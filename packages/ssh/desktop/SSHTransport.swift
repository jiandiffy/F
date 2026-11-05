import AppKit

enum SSHFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum SSHConfig {
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config") }

    /// Enumerate literal aliases only. OpenSSH itself resolves Match, defaults, keys and ProxyJump.
    static func hosts(in url: URL = SSHConfig.url) -> [String] {
        let base = url.deletingLastPathComponent()
        var visited: Set<String> = []
        var result: [String] = []
        func read(_ url: URL, depth: Int) {
            guard depth < 16, visited.insert(url.standardizedFileURL.path).inserted,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) {
                let parts = tokens(line)
                guard let keyword = parts.first?.lowercased() else { continue }
                if keyword == "host" {
                    for host in parts.dropFirst() where !host.contains(where: { "*?!".contains($0) }) && validHost(host) {
                        if !result.contains(host) { result.append(host) }
                    }
                } else if keyword == "include" {
                    for pattern in parts.dropFirst() {
                        let expanded = (pattern as NSString).expandingTildeInPath
                        let absolute = expanded.hasPrefix("/") ? expanded : base.appendingPathComponent(expanded).path
                        for file in expand(absolute) { read(file, depth: depth + 1) }
                    }
                }
            }
        }
        read(url, depth: 0)
        return result
    }

    static func tokens(_ line: String) -> [String] {
        var parts: [String] = [], value = ""
        var quoted = false, escaped = false
        for character in line {
            if escaped { value.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if character == "#", !quoted { break }
            if (character.isWhitespace || (character == "=" && parts.isEmpty)), !quoted {
                if !value.isEmpty { parts.append(value); value = "" }
            } else { value.append(character) }
        }
        if !value.isEmpty { parts.append(value) }
        return parts
    }

    private static func expand(_ pattern: String) -> [URL] {
        var paths = [URL(fileURLWithPath: "/")]
        for component in pattern.split(separator: "/").map(String.init) {
            if component.contains("*") || component.contains("?") || component.contains("[") {
                paths = paths.flatMap { parent in
                    ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [])
                        .filter { fnmatch(component, $0.lastPathComponent, 0) == 0 }.sorted { $0.path < $1.path }
                }
            } else { paths = paths.map { $0.appendingPathComponent(component) } }
        }
        return paths.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.range(of: #"^[A-Za-z0-9_.:%\[\]-]+$"#, options: .regularExpression) != nil
    }
}

struct SSHConnection: Equatable, Hashable, Codable {
    let host: String
    var user = ""
    var port: Int?
    var label: String { user.isEmpty ? host : "\(user)@\(host)" }
    var key: String { "\(user)|\(host)|\(port.map(String.init) ?? "default")" }
    static func parse(_ input: String) throws -> SSHConnection {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = text.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { throw SSHFailure.message("主机格式应为 user@host:port。") }
        let user = pieces.count == 2 ? String(pieces[0]) : ""
        let address = String(pieces.last ?? "")
        var host = address, port: Int?
        if address.hasPrefix("[") {
            guard let end = address.firstIndex(of: "]") else { throw SSHFailure.message("IPv6 地址请使用 [地址]:端口。") }
            host = String(address[address.index(after: address.startIndex)..<end])
            let suffix = String(address[address.index(after: end)...])
            if !suffix.isEmpty {
                guard suffix.hasPrefix(":"), let value = Int(suffix.dropFirst()) else { throw SSHFailure.message("端口无效。") }
                port = value
            }
        } else if address.filter({ $0 == ":" }).count == 1 {
            let values = address.split(separator: ":", omittingEmptySubsequences: false)
            host = String(values[0])
            guard let value = Int(values[1]) else { throw SSHFailure.message("端口无效。") }
            port = value
        }
        let connection = SSHConnection(host: host, user: user, port: port)
        try connection.validate()
        return connection
    }
    var address: String {
        let target = host.contains(":") ? "[\(host)]" : host
        return (user.isEmpty ? "" : user + "@") + target + (port.map { ":\($0)" } ?? "")
    }
    func validate() throws {
        guard SSHConfig.validHost(host), user.isEmpty || user.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              port == nil || (1...65535).contains(port!) else { throw SSHFailure.message("请填写有效的主机、用户名和端口。") }
    }
}

