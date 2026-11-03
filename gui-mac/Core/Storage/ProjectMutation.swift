import Foundation
import CryptoKit

/// A deliberately conservative local-folder transaction. Session files normally stay where they
/// are: only their structured header cwd changes, so session identity/parent links remain stable.
/// No process is stopped, no shell is executed and no git refs or validation evidence are changed.
enum ProjectMutation {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    struct Environment {
        var defaults: UserDefaults = .standard
        var support: URL = BoardStore.appSupport
        var sessions: URL? = PiHistory.agentDirectory()
        var additionalSessions: [URL] = []
        var protectedRoots: [URL] = [URL(fileURLWithPath: "/Users/fanfy/Desktop/fy/F"), Bundle.main.bundleURL]
        /// Test-only failure injection; production never sets it.
        var checkpoint: ((String) throws -> Void)?
    }
    struct Move: Codable { let source: String; let target: String }
    struct SavedFile: Codable {
        let source: String; let target: String; let backup: String
        let beforeSHA256: String; let afterSHA256: String
    }
    struct Journal: Codable {
        var phase: String
        let source: String
        let target: String
        var moves: [Move]
        var files: [SavedFile]
        var defaultKeys: [String] = []
        var message: String?
    }
    private struct Edit {
        let source: URL
        let target: URL
        let before: Data
        let after: Data
    }
    static func contains(_ path: String, in root: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = URL(fileURLWithPath: root).standardizedFileURL.path
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    static func remap(_ path: String, from source: URL, to target: URL) -> String {
        let source = source.standardizedFileURL, target = target.standardizedFileURL
        guard path.hasPrefix("/"), contains(path, in: source.path) else { return path }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return target.path + normalized.dropFirst(source.path.count)
    }
    private static func reject(_ text: String) throws -> Never { throw Failure(message: text) }
    private static func exists(_ url: URL) -> Bool {
        // Includes dangling symlinks, which must also count as a conflicting destination.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
    private static func digest(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func files(in root: URL) throws -> [URL] {
        guard exists(root) else { return [] }
        var error: Error?
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [], errorHandler: { _, failure in error = failure; return false })
        var result: [URL] = []
        while let url = walker?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { walker?.skipDescendants(); continue }
            if values.isRegularFile == true { result.append(url.standardizedFileURL) }
        }
        if let error { throw error }
        return result
    }
    private static let referenceKeys: Set<String> = ["project", "projectPath", "cwd", "session", "sessionPath", "sessionFile", "parentSession", "noticeProject", "noticeSession", "originProject", "originSession"]
    private static func relocatedPath(_ path: String, from source: URL, to target: URL, moves: [Move]) -> String {
        var result = remap(path, from: source, to: target)
        for move in moves.dropFirst() {
            result = remap(result, from: URL(fileURLWithPath: move.source), to: URL(fileURLWithPath: move.target))
        }
        return result
    }
    private static func references(_ value: Any, from source: URL, to target: URL, moves: [Move]) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, pair in
                if referenceKeys.contains(pair.key), let path = pair.value as? String {
                    result[pair.key] = relocatedPath(path, from: source, to: target, moves: moves)
                } else { result[pair.key] = references(pair.value, from: source, to: target, moves: moves) }
            }
        }
        if let values = value as? [Any] { return values.map { references($0, from: source, to: target, moves: moves) } }
        return value
    }
    /// Preserve message/tool bytes exactly, including historical paths in evidence and prompts.
    private static func sessionData(_ data: Data, from source: URL, to target: URL, moves: [Move]) throws -> Data {
        var result = Data()
        var found = false
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            var output = Data(line)
            if !found, !line.isEmpty {
                guard var header = try JSONSerialization.jsonObject(with: output) as? [String: Any], header["type"] as? String == "session" else {
                    throw Failure(message: "会话头无效，未迁移：请先修复会话文件。")
                }
                found = true
                if header["cwd"] as? String == nil { throw Failure(message: "旧会话缺少 cwd，无法无歧义迁移；请先打开并保存旧会话。") }
                var changed = false
                for key in ["cwd", "parentSession"] {
                    if let old = header[key] as? String {
                        let mapped = relocatedPath(old, from: source, to: target, moves: moves)
                        if old != mapped { header[key] = mapped; changed = true }
                    }
                }
                if changed { output = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]) }
            }
            result.append(output)
            if index < lines.count - 1 { result.append(10) }
        }
        return result
    }
    /// Validate first without changing either folder. Worktrees/operation locks are never repaired
    /// or removed here; moving their common git directory requires a separate git-aware operation.
    static func validate(_ source: URL, name: String, environment env: Environment = Environment()) throws -> URL {
        let fm = FileManager.default, source = source.standardizedFileURL
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              !name.contains("\0"), name == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
            try reject("请输入有效文件夹名（不能包含 /、: 或首尾空白）。")
        }
        guard RemoteProjects.load(source) == nil else { try reject("SSH 项目暂不支持安全远程重命名；未改动本机代理目录。") }
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &directory), directory.boolValue else { try reject("项目文件夹不存在。") }
        guard source.path != "/", source.resolvingSymlinksInPath().path == source.path else { try reject("请使用真实文件夹路径；符号链接或路径别名不支持重命名。") }
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard source.path != home else { try reject("不能重命名主目录。") }
        for protected in env.protectedRoots + [env.support, BoardStore.root] {
            if contains(protected.resolvingSymlinksInPath().path, in: source.path) {
                try reject("该目录包含正在使用的 F 源码、应用或数据，不能重命名。")
            }
        }
        let target = source.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        guard target.path != source.path else { try reject("文件夹名称未改变。") }
        guard !exists(target) else { try reject("目标文件夹已存在（大小写重命名也须使用不冲突名称）。") }
        if exists(env.support.appendingPathComponent("updates/pending.json")) { try reject("存在待安装更新，暂不能迁移项目。") }
        let versions = env.support.appendingPathComponent("applications/versions/" + digest(source.path) + "/worktrees")
        if exists(versions), !(try fm.contentsOfDirectory(atPath: versions.path)).isEmpty { try reject("项目存在版本子工作树，请先安全收拢工作树。") }
        var scanError: Error?
        let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [],
            errorHandler: { _, error in scanError = error; return false })
        guard walker != nil else { try reject("无法安全检查项目目录，未迁移。") }
        while let url = walker?.nextObject() as? URL {
            if url.lastPathComponent == "f-tree-operation.lock" { try reject("版本操作锁仍存在，未迁移或删除锁。") }
            if url.lastPathComponent == ".git" {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                      (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { try reject("Git worktree/外置 gitdir 项目不能直接重命名。") }
                let worktrees = url.appendingPathComponent("worktrees")
                if exists(worktrees), !(try fm.contentsOfDirectory(atPath: worktrees.path)).isEmpty { try reject("Git 登记了工作树，暂不能重命名。") }
                if exists(url.appendingPathComponent("f-tree-operation.lock")) { try reject("版本操作锁仍存在，未迁移或删除锁。") }
                walker?.skipDescendants()
            } else if (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { walker?.skipDescendants() }
        }
        if let scanError { throw scanError }
        return target
    }
    @discardableResult
    static func rename(_ source: URL, name: String, environment env: Environment = Environment()) throws -> URL {
        let fm = FileManager.default, source = source.standardizedFileURL
        let target = try validate(source, name: name, environment: env)
        try fm.createDirectory(at: env.support, withIntermediateDirectories: true)
        let lock = env.support.appendingPathComponent("project-mutation.lock", isDirectory: true)
        do { try fm.createDirectory(at: lock, withIntermediateDirectories: false) }
        catch { try reject("另一个项目迁移仍持有锁，请勿手动删除锁。") }
        defer { try? fm.removeItem(at: lock) }
        let transactions = env.support.appendingPathComponent("project-mutations", isDirectory: true)
        try fm.createDirectory(at: transactions, withIntermediateDirectories: true)
        for folder in try fm.contentsOfDirectory(at: transactions, includingPropertiesForKeys: nil) {
            let journal = folder.appendingPathComponent("journal.json")
            guard exists(journal) else { continue }
            let saved = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journal))
            guard ["committed", "rolledBack"].contains(saved.phase) else { try reject("存在未完成迁移，保留日志与备份，请先恢复：" + folder.path) }
        }
        var edits: [Edit] = [], projects: Set<String> = [source.path]
        let defaultsBefore = env.defaults.dictionaryRepresentation()
        for key in ["FProjectFolders", "FHiddenProjectFolders"] {
            for path in env.defaults.stringArray(forKey: key) ?? [] {
                if contains(path, in: target.path) { try reject("目标路径已有项目入口或隐藏记录，拒绝合并。") }
                if contains(path, in: source.path) { projects.insert(URL(fileURLWithPath: path).standardizedFileURL.path) }
            }
        }
        // Include empty sessions (not shown by PiHistory.load), child sessions and parent links.
        var validSessions: [URL: [String: Any]] = [:]
        var sessionFiles: Set<URL> = Set(env.additionalSessions.map(\.standardizedFileURL))
        if let sessions = env.sessions { sessionFiles.formUnion(try files(in: sessions).filter { $0.pathExtension == "jsonl" }) }
        for file in sessionFiles.sorted(by: { $0.path < $1.path }) {
            let handle = try FileHandle(forReadingFrom: file)
            let prefix: Data
            do { prefix = try handle.read(upToCount: 1024 * 1024) ?? Data(); try handle.close() }
            catch { try? handle.close(); throw error }
            guard !prefix.isEmpty else { continue }
            guard let line = prefix.split(separator: 10).first,
                  let header = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  header["type"] as? String == "session" else {
                if contains(file.path, in: source.path) { try reject("项目内会话头无效，未迁移。") }
                continue // Never block an unrelated project's rename because of unrelated history.
            }
            if header["cwd"] == nil {
                if let decoded = PiHistory.decodedProjectDirectory(file), contains(decoded, in: source.path) {
                    try reject("该项目旧会话缺少 cwd，无法无歧义迁移，请先修复会话头。")
                }
                continue
            }
            if let cwd = header["cwd"] as? String {
                if contains(cwd, in: target.path) { try reject("目标路径已有历史会话，拒绝合并两个项目。") }
                if contains(cwd, in: source.path) { projects.insert(URL(fileURLWithPath: cwd).standardizedFileURL.path) }
            }
            validSessions[file] = header
        }
        // A project can own a saved scene before its first message, including nested projects.
        if exists(BoardStore.root) {
            for folder in try fm.contentsOfDirectory(at: BoardStore.root, includingPropertiesForKeys: nil) {
                let scene = folder.appendingPathComponent("scene.json")
                if let data = try? Data(contentsOf: scene),
                   let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let path = object["project"] as? String {
                    if contains(path, in: target.path) { try reject("目标路径已有集中画板，拒绝合并。") }
                    if contains(path, in: source.path) { projects.insert(URL(fileURLWithPath: path).standardizedFileURL.path) }
                }
            }
        }
        var moves = [Move(source: source.path, target: target.path)]
        var metadataRoots: [URL] = []
        var boardRoots: [URL] = []
        let applications = env.support.appendingPathComponent("applications", isDirectory: true)
        let pluginRoots = exists(applications) ? try fm.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil) : []
        for path in projects.sorted() {
            let old = URL(fileURLWithPath: path), new = URL(fileURLWithPath: remap(path, from: source, to: target))
            let oldBoard = BoardStore.directory(for: old), newBoard = BoardStore.directory(for: new)
            if exists(oldBoard) { boardRoots.append(oldBoard) }
            let legacy = old.appendingPathComponent(".f/whiteboard")
            if exists(legacy) { metadataRoots.append(legacy) }
            let childWorktrees = applications.appendingPathComponent("versions/" + digest(old.path) + "/worktrees")
            if exists(childWorktrees), !(try fm.contentsOfDirectory(atPath: childWorktrees.path)).isEmpty { try reject("项目或子项目存在版本子工作树，未迁移。") }
            for (oldData, newData) in [(oldBoard, newBoard)] + pluginRoots.map({ ($0.appendingPathComponent(digest(old.path)), $0.appendingPathComponent(digest(new.path))) }) {
                guard !exists(newData) else { try reject("目标项目数据已存在，拒绝覆盖：" + newData.path) }
                if exists(oldData) {
                    guard oldData.path != newData.path,
                          (try oldData.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { try reject("项目数据路径存在链接或身份冲突，未迁移。") }
                    guard !contains(oldData.path, in: source.path) else { try reject("集中存储不能位于待重命名文件夹内。") }
                    moves.append(Move(source: oldData.path, target: newData.path)); metadataRoots.append(oldData)
                }
            }
        }
        for (file, header) in validSessions.sorted(by: { $0.key.path < $1.key.path }) {
            let affected = ["cwd", "parentSession"].contains { key in
                guard let path = header[key] as? String else { return false }
                return relocatedPath(path, from: source, to: target, moves: moves) != path
            }
            guard affected || relocatedPath(file.path, from: source, to: target, moves: moves) != file.path else { continue }
            let before = try Data(contentsOf: file)
            let after = try sessionData(before, from: source, to: target, moves: moves)
            let destination = URL(fileURLWithPath: relocatedPath(file.path, from: source, to: target, moves: moves))
            if after != before || destination.path != file.path { edits.append(Edit(source: file, target: destination, before: before, after: after)) }
        }
        // Transaction metadata has path fields; arbitrary plugin JSON, prose and git validation
        // records are not rewritten. Git root worktree gets its own tightly scoped update below.
        for root in metadataRoots {
            for file in try files(in: root) where file.pathExtension == "json" || file.pathExtension == "jsonl" {
                if file.pathExtension == "jsonl" {
                    let before = try Data(contentsOf: file)
                    guard !before.isEmpty else { continue }
                    let after = try sessionData(before, from: source, to: target, moves: moves)
                    let destination = URL(fileURLWithPath: relocatedPath(file.path, from: source, to: target, moves: moves))
                    if after != before || destination.path != file.path {
                        edits.append(Edit(source: file, target: destination, before: before, after: after))
                    }
                    continue
                }
                if file.lastPathComponent == "catalog.json" || file.path.contains("/interruptions/") || file.lastPathComponent == "scene.json" {
                    let before = try Data(contentsOf: file)
                    let object = try JSONSerialization.jsonObject(with: before)
                    let updated = references(object, from: source, to: target, moves: moves)
                    let after = try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])
                    if !(object as! NSObject).isEqual(updated) {
                        let newPath = relocatedPath(file.path, from: source, to: target, moves: moves)
                        edits.append(Edit(source: file, target: URL(fileURLWithPath: newPath), before: before, after: after))
                    }
                }
            }
        }
        for filename in ["resume.json", "last-resume.json"] {
            let file = env.support.appendingPathComponent("updates/" + filename)
            if exists(file) {
                let before = try Data(contentsOf: file), object = try JSONSerialization.jsonObject(with: before)
                let after = try JSONSerialization.data(withJSONObject: references(object, from: source, to: target, moves: moves), options: [.sortedKeys])
                if before != after { edits.append(Edit(source: file, target: file, before: before, after: after)) }
            }
        }
        for file in try files(in: source) where file.lastPathComponent == "f-tree.json" && file.deletingLastPathComponent().lastPathComponent == ".git" {
            let before = try Data(contentsOf: file)
            guard var object = try JSONSerialization.jsonObject(with: before) as? [String: Any], var nodes = object["nodes"] as? [[String: Any]] else { try reject("版本元数据无效，未迁移。") }
            for index in nodes.indices {
                if let old = nodes[index]["worktree"] as? String { nodes[index]["worktree"] = remap(old, from: source, to: target) }
            }
            object["nodes"] = nodes
            let after = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            edits.append(Edit(source: file, target: URL(fileURLWithPath: remap(file.path, from: source, to: target)), before: before, after: after))
        }
        var uniqueEdits: [String: Edit] = [:]
        for edit in edits {
            let key = edit.source.standardizedFileURL.path
            if let prior = uniqueEdits[key], prior.before != edit.before || prior.after != edit.after || prior.target.path != edit.target.path {
                try reject("同一文件出现不一致的迁移计划，未迁移：" + key)
            }
            uniqueEdits[key] = edit
        }
        edits = uniqueEdits.values.sorted { $0.source.path < $1.source.path }
        for edit in edits {
            let attrs = try fm.attributesOfItem(atPath: edit.source.path)
            guard fm.isWritableFile(atPath: edit.source.path),
                  fm.isWritableFile(atPath: edit.source.deletingLastPathComponent().path),
                  ((attrs[.referenceCount] as? NSNumber)?.intValue ?? 1) <= 1 else {
                try reject("需更新的项目数据不可写或存在硬链接，未迁移：" + edit.source.path)
            }
        }
        var defaultsAfter = defaultsBefore
        for key in ["FProjectFolders", "FHiddenProjectFolders"] {
            if let paths = defaultsBefore[key] as? [String] { defaultsAfter[key] = paths.map { remap($0, from: source, to: target) } }
        }
        if let path = defaultsBefore["LastProjectDirectory"] as? String { defaultsAfter["LastProjectDirectory"] = remap(path, from: source, to: target) }
        let bindings = defaultsBefore["FConversationBoardIDs"] as? [String: String] ?? [:]
        var mappedBindings: [String: String] = [:]
        for (path, id) in bindings {
            let new = relocatedPath(path, from: source, to: target, moves: moves)
            if let existing = mappedBindings[new], existing != id { try reject("会话画板绑定冲突。") }
            mappedBindings[new] = id
        }
        for edit in edits where edit.source.pathExtension == "jsonl" && edit.source.path != edit.target.path {
            // Persist the old fallback identity before a session path changes, even if that
            // older session never had an explicit alias. Recomputing SHA(newPath) loses its board.
            let id = bindings[edit.source.standardizedFileURL.path] ?? digest(edit.source.standardizedFileURL.path)
            if let existing = mappedBindings[edit.target.standardizedFileURL.path], existing != id { try reject("会话画板绑定冲突。") }
            mappedBindings[edit.target.standardizedFileURL.path] = id
        }
        if !mappedBindings.isEmpty || defaultsBefore["FConversationBoardIDs"] != nil { defaultsAfter["FConversationBoardIDs"] = mappedBindings }
        for path in projects {
            let old = BoardStore.directory(for: URL(fileURLWithPath: path)).lastPathComponent
            let new = BoardStore.directory(for: URL(fileURLWithPath: remap(path, from: source, to: target))).lastPathComponent
            for (key, value) in defaultsBefore where key == "FPromptHistory." + old || key.hasPrefix("FPromptHistory." + old + ".") {
                let next = "FPromptHistory." + new + key.dropFirst(("FPromptHistory." + old).count)
                guard defaultsBefore[next] == nil else { try reject("输入历史目标已存在，拒绝覆盖。") }
                defaultsAfter.removeValue(forKey: key); defaultsAfter[next] = value
            }
        }
        let directory = transactions.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var journal = Journal(phase: "preparing", source: source.path, target: target.path, moves: moves, files: [])
        let journalURL = directory.appendingPathComponent("journal.json")
        func saveJournal() throws { try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic) }
        try saveJournal()
        let changedKeys = Set(defaultsBefore.keys).union(defaultsAfter.keys).filter { key in
            let old = defaultsBefore[key], new = defaultsAfter[key]
            return !((old as? NSObject)?.isEqual(new) ?? (old == nil && new == nil))
        }
        let defaultsBackup = changedKeys.reduce(into: [String: Any]()) { result, key in if let value = defaultsBefore[key] { result[key] = value } }
        do {
            journal.defaultKeys = changedKeys.sorted()
            try PropertyListSerialization.data(fromPropertyList: defaultsBackup, format: .binary, options: 0).write(to: directory.appendingPathComponent("defaults.plist"), options: .atomic)
            for (index, edit) in edits.enumerated() {
                let backup = directory.appendingPathComponent("file-\(index)")
                try fm.copyItem(at: edit.source, to: backup)
                func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
                journal.files.append(SavedFile(source: edit.source.path, target: edit.target.path, backup: backup.path,
                    beforeSHA256: checksum(edit.before), afterSHA256: checksum(edit.after)))
            }
            journal.phase = "prepared"; try saveJournal()
        } catch {
            journal.phase = "rolledBack"; journal.message = "准备备份失败，未变更原文件：" + error.localizedDescription
            try? saveJournal()
            throw Failure(message: "准备备份失败，原项目未改动：" + error.localizedDescription + "\n日志：" + directory.path)
        }
        var moved: [Move] = [], written: [Int] = []
        var sceneLocks: [(url: URL, inode: UInt64)] = []
        defer {
            for held in sceneLocks {
                let newPath = relocatedPath(held.url.path, from: source, to: target, moves: moves)
                for candidate in Set([held.url.path, newPath]) {
                    if let attrs = try? fm.attributesOfItem(atPath: candidate),
                       (attrs[.systemFileNumber] as? NSNumber)?.uint64Value == held.inode {
                        ProjectSceneWriter.releaseLock(URL(fileURLWithPath: candidate))
                    }
                }
            }
        }
        do {
            try env.checkpoint?("prepared")
            for root in boardRoots {
                guard let lock = try ProjectSceneWriter.acquireLock(for: root.appendingPathComponent("scene.json")) else { try reject("该项目画板仍有写事务，未迁移。") }
                do {
                    let attrs = try fm.attributesOfItem(atPath: lock.path)
                    guard let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else { try reject("无法确认画板锁身份。") }
                    sceneLocks.append((lock, inode))
                } catch { ProjectSceneWriter.releaseLock(lock); throw error }
                let leaseFile = root.appendingPathComponent("harness/leases/leases.json")
                if exists(leaseFile) {
                    guard let state = try JSONSerialization.jsonObject(with: Data(contentsOf: leaseFile)) as? [String: Any],
                          let leases = state["leases"] as? [Any], leases.isEmpty,
                          (state["pins"] as? [Any] ?? []).isEmpty else {
                        try reject("该项目仍有资源租约或正在执行的工具；请由原会话释放，不会删除他人租约。")
                    }
                }
            }
            // A concurrently rewritten session must never be silently overwritten by our snapshot.
            for edit in edits { guard try Data(contentsOf: edit.source) == edit.before else { try reject("迁移期间文件发生变化，已取消。") } }
            for move in moves {
                guard !exists(URL(fileURLWithPath: move.target)) else { try reject("迁移目标刚被占用，已取消。") }
                try fm.moveItem(atPath: move.source, toPath: move.target); moved.append(move)
                try env.checkpoint?("moved")
            }
            for (index, edit) in edits.enumerated() {
                let current: Data
                do { current = try Data(contentsOf: edit.target) }
                catch { try reject("读取迁移数据失败：" + edit.target.path + "；" + error.localizedDescription) }
                guard current == edit.before else { try reject("迁移期间数据发生变化，已取消。") }
                if edit.after == edit.before { continue }
                let attrs = try fm.attributesOfItem(atPath: edit.target.path)
                try edit.after.write(to: edit.target, options: .atomic); written.append(index)
                var preserved: [FileAttributeKey: Any] = [:]
                for key in [FileAttributeKey.posixPermissions, .modificationDate, .creationDate] { preserved[key] = attrs[key] }
                try fm.setAttributes(preserved, ofItemAtPath: edit.target.path)
                try env.checkpoint?("written")
            }
            for key in changedKeys { env.defaults.set(defaultsAfter[key], forKey: key) }
            guard env.defaults.synchronize() else { try reject("项目设置写入失败。") }
            try env.checkpoint?("defaults")
            journal.phase = "committed"; try saveJournal()
            return target
        } catch {
            var failures: [String] = []
            for index in written.reversed() {
                do {
                    let file = journal.files[index]
                    guard try Data(contentsOf: URL(fileURLWithPath: file.target)) == edits[index].after else {
                        throw Failure(message: "回滚文件出现并发修改，保留新内容与原备份：" + file.target)
                    }
                    try Data(contentsOf: URL(fileURLWithPath: file.backup)).write(to: URL(fileURLWithPath: file.target), options: .atomic)
                    let attrs = try fm.attributesOfItem(atPath: file.backup)
                    var preserved: [FileAttributeKey: Any] = [:]
                    for key in [FileAttributeKey.posixPermissions, .modificationDate, .creationDate] { preserved[key] = attrs[key] }
                    try fm.setAttributes(preserved, ofItemAtPath: file.target)
                } catch { failures.append(error.localizedDescription) }
            }
            for move in moved.reversed() {
                do { try fm.moveItem(atPath: move.target, toPath: move.source) } catch { failures.append(error.localizedDescription) }
            }
            for key in changedKeys { env.defaults.set(defaultsBefore[key], forKey: key) }
            if !env.defaults.synchronize() { failures.append("恢复项目设置失败") }
            journal.phase = failures.isEmpty ? "rolledBack" : "rollbackFailed"
            journal.message = error.localizedDescription + (failures.isEmpty ? "" : "；" + failures.joined(separator: "；"))
            do { try saveJournal() } catch { failures.append(error.localizedDescription) }
            throw Failure(message: (failures.isEmpty ? "迁移未完成，已回滚：" : "迁移恢复需要人工处理，未删除备份：") + error.localizedDescription + "\n日志：" + directory.path)
        }
    }
}
