import Foundation

struct VersionSnapshotFile {
    let path: String
    let object: String?
    let kind: String
    let size: Int?
    let change: String?
}

struct VersionSnapshot {
    let hash: String
    let parents: [String]
    let author: String
    let date: String
    let message: String
    let files: [VersionSnapshotFile]

    /// Deterministic, source-attributed synopsis, never an invented model assessment.
    var synopsis: String {
        let changed = files.filter { $0.change != nil }.count
        let lead = "提交说明："
        let source = message.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let tail = "\n\(author.prefix(24)) · \(date.prefix(10)) · \(files.filter { $0.object != nil }.count)个文件／\(changed)个变更路径。据 Git 记录，不代表测试结论。"
        let budget = max(0, 200 - lead.count - tail.count)
        let excerpt = source.count > budget ? String(source.prefix(max(0, budget - 1))) + "…" : source
        return String((lead + excerpt + tail).prefix(200))
    }
}

/// Local Git object reads only: no checkout, staging, hooks, shell, network or writes.
/// Each request owns its subprocess; cancellation cannot terminate the Agent or F.
final class VersionGitReader {
    private let project: URL
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    init(project: URL) { self.project = project }

    func cancel() {
        lock.lock(); cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    static func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "F.VersionSnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func git(_ args: [String], limit: Int = 12 * 1024 * 1024) throws -> Data {
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        child.arguments = ["--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects", "-c", "core.fsmonitor=false", "-C", project.path] + args
        child.standardOutput = pipe; child.standardError = pipe
        child.standardInput = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw failure("已取消版本读取") }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer {
            try? pipe.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        var result = Data(), overflow = false
        while true {
            let chunk = pipe.fileHandleForReading.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            if !overflow && result.count + chunk.count <= limit { result.append(chunk) }
            else if !overflow {
                overflow = true
                if child.isRunning { child.terminate() }
            }
        }
        child.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw failure("已取消版本读取") }
        if overflow { throw failure("版本内容过大，未载入（上限 \(limit / 1024) KB）") }
        guard child.terminationStatus == 0 else {
            throw failure(String(data: result.prefix(2048), encoding: .utf8) ?? "Git 对象读取失败")
        }
        return result
    }

    private func validateRoot() throws {
        let rootData = try git(["rev-parse", "--show-toplevel"])
        guard let root = String(data: rootData, encoding: .utf8)?.trimmingCharacters(in: .newlines),
              URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL == project.resolvingSymlinksInPath().standardizedFileURL else {
            throw failure("此文件夹没有独立 Git 仓库，不读取父项目的版本")
        }
    }

    /// Every commit is an immutable node; branch labels are annotations, not node IDs.
    func history(branches: [[String: Any]]) throws -> [[String: Any]] {
        try validateRoot()
        let raw = try git(["log", "--all", "--topo-order", "--reverse", "--max-count=250", "--format=%H%x00%P%x00%s%x00"])
        return try String(decoding: raw, as: UTF8.self).split(separator: "\n").map { record in
            let fields = record.components(separatedBy: "\0")
            guard fields.count >= 3, Self.isObjectID(fields[0]) else { throw failure("提交历史记录无效") }
            let hash = fields[0], parents = fields[1].split(separator: " ").map(String.init)
            let labels = branches.filter { $0["head"] as? String == hash }.map {
                ($0["branch"] as? String ?? "") + " [" + ($0["id"] as? String ?? "") + "]"
            }.joined(separator: " · ")
            var node: [String: Any] = ["id": hash, "head": hash, "label": fields[2], "parents": parents, "branch": labels]
            if let parent = parents.first { node["parent"] = parent }
            return node
        }
    }

    func snapshot(hash: String) throws -> VersionSnapshot {
        guard Self.isObjectID(hash) else { throw failure("缺少有效的固定 commit 哈希，请刷新版本图") }
        try validateRoot()
        let type = String(decoding: try git(["cat-file", "-t", hash]), as: UTF8.self).trimmingCharacters(in: .newlines)
        guard type == "commit" else { throw failure("所选对象不是 commit") }
        let raw = String(decoding: try git(["show", "-s", "--no-show-signature", "--no-notes", "--format=%H%x00%P%x00%an%x00%aI%x00%B", hash, "--"]), as: UTF8.self)
        let fields = raw.components(separatedBy: "\0")
        guard fields.count >= 5, fields[0] == hash else { throw failure("提交元数据无效") }
        let parents = fields[1].split(separator: " ").map(String.init)
        let diff = try git(["diff-tree", "--root", "-m", "--no-commit-id", "--name-status", "-z", "-r", "--no-renames", "--no-ext-diff", "--no-textconv", hash, "--"])
        let entries = String(decoding: diff, as: UTF8.self).components(separatedBy: "\0")
        var changes: [String: String] = [:]
        var index = 0
        while index + 1 < entries.count {
            let status = entries[index], path = entries[index + 1]
            if !status.isEmpty && !path.isEmpty { changes[path] = status }
            index += 2
        }
        let tree = try git(["ls-tree", "-r", "-l", "-z", "--full-tree", hash])
        var files: [VersionSnapshotFile] = [], paths = Set<String>()
        for record in String(decoding: tree, as: UTF8.self).components(separatedBy: "\0") where !record.isEmpty {
            guard let tab = record.firstIndex(of: "\t") else { throw failure("提交文件记录无效") }
            let info = record[..<tab].split(separator: " ")
            let path = String(record[record.index(after: tab)...])
            guard info.count == 4, Self.isObjectID(String(info[2])) else { throw failure("提交文件对象无效") }
            paths.insert(path)
            files.append(VersionSnapshotFile(path: path, object: String(info[2]), kind: String(info[1]), size: Int(info[3]), change: changes[path]))
        }
        for path in changes.keys.sorted() where !paths.contains(path) {
            files.append(VersionSnapshotFile(path: path, object: nil, kind: "deleted", size: nil, change: changes[path]))
        }
        files.sort { lhs, rhs in
            if (lhs.change != nil) != (rhs.change != nil) { return lhs.change != nil }
            return lhs.path < rhs.path
        }
        return VersionSnapshot(hash: hash, parents: parents, author: fields[2], date: fields[3], message: fields[4], files: files)
    }

    func contents(of file: VersionSnapshotFile) throws -> String {
        guard let object = file.object else { return "该路径在此提交中已删除，没有可预览内容。" }
        guard Self.isObjectID(object), file.kind == "blob" else { return "子模块仅记录固定提交，不访问其仓库或网络。" }
        guard let size = file.size, size <= 2 * 1024 * 1024 else { return "此文件超过 2 MB，只显示提交文件记录，不载入内容。" }
        let data = try git(["cat-file", "blob", object], limit: 2 * 1024 * 1024)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return "二进制或非 UTF-8 文件（\(data.count) 字节）；为保持只读，不调用外部应用或当前工作区文件。"
        }
        return text.isEmpty ? "（空文件）" : text
    }
}
