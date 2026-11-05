import AppKit
import AVKit
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

// MARK: - pi RPC

struct AgentModel {
    let provider: String
    let id: String
    let name: String
    let reasoning: Bool
}

final class PiRPC {
    /// 每个项目一个后台 Agent，退出时需要停止全部进程。
    private static let registry = NSHashTable<PiRPC>.weakObjects()
    static func stopAll() { registry.allObjects.forEach { $0.stop() } }

    /// Read-only lifetime query, including standalone/side-agent RPCs outside a window's views.
    /// Never stop a backend to make relocation possible; unrelated cwd values do not block it.
    static func hasRunningAgent(inProject project: URL) -> Bool {
        let root = project.resolvingSymlinksInPath().standardizedFileURL.path
        return registry.allObjects.contains { rpc in
            guard rpc.isRunning, let configured = rpc.configuredProject else { return false }
            let cwd = URL(fileURLWithPath: configured).resolvingSymlinksInPath().standardizedFileURL.path
            return cwd == root || cwd.hasPrefix(root == "/" ? "/" : root + "/")
        }
    }

    var onEvent: (([String: Any]) -> Void)?
    var onExit: ((String) -> Void)?

    private var process: Process?
    private var outPipe: Pipe?
    private var errPipe: Pipe?
    private var buffer = Data()
    private var nextID = 0
    private var callbacks: [String: ([String: Any]) -> Void] = [:]
    private var generation = 0
    private var configuredProject: String?
    private var configuredBoard: String?
    private var configuredConversation: String?
    private var configuredRemoteSocket: String?
    private var configuredPlugins: String?
    private var relocationClose: (id: UUID, completion: (Result<Void, Error>) -> Void)?
    private(set) var isInputClosedForRelocation = false
    var hasPendingRequests: Bool { !callbacks.isEmpty }

    var isRunning: Bool { process?.isRunning ?? false }

    func isConfigured(for project: URL, boardDirectory: URL? = nil, conversationDirectory: URL? = nil) -> Bool {
        let remoteSocket = RemoteProjects.load(project).flatMap { SSHSessions.shared.session($0.connection) }.map { $0.transport.socket }
        return configuredProject == project.standardizedFileURL.path &&
            configuredBoard == (boardDirectory ?? BoardStore.directory(for: project)).path &&
            (conversationDirectory == nil || configuredConversation == conversationDirectory?.path) &&
            configuredRemoteSocket == remoteSocket && configuredPlugins == PluginPreferences.signature
    }

    init() {
        PiRPC.registry.add(self)
    }

