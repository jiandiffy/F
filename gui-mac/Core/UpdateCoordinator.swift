import AppKit

struct UpdateResume: Codable {
    var id: String
    var project: String
    var session: String?
    var mainDraft = ""
    var boardDraft = ""
    var provider: String?
    var model: String?
    var modelName: String?
    var thinking = "high"
    var announcement: String
    var noticeProject: String?
    var noticeSession: String?
    var background: [UpdateResume]?
    var boardID: String?
    var interruption: ConversationInterruption?
}

/// A durable continuation, not a snapshot of the model's private reasoning or OS processes.
struct ConversationInterruption: Codable {
    var updateID: String
    var date = Date()
    var prompt: QueuedPrompt?
    var promptWasSent: Bool
    var promptCompleted: Bool?
    var queue: [QueuedPrompt]
    var queuePaused: Bool
}

/// The host, never the child Agent, owns quitting and restarting F.
final class UpdateCoordinator {
    static var root: URL { BoardStore.appSupport.appendingPathComponent("updates", isDirectory: true) }
    private let host: RootView
    private var timer: Timer?
    private var checking = false
    private var ignoredID: String?
    private var activeID: String?
    private var restore: UpdateResume?
    private var helper: Process?

    init(host: RootView) {
        self.host = host
        let resumeURL = Self.root.appendingPathComponent("resume.json")
        if let data = try? Data(contentsOf: resumeURL), var resume = try? JSONDecoder().decode(UpdateResume.self, from: data), Self.validID(resume.id) {
            // Also supports updates submitted by a host predating origin-aware announcements.
            if let manifestData = try? Data(contentsOf: Self.root.appendingPathComponent("pending.json")),
               let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
               manifest["id"] as? String == resume.id {
                resume.noticeProject = manifest["originProject"] as? String
                resume.noticeSession = manifest["originSession"] as? String
            }
            restore = resume
            ignoredID = resume.id
            try? JSONEncoder().encode(resume).write(to: Self.root.appendingPathComponent("last-resume.json"), options: .atomic)
            host.restoreAfterUpdate(resume)
        }
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    deinit { timer?.invalidate() }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.range(of: #"^[a-f0-9-]+$"#, options: .regularExpression) != nil
    }
    static func markBoot() {
        let path = root.appendingPathComponent("resume.json")
        guard let data = try? Data(contentsOf: path), let resume = try? JSONDecoder().decode(UpdateResume.self, from: data), validID(resume.id) else { return }
        let directory = root.appendingPathComponent(resume.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pid = try? JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier])
        try? pid?.write(to: directory.appendingPathComponent("boot.json"), options: .atomic)
    }

    private func tick() {
        if let resume = restore, host.isUpdateUIReady {
            do {
                let directory = Self.root.appendingPathComponent(resume.id)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("ready".utf8).write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
                // Consume the restart snapshot before dispatching any side-effecting continuation.
                // If this fails, keep the conversations suspended rather than replay them on next boot.
                try FileManager.default.removeItem(at: Self.root.appendingPathComponent("resume.json"))
                restore = nil
                host.continueAfterUpdate()
            } catch {
                host.showUpdateError("恢复状态提交失败，对话保持暂停：" + error.localizedDescription)
                return
            }
        }
        guard restore == nil, !checking, activeID == nil, host.window?.attachedSheet == nil,
              let data = try? Data(contentsOf: Self.root.appendingPathComponent("pending.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = manifest["id"] as? String, Self.validID(id), id != ignoredID,
              let target = manifest["target"] as? String,
              URL(fileURLWithPath: target).resolvingSymlinksInPath() == Bundle.main.bundleURL.resolvingSymlinksInPath(),
              let announcement = manifest["announcement"] as? String, !announcement.isEmpty, announcement.count <= 100,
              let helperURL = Bundle.main.url(forResource: "update-helper", withExtension: "py"),
              host.canBeginUpdate(originSession: manifest["originSession"] as? String) else { return }
        checking = true
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helperURL.path, Self.root.appendingPathComponent("pending.json").path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        process.terminationHandler = { [weak self] completed in
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self else { return }
                guard completed.terminationStatus == 0 else {
                    self.checking = false
                    self.ignoredID = id
                    self.host.showUpdateError("更新校验失败，当前版本继续运行。" + String(decoding: errorData.suffix(600), as: UTF8.self))
                    return
                }
                guard self.host.canBeginUpdate(originSession: manifest["originSession"] as? String), self.host.window?.attachedSheet == nil else {
                    self.checking = false
                    return
                }
                self.host.interruptForUpdate(id: id) { result in
                    self.checking = false
                    switch result {
                    case .success:
                        guard self.host.canRestartForUpdate, self.host.window?.attachedSheet == nil else {
                            self.host.continueAfterUpdate(); return
                        }
                        self.install(id: id, announcement: announcement, helperURL: helperURL,
                            originProject: manifest["originProject"] as? String, originSession: manifest["originSession"] as? String)
                    case .failure(let error):
                        self.ignoredID = id
                        self.host.continueAfterUpdate()
                        self.host.showUpdateError("中断历史保存失败，未重启：" + error.localizedDescription)
                    }
                }
            }
        }
        do { try process.run() } catch { checking = false; ignoredID = id; host.showUpdateError(error.localizedDescription) }
    }

    private func install(id: String, announcement: String, helperURL: URL, originProject: String?, originSession: String?) {
        do {
            var resume = host.prepareUpdateResume(id: id, announcement: announcement)
            resume.noticeProject = originProject
            resume.noticeSession = originSession
            try JSONEncoder().encode(resume).write(to: Self.root.appendingPathComponent("resume.json"), options: .atomic)
            // Copy the running helper outside the bundle before replacing any of its contents.
            let detached = Self.root.appendingPathComponent(id).appendingPathComponent("install.py")
            try Data(contentsOf: helperURL).write(to: detached, options: .atomic)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [detached.path, Self.root.appendingPathComponent("pending.json").path, "--wait-pid", String(ProcessInfo.processInfo.processIdentifier)]
            let log = Self.root.appendingPathComponent(id).appendingPathComponent("install.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = handle
            try process.run()
            helper = process; activeID = id
            FApplicationLifecycle.requestTermination()
        } catch {
            ignoredID = id
            discardResumeAndContinue()
            host.showUpdateError(error.localizedDescription)
        }
    }
    private func discardResumeAndContinue() {
        do {
            let path = Self.root.appendingPathComponent("resume.json")
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            host.continueAfterUpdate()
        } catch {
            // Never continue now and then replay the same saved task on a later normal launch.
            host.showUpdateError("取消恢复状态失败，对话保持暂停：" + error.localizedDescription)
        }
    }
    func cancelQuit() {
        if let id = activeID { ignoredID = id }
        activeID = nil
        helper?.terminate(); helper = nil
        discardResumeAndContinue()
    }
}
