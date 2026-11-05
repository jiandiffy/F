import AppKit

extension Notification.Name { static let fSSHChanged = Notification.Name("F.SSHChanged") }

/// Non-interactive probes never open a terminal, ask for a password, or start port forwarding.
enum SSHCommand {
    static func run(_ arguments: [String], timeout: TimeInterval = 10, completion: @escaping (Result<Data, Error>) -> Void) {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        process.environment = environment
        do { try process.run() } catch { completion(.failure(error)); return }
        let captured = SSHCommandOutput(), group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { captured.data = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { captured.error = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        DispatchQueue.global().async {
            process.waitUntilExit(); group.wait()
            DispatchQueue.main.async {
                if process.terminationStatus == 0 { completion(.success(captured.data)) }
                else { completion(.failure(SSHFailure.message(String(decoding: captured.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                process.terminate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
        }
    }
    static func options(_ connection: SSHConnection, config: URL? = nil) -> [String] {
        var args = config.map { ["-F", $0.path] } ?? []
        if !connection.user.isEmpty { args += ["-l", connection.user] }
        if let port = connection.port { args += ["-p", String(port)] }
        return args
    }
    static func resolve(_ connection: SSHConnection, config: URL? = nil, completion: @escaping (String) -> Void) {
        run(options(connection, config: config) + ["-G", connection.host]) { result in
            var values: [String: String] = [:]
            if case .success(let data) = result {
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    let pair = line.split(separator: " ", maxSplits: 1)
                    if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
                }
            }
            completion("\(values["user"] ?? connection.user)@\(values["hostname"] ?? connection.host):\(values["port"] ?? String(connection.port ?? 22))")
        }
    }
}
private final class SSHCommandOutput { var data = Data(); var error = Data() }

final class SSHSession {
    enum Phase: Equatable { case connecting, password(String), hostKey(String), connected, ended(String) }
    let transport: SSHTransport
    let terminal: TerminalView
    private(set) var phase = Phase.connecting
    private(set) var home = "/"
    private(set) var endpoint = ""
    /// 哪个 SSH 面板正在显示认证终端；其他面板必须创建自己的终端视图。
    var authTerminalOwner: ObjectIdentifier?
    var connection: SSHConnection { transport.connection }
    private var tail = ""
    private var timer: Timer?
    private var checking = false
    private var generation = 0
    private var waits: [(Result<SSHSession, Error>) -> Void] = []

    init(connection: SSHConnection, config: URL? = nil) throws {
        transport = try SSHTransport(connection: connection, config: config)
        terminal = TerminalView(frame: .zero)
        terminal.appearance = NSAppearance(named: .aqua)
        terminal.onOutput = { [weak self] in self?.receive($0) }
        terminal.onExit = { [weak self] in self?.finish("SSH 已断开") }
    }
    deinit { timer?.invalidate() }
    func start() {
        SSHCommand.resolve(connection, config: transport.config) { [weak self] endpoint in self?.endpoint = endpoint }
        terminal.startCommand("/usr/bin/ssh", arguments: transport.terminalArguments, in: FileManager.default.homeDirectoryForCurrentUser)
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func wait(_ completion: @escaping (Result<SSHSession, Error>) -> Void) {
        if phase == .connected { completion(.success(self)) }
        else if case .ended(let message) = phase { completion(.failure(SSHFailure.message(message))) }
        else { waits.append(completion) }
    }
    private func publish() { NotificationCenter.default.post(name: .fSSHChanged, object: self) }
    private func receive(_ data: Data) {
        guard phase != .connected else { return }
        tail = String((tail + String(decoding: data, as: UTF8.self)).suffix(4096))
        if tail.range(of: #"(?i)(password|passphrase|密码)[^\r\n]*[:：]\s*$"#, options: .regularExpression) != nil {
            phase = .password(tail.components(separatedBy: .newlines).last ?? "密码")
            publish()
        } else if tail.contains("Are you sure you want to continue connecting"), tail.hasSuffix("? ") || tail.hasSuffix("?") {
            phase = .hostKey(tail); publish()
        }
    }
    func answer(_ value: String) {
        guard case .password = phase else {
            if case .hostKey = phase { tail = ""; phase = .connecting; terminal.send(Data((value + "\n").utf8)); publish() }
            return
        }
        tail = ""; phase = .connecting
        terminal.send(Data((value + "\n").utf8))
        publish()
    }
    private func check() {
        guard phase != .connected, !checking, FileManager.default.fileExists(atPath: transport.socket) else { return }
        checking = true; let token = generation
        transport.home { [weak self] result in
            guard let self, self.generation == token else { return }
            self.checking = false
            if case .success(let home) = result {
                self.home = home
                self.phase = .connected
                self.tail = ""
                self.timer?.invalidate(); self.timer = nil
                if self.endpoint.isEmpty { self.endpoint = self.connection.address }
                let callbacks = self.waits; self.waits.removeAll()
                callbacks.forEach { $0(.success(self)) }
                self.publish()
            }
        }
    }
    private func finish(_ message: String) {
        generation += 1; timer?.invalidate(); timer = nil
        phase = .ended(tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? message : String(tail.suffix(1000)))
        transport.disconnect()
        let callbacks = waits; waits.removeAll()
        callbacks.forEach { $0(.failure(SSHFailure.message(message))) }
        publish()
    }
    func stop() { terminal.stop(); finish("SSH 已断开") }
}

final class SSHSessions {
    static let shared = SSHSessions()
    private(set) var sessions: [String: SSHSession] = [:]
    private(set) var verified: [String: SSHConnection] = [:]
    private(set) var resolved: [String: String] = [:]
    private(set) var probing = false
    private var revision = 0
    private var lastProbe: Date?
    private var lastConfig: String?
    var available: [SSHConnection] {
        guard PluginPreferences.isEnabled("ssh") else { return [] }
        var values = verified
        for session in sessions.values where session.phase == .connected { values[session.connection.key] = session.connection }
        return values.values.sorted { $0.address.localizedStandardCompare($1.address) == .orderedAscending }
    }
    func session(_ connection: SSHConnection) -> SSHSession? { sessions[connection.key] }
    @discardableResult func connect(_ connection: SSHConnection, config: URL? = nil) throws -> SSHSession {
        if let existing = sessions[connection.key], existing.phase == .connected { return existing }
        sessions[connection.key]?.stop()
        let session = try SSHSession(connection: connection, config: config)
        sessions[connection.key] = session
        session.start()
        return session
    }
    func ensure(_ connection: SSHConnection, completion: @escaping (Result<SSHSession, Error>) -> Void) {
        guard PluginPreferences.isEnabled("ssh") else { completion(.failure(SSHFailure.message("SSH 插件已关闭，请在 F → plugin 中打开。"))); return }
        if let session = session(connection), session.phase == .connected { completion(.success(session)); return }
        if verified[connection.key] == nil, probing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.ensure(connection, completion: completion) }
            return
        }
        guard verified[connection.key] != nil else { completion(.failure(SSHFailure.message("请先在底部 SSH 中登录 \(connection.address)，再继续此远程项目。"))); return }
        do {
            let session = try connect(connection)
            session.wait(completion)
            DispatchQueue.main.asyncAfter(deadline: .now() + 18) {
                if session.phase != .connected { session.stop() }
            }
        } catch { completion(.failure(error)) }
    }
    func refresh(config: URL = SSHConfig.url) {
        guard PluginPreferences.isEnabled("ssh"), !probing else { return }
        if lastConfig == config.path, let lastProbe, Date().timeIntervalSince(lastProbe) < 30 { return }
        probing = true; revision += 1
        lastConfig = config.path
        var nextVerified: [String: SSHConnection] = [:]
        let token = revision, hosts = SSHConfig.hosts(in: config)
        var pending = hosts, running = 0
        func next() {
            guard token == revision else { return }
            while running < 3, !pending.isEmpty {
                let connection = SSHConnection(host: pending.removeFirst())
                running += 1
                SSHCommand.resolve(connection, config: config == SSHConfig.url ? nil : config) { endpoint in self.resolved[connection.host] = endpoint }
                let args = SSHCommand.options(connection, config: config == SSHConfig.url ? nil : config) +
                    ["-T", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=4", "-o", "ConnectionAttempts=1", "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no", connection.host, "true"]
                SSHCommand.run(args, timeout: 9) { result in
                    guard token == self.revision else { return }
                    if case .success = result {
                        nextVerified[connection.key] = connection
                        self.verified[connection.key] = connection
                    }
                    running -= 1
                    NotificationCenter.default.post(name: .fSSHChanged, object: nil)
                    next()
                }
            }
            if running == 0, pending.isEmpty {
                verified = nextVerified; probing = false; lastProbe = Date()
                NotificationCenter.default.post(name: .fSSHChanged, object: nil)
            }
        }
        next()
    }
    /// 每个 SSH 进程拥有自己的终端视图；多个进程可以同时复用同一个 ControlMaster 套接字。
    /// 这里从不缓存返回的视图，避免两个面板挂载同一个 NSView 而互相挪走。
    func makeTerminal(for session: SSHSession, project: RemoteProject?) -> TerminalView {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        terminal.appearance = NSAppearance(named: .aqua)
        let base = Array(session.transport.commandArguments.dropLast())
        let command = project.map { "cd " + SSHTransport.quote($0.path) + " && " } ?? ""
        let args = base + ["-tt", session.connection.host,
            command + "exec \"${SHELL:-/bin/sh}\" -l"]
        terminal.startCommand("/usr/bin/ssh", arguments: args, in: FileManager.default.homeDirectoryForCurrentUser)
        return terminal
    }
    func shutdown() {
        revision += 1; probing = false; verified.removeAll(); lastProbe = nil
        sessions.values.forEach { $0.stop() }; sessions.removeAll()
    }
}