    @discardableResult
    func start(cliPath: String, workingDirectory: URL, boardDirectory: URL? = nil, conversationDirectory: URL? = nil) -> Bool {
        guard !isInputClosedForRelocation else { return false }
        stop()
        let connection = generation

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = ["--mode", "rpc"]
        proc.currentDirectoryURL = workingDirectory

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        // 避免继承当前 pi 会话/模型相关变量，应用自己用 switch_session 指定会话
        for key in env.keys where key.hasPrefix("PI_") && key != "PI_CODING_AGENT_DIR" {
            env.removeValue(forKey: key)
        }
        // 告诉 pi 的 whiteboard 工具：画板存在 F 的软件数据目录里（与打开的项目对应）
        let boardDirectory = boardDirectory ?? BoardStore.directory(for: workingDirectory)
        try? FileManager.default.createDirectory(at: boardDirectory, withIntermediateDirectories: true)
        env["F_BOARD_DIR"] = boardDirectory.path
        if let conversationDirectory { env["F_CONVERSATION_DIR"] = conversationDirectory.path }
        else { env.removeValue(forKey: "F_CONVERSATION_DIR") }
        env["F_PROJECT"] = workingDirectory.path
        env["F_LOCAL_PROJECT"] = workingDirectory.standardizedFileURL.path
        if let remote = RemoteProjects.load(workingDirectory) {
            guard let session = SSHSessions.shared.session(remote.connection), session.phase == .connected, session.endpoint == remote.endpoint else {
                onExit?("远程项目的 SSH 尚未登录。")
                return false
            }
            let descriptor: [String: Any] = ["arguments": session.transport.commandArguments, "cwd": remote.path,
                "endpoint": remote.endpoint, "socket": session.transport.socket, "home": session.home]
            guard let data = try? JSONSerialization.data(withJSONObject: descriptor), let json = String(data: data, encoding: .utf8) else { return false }
            configuredRemoteSocket = session.transport.socket
            env["F_REMOTE_PROJECT"] = json
            env["F_PROJECT"] = remote.path
        } else { env.removeValue(forKey: "F_REMOTE_PROJECT") }
        env["F_APP_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        env["F_APP_BUNDLE"] = Bundle.main.bundleURL.path
        env["F_SOURCE_ROOT"] = URL(fileURLWithPath: cliPath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        env["F_DISABLED_PLUGINS"] = PluginPreferences.signature
        let harness = Bundle.main.resourceURL?.appendingPathComponent("runtime/harness")
        if let harness, FileManager.default.fileExists(atPath: harness.appendingPathComponent("src/index.mjs").path) {
            env["F_HARNESS_DIR"] = harness.path
        }
        proc.environment = env

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == connection else { return }
                self.consume(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        proc.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.generation == connection, self.process === finished else { return }
                self.outPipe?.fileHandleForReading.readabilityHandler = nil
                self.errPipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                let wasRelocation = self.isInputClosedForRelocation
                self.isInputClosedForRelocation = false
                let close = self.relocationClose
                self.relocationClose = nil
                let pending = self.callbacks
                self.callbacks.removeAll()
                pending.values.forEach { $0(["success": false, "error": "pi 连接已断开"]) }
                self.onExit?(wasRelocation ? "空闲会话已自然关闭" : "pi 连接已断开（退出码 \(finished.terminationStatus)）")
                if finished.terminationReason == .exit, finished.terminationStatus == 0 { close?.completion(.success(())) }
                else { close?.completion(.failure(ProjectMutation.Failure(message: "会话退出异常，保留原状态，请正常退出并重开 F。"))) }
            }
        }

        do {
            try proc.run()
        } catch {
            onExit?("无法启动 pi：\(error.localizedDescription)")
            return false
        }

        process = proc
        configuredProject = workingDirectory.standardizedFileURL.path
        configuredBoard = boardDirectory.path
        configuredConversation = conversationDirectory?.path
        configuredPlugins = PluginPreferences.signature
        outPipe = output
        errPipe = errors
        buffer.removeAll()
        nextID = 0
        callbacks.removeAll()
        return true
    }

    func stop() {
        generation += 1
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if let previous = process {
            previous.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if previous.isRunning { kill(previous.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        configuredProject = nil
        configuredBoard = nil
        configuredConversation = nil
        configuredRemoteSocket = nil
        configuredPlugins = nil
        callbacks.removeAll()
        buffer.removeAll()
    }

    /// Caller must verify UI/model/queue idleness immediately before invoking this method.
    /// EOF is the only shutdown request: timeout leaves the process and its handlers alive.
    func closeInputAndWaitForRelocation(timeout: TimeInterval = 8, completion: @escaping (Result<Void, Error>) -> Void) {
        guard relocationClose == nil, !isInputClosedForRelocation else {
            completion(.failure(ProjectMutation.Failure(message: "该会话已在等待自然退出，请勿重复关闭；超时后可正常退出并重开 F。"))); return
        }
        guard callbacks.isEmpty else {
            completion(.failure(ProjectMutation.Failure(message: "会话仍有 RPC 请求，未关闭输入。"))); return
        }
        guard let process, process.isRunning else { completion(.success(())); return }
        guard let pipe = process.standardInput as? Pipe else {
            completion(.failure(ProjectMutation.Failure(message: "无法安全关闭会话输入，未终止进程。"))); return
        }
        let id = UUID()
        relocationClose = (id, completion)
        isInputClosedForRelocation = true
        do { try pipe.fileHandleForWriting.close() } catch {
            relocationClose = nil
            // The descriptor might already be closed. Keep the fail-closed state until exit.
            completion(.failure(ProjectMutation.Failure(message: "关闭会话输入失败，保留状态且未终止进程：" + error.localizedDescription))); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, timeout)) { [weak self] in
            guard let self, self.relocationClose?.id == id, self.process === process else { return }
            let callback = self.relocationClose?.completion
            self.relocationClose = nil
            callback?(.failure(ProjectMutation.Failure(message: "等待会话自然退出超时，未发送 terminate/SIGKILL；状态已保留，请正常退出并重开 F。")))
        }
    }

    func request(_ command: [String: Any], completion: (([String: Any]) -> Void)? = nil) {
        guard !isInputClosedForRelocation else {
            completion?(["success": false, "error": "会话正在自然退出，尚未重连；请稍候或正常退出并重开 F。"]); return
        }
        guard let process, process.isRunning, let pipe = process.standardInput as? Pipe else {
            completion?(["success": false, "error": "pi 未运行"])
            return
        }

        var payload = command
        let id = "c\(nextID)"
        nextID += 1
        payload["id"] = id
        if let completion { callbacks[id] = completion }

        do {
            var data = try JSONSerialization.data(withJSONObject: payload)
            data.append(0x0A)
            try pipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            callbacks.removeValue(forKey: id)?(["success": false, "error": "无法发送到 pi：\(error.localizedDescription)"])
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let raw = try? JSONSerialization.jsonObject(with: Data(line)),
                  let object = raw as? [String: Any]
            else { continue }

            if object["type"] as? String == "response",
               let id = object["id"] as? String,
               let completion = callbacks.removeValue(forKey: id) {
                completion(object)
            } else {
                onEvent?(object)
            }
        }
    }
}