struct RemoteEntry: Equatable {
    let path: String
    let isDirectory: Bool
    var name: String { (path as NSString).lastPathComponent }
}

struct RemoteTextFile {
    let path: String
    let text: String
    let fingerprint: String
}

private final class SSHProcessOutput {
    var inputError: Error?
    var stdout = Data()
    var stderr = Data()
}

final class SSHTransport {
    let connection: SSHConnection
    let socketDirectory: URL
    var socket: String { socketDirectory.appendingPathComponent("s").path }
    private let executable: String
    let config: URL?
    private var generation = 0
    private var processes: [UUID: Process] = [:]

    init(connection: SSHConnection, executable: String = "/usr/bin/ssh", config: URL? = nil) throws {
        try connection.validate()
        self.connection = connection
        self.executable = executable
        self.config = config
        // Keep Darwin's Unix socket path short and private.
        socketDirectory = URL(fileURLWithPath: "/tmp/f-ssh-" + UUID().uuidString.prefix(12))
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    deinit { processes.values.forEach { if $0.isRunning { $0.terminate() } }; try? FileManager.default.removeItem(at: socketDirectory) }

    private var options: [String] {
        var args: [String] = config.map { ["-F", $0.path] } ?? []
        args += ["-S", socket, "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=12", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"]
        if !connection.user.isEmpty { args += ["-l", connection.user] }
        if let port = connection.port { args += ["-p", String(port)] }
        return args
    }

    var terminalArguments: [String] {
        options + ["-tt", "-M", "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-o", "StrictHostKeyChecking=ask", connection.host]
    }

    /// File commands fail closed if the interactive connection has gone away: no second login.
    var commandArguments: [String] {
        options + ["-T", "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ProxyCommand=/usr/bin/false", connection.host]
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func run(_ command: String, input: Data = Data(), completion: @escaping (Result<Data, Error>) -> Void) {
        let token = generation, id = UUID()
        let process = Process(), output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = commandArguments + ["/bin/sh -c " + Self.quote(command)]
        process.standardOutput = output; process.standardError = errors; process.standardInput = stdin
        processes[id] = process
        do { try process.run() }
        catch { processes.removeValue(forKey: id); completion(.failure(error)); return }
        // Drain stdout/stderr concurrently so large files cannot deadlock the child.
        let group = DispatchGroup()
        let captured = SSHProcessOutput()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { captured.stdout = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { captured.stderr = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        DispatchQueue.global(qos: .userInitiated).async {
            do { try stdin.fileHandleForWriting.write(contentsOf: input) } catch { captured.inputError = error }
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            group.wait()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.processes.removeValue(forKey: id)
                guard self.generation == token else { completion(.failure(SSHFailure.message("SSH 连接已断开。"))); return }
                if let error = captured.inputError { completion(.failure(error)) }
                else if process.terminationStatus == 0 { completion(.success(captured.stdout)) }
                else {
                    let detail = String(decoding: captured.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(.failure(SSHFailure.message(detail.isEmpty ? "远程操作失败（\(process.terminationStatus)）。" : detail)))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self, weak process] in
            guard let self, self.processes[id] != nil, let process, process.isRunning else { return }
            process.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
    }

    func home(_ completion: @escaping (Result<String, Error>) -> Void) {
        run("printf '%s' \"$HOME\"") { result in
            completion(result.flatMap { data in
                guard let path = String(data: data, encoding: .utf8), path.hasPrefix("/") else { return .failure(SSHFailure.message("无法读取远程主目录。")) }
                return .success(path)
            })
        }
    }

    func list(_ path: String, completion: @escaping (Result<(String, [RemoteEntry]), Error>) -> Void) {
        let command = """
        cd \(Self.quote(path)) || exit
        printf '%s\\0' "$PWD"
        for p in "$PWD"/.[!.]* "$PWD"/..?* "$PWD"/*; do
          [ -e "$p" ] || [ -L "$p" ] || continue
          if [ -d "$p" ]; then t=d; else t=f; fi
          printf '%s\\0%s\\0' "$t" "$p"
        done
        """
        run(command) { completion($0.flatMap(Self.decodeListing)) }
    }

    static func decodeListing(_ data: Data) -> Result<(String, [RemoteEntry]), Error> {
        let parts = data.split(separator: 0, omittingEmptySubsequences: false)
        guard parts.count >= 2, let path = String(data: parts[0], encoding: .utf8), path.hasPrefix("/"), parts.last?.isEmpty == true,
              (parts.count - 2) % 2 == 0 else { return .failure(SSHFailure.message("远程文件列表格式无效。")) }
        var entries: [RemoteEntry] = []
        for index in stride(from: 1, to: parts.count - 1, by: 2) {
            guard let name = String(data: parts[index + 1], encoding: .utf8), name.hasPrefix("/"),
                  parts[index] == Data("d".utf8) || parts[index] == Data("f".utf8) else {
                return .failure(SSHFailure.message("远程文件名无法以 UTF-8 读取。"))
            }
            entries.append(RemoteEntry(path: name, isDirectory: parts[index] == Data("d".utf8)))
        }
        entries.sort { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return .success((path, entries))
    }

    func readText(_ path: String, completion: @escaping (Result<RemoteTextFile, Error>) -> Void) {
        let q = Self.quote(path)
        run("set -e; [ -f \(q) ]; [ \"$(wc -c < \(q))\" -le 2000000 ] || { echo '文件超过 2 MB，请在远程终端中编辑。' >&2; exit 1; }; cksum < \(q); cat < \(q)") { result in
            completion(result.flatMap { data in
                guard let split = data.firstIndex(of: 10), let fingerprint = String(data: data[..<split], encoding: .utf8),
                      let text = String(data: data[data.index(after: split)...], encoding: .utf8), !text.contains("\0") else {
                    return .failure(SSHFailure.message("此文件不是 UTF-8 文本，请使用远程终端读写。"))
                }
                return .success(RemoteTextFile(path: path, text: text, fingerprint: fingerprint))
            })
        }
    }

    func save(_ file: RemoteTextFile, text: String, completion: @escaping (Result<RemoteTextFile, Error>) -> Void) {
        // Copy permissions, write a sibling temporary file, then atomically replace the target.
        // Refuse symlinks and concurrent changes rather than replacing an unexpected target.
        let command = """
        set -e
        p=\(Self.quote(file.path))
        [ ! -L "$p" ] || { echo '请通过真实路径编辑符号链接的目标文件。' >&2; exit 1; }
        [ "$(cksum < "$p")" = \(Self.quote(file.fingerprint)) ] || { echo '远程文件已被修改，请重新打开后再保存。' >&2; exit 73; }
        dir=${p%/*}; [ -n "$dir" ] || dir=/
        tmp=$(mktemp "$dir/.f-write.XXXXXX")
        trap 'rm -f "$tmp"' EXIT HUP INT TERM
        cp -p "$p" "$tmp"
        cat > "$tmp"
        [ "$(cksum < "$p")" = \(Self.quote(file.fingerprint)) ] || { echo '远程文件已被修改，请重新打开后再保存。' >&2; exit 73; }
        mv -f "$tmp" "$p"
        trap - EXIT HUP INT TERM
        cksum < "$p"
        """
        run(command, input: Data(text.utf8)) { result in
            completion(result.map { RemoteTextFile(path: file.path, text: text, fingerprint: String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) })
        }
    }

    func disconnect() {
        generation += 1
        for process in processes.values where process.isRunning { process.terminate() }
        processes.removeAll()
    }
}
