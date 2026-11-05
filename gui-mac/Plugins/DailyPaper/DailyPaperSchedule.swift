import Foundation
import Darwin

/// F owns this per-user launchd job. It starts the signed F executable in a
/// headless update mode, so neither Codex nor an open F window is required.
final class DailyPaperSchedule {
    static let preference = "FDailyPaperAutoUpdate"
    let directory: URL
    let defaults: UserDefaults
    let label: String
    private let agents: URL
    private let command: ([String]) throws -> Int32
    init(directory: URL, defaults: UserDefaults = .standard, agents: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"), label: String = "local.f.app.daily-paper.updater", command: (([String]) throws -> Int32)? = nil) {
        self.directory = directory; self.defaults = defaults; self.agents = agents; self.label = label
        self.command = command ?? { arguments in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
    }
    var automatic: Bool { defaults.bool(forKey: Self.preference) }
    private var domain: String { "gui/\(getuid())" }
    var plist: URL { agents.appendingPathComponent(label + ".plist") }
    func definition(executable: URL) -> [String: Any] {
        ["Label": label, "ProgramArguments": [executable.path, "--daily-paper-update"],
         "StartCalendarInterval": ["Hour": 9, "Minute": 0], "StartInterval": 900,
         "RunAtLoad": true, "ProcessType": "Background", "LowPriorityIO": true, "Nice": 10,
         "StandardOutPath": directory.appendingPathComponent("scheduler.log").path,
         "StandardErrorPath": directory.appendingPathComponent("scheduler.log").path]
    }
    func install(executable: URL) throws {
        guard automatic else { return }
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if (try? plist.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw DailyPaperError.message("F 每日更新配置为符号链接，未修改。") }
        let expected = definition(executable: executable)
        let current = (try? Data(contentsOf: plist)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let loaded = try command(["print", domain + "/" + label]) == 0
        if loaded, let current, NSDictionary(dictionary: current).isEqual(to: expected) { return }
        if loaded, try command(["bootout", domain + "/" + label]) != 0 { throw DailyPaperError.message("无法停止旧的 F 每日更新配置。") }
        let data = try PropertyListSerialization.data(fromPropertyList: expected, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
        guard try command(["bootstrap", domain, plist.path]) == 0 else { throw DailyPaperError.message("系统未能启用 F 每日更新，请在设置中重新开启。") }
    }
    func uninstall() throws {
        if try command(["print", domain + "/" + label]) == 0,
           try command(["bootout", domain + "/" + label]) != 0 { throw DailyPaperError.message("系统未能关闭 F 每日更新。") }
        if FileManager.default.fileExists(atPath: plist.path) { try FileManager.default.removeItem(at: plist) }
    }
    func cancelBackground() {
        _ = try? command(["kill", "SIGTERM", domain + "/" + label])
    }
    func startIfIdle() { _ = try? command(["kickstart", domain + "/" + label]) } // No -k: never replace a running job.
    static func isDue(_ state: DailyPaperState, at date: Date = Date()) -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        guard calendar.component(.hour, from: date) >= 9 else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyyMMdd"
        return state.sourceMode != "alphaxiv-links-v1" || state.records.isEmpty || state.currentBatch?.hasSuffix("-" + formatter.string(from: date)) != true
    }
    static func processAlive(_ file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return false }
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
    static func runHeadless() {
        let root = PluginStorage.directory(for: "daily-paper"), defaults = UserDefaults.standard
        guard defaults.bool(forKey: preference), PluginPreferences.isEnabled("daily-paper") else { return }
        // A pending application update must not race a new headless process.
        guard !FileManager.default.fileExists(atPath: BoardStore.appSupport.appendingPathComponent("updates/pending.json").path) else { return }
        do {
            let state = try DailyPaperStore(directory: root).load()
            guard isDue(state) else { return }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let pidFile = root.appendingPathComponent("scheduler.pid")
            try String(getpid()).write(to: pidFile, atomically: true, encoding: .utf8)
            let worker = DailyPaperWorker()
            let task = Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: pidFile) }
                do {
                    let value = try await worker.update(directory: root, scheduled: true) { print($0) }
                    let data = try JSONSerialization.data(withJSONObject: ["ok": true, "value": value], options: [.sortedKeys])
                    print(String(data: data, encoding: .utf8)!); try? FileManager.default.removeItem(at: pidFile); exit(0)
                } catch { fputs("Daily Paper：\(error.localizedDescription)\n", stderr); try? FileManager.default.removeItem(at: pidFile); exit(1) }
            }
            let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
                Darwin.signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { task.cancel(); worker.cancel() }; source.resume(); return source
            }
            withExtendedLifetime(signals) { RunLoop.main.run() }
        } catch { fputs("Daily Paper：\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
