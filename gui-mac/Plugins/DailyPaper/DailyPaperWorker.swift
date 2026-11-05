import Foundation

/// Owns only the dedicated importer process. JSON uses stdin; credentials stay
/// in the existing readonly Keychain item and never enter argv or logs.
final class DailyPaperWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        if child?.isRunning == true { child?.terminate() }
    }
    func update(directory: URL, scheduled: Bool = false, progress: @escaping (String) -> Void) async throws -> [String: Any] {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard let cli = Bundle.main.object(forInfoDictionaryKey: "PiCLIPath") as? String, !cli.isEmpty,
                      let script = Bundle.main.resourceURL?.appendingPathComponent("harness/src/daily-paper/cli.mjs"), FileManager.default.fileExists(atPath: script.path) else {
                    continuation.resume(throwing: DailyPaperError.message("论文链接更新资源缺失，请完成 F 更新后重试。")); return
                }
                let root = URL(fileURLWithPath: cli).deletingLastPathComponent().deletingLastPathComponent()
                let child = Process(), input = Pipe(), output = Pipe()
                child.executableURL = root.appendingPathComponent("runtime/node/bin/node")
                child.arguments = ["--use-env-proxy", script.path]
                child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
                do {
                    let request = try JSONSerialization.data(withJSONObject: ["root": directory.path, "pi": cli, "scheduled": scheduled])
                    lock.lock()
                    if cancelled { lock.unlock(); throw CancellationError() }
                    do { try child.run(); process = child; lock.unlock() } catch { lock.unlock(); throw error }
                    DispatchQueue.global(qos: .utility).async { [self] in
                        var response: [String: Any]?, buffer = Data(), received = 0
                        do {
                            try input.fileHandleForWriting.write(contentsOf: request); try input.fileHandleForWriting.close()
                            while let data = try output.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                                received += data.count
                                guard received <= 2_000_000 else { cancel(); throw DailyPaperError.message("论文链接状态输出异常，操作已取消。") }
                                buffer.append(data)
                                while let newline = buffer.firstIndex(of: 10) {
                                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                                    guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                                    if let message = value["status"] as? String { progress(message) }
                                    if value["ok"] != nil { response = value }
                                }
                            }
                            child.waitUntilExit()
                            lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock()
                            if wasCancelled { throw CancellationError() }
                            guard child.terminationStatus == 0, response?["ok"] as? Bool == true, let value = response?["value"] as? [String: Any] else { throw DailyPaperError.message(response?["error"] as? String ?? "论文链接未更新，原卡片保留。") }
                            continuation.resume(returning: value)
                        } catch {
                            if child.isRunning { child.terminate() }; child.waitUntilExit()
                            lock.lock(); process = nil; lock.unlock()
                            continuation.resume(throwing: error)
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }, onCancel: { self.cancel() })
    }
}
