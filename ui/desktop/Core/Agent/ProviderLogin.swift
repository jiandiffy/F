import AppKit

/// One independent login terminal per source; the running conversation is left intact.
final class ProviderLogin: NSObject, NSWindowDelegate {
    static let shared = ProviderLogin()
    static let sources = ["dp", "gpt", "cbc", "cbi"]
    private struct Login {
        let window: NSWindow
        let terminal: TerminalView
        let receipt: URL
        var completions: [(Bool) -> Void]
    }
    private var logins: [String: Login] = [:]
    private var checks: [String: [(Bool) -> Void]] = [:]
    private var failedWindows: [NSWindow] = []

    func ensure(_ source: String, relativeTo parent: NSWindow?, completion: @escaping (Bool) -> Void) {
        guard Self.sources.contains(source) else { completion(true); return }
        if var login = logins[source] {
            login.completions.append(completion); logins[source] = login
            login.window.makeKeyAndOrderFront(nil); login.terminal.focus(); return
        }
        if checks[source] != nil { checks[source]?.append(completion); return }
        checks[source] = [completion]
        status(source) { [weak self, weak parent] authenticated in
            guard let self, let waiting = self.checks.removeValue(forKey: source) else { return }
            if authenticated { waiting.forEach { $0(true) }; return }
            self.open(source, relativeTo: parent, completions: waiting)
        }
    }

    private func status(_ source: String, completion: @escaping (Bool) -> Void) {
        guard let cli = PiPaths.cliPath else { completion(false); return }
        let executable = PiPaths.nodeURL(for: cli)
        let helper = URL(fileURLWithPath: cli).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/provider-auth.mjs")
        let environment = PiPaths.environment(for: cli, agentDirectory: PiHistory.agentDirectory()?.deletingLastPathComponent())
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process(), output = Pipe()
            task.executableURL = executable; task.arguments = [helper.path, "status", source]
            task.environment = environment; task.standardOutput = output; task.standardError = FileHandle.nullDevice
            var authenticated = false
            do {
                try task.run()
                let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
                if task.terminationStatus == 0,
                   let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    authenticated = value["authenticated"] as? Bool ?? false
                }
            } catch { }
            DispatchQueue.main.async { completion(authenticated) }
        }
    }

    private func open(_ source: String, relativeTo parent: NSWindow?, completions: [(Bool) -> Void]) {
        guard let cli = PiPaths.cliPath else { completions.forEach { $0(false) }; return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = source == "dp" ? "DP · 输入 API key" : "\(source.uppercased()) · 登录"
        window.isReleasedWhenClosed = false; window.delegate = self
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 860, height: 480))
        terminal.autoresizingMask = [.width, .height]; terminal.applyTheme(dark: AppearanceStore.dark)
        window.contentView = terminal
        let receipt = PiPaths.userDataDirectory.appendingPathComponent("auth/login/results/\(UUID().uuidString).json")
        logins[source] = Login(window: window, terminal: terminal, receipt: receipt, completions: completions)
        terminal.onExit = { [weak self] in self?.finished(source) }
        if let parent { window.setFrameOrigin(NSPoint(x: parent.frame.midX - 430, y: parent.frame.midY - 240)) }
        else { window.center() }
        window.makeKeyAndOrderFront(nil)
        let helper = URL(fileURLWithPath: cli).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/provider-auth.mjs")
        var environment = PiPaths.environment(for: cli, agentDirectory: PiHistory.agentDirectory()?.deletingLastPathComponent())
        environment["F_LOGIN_RESULT_FILE"] = receipt.path
        terminal.startCommand(PiPaths.nodeURL(for: cli).path, arguments: [helper.path, "login", source],
            in: PiPaths.userDataDirectory, environment: environment)
        terminal.focus()
    }

    private func finished(_ source: String) {
        guard let pending = logins[source] else { return }
        let value = (try? Data(contentsOf: pending.receipt)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard value?["authenticated"] as? Bool == true else { complete(source, authenticated: false); return }
        status(source) { [weak self] authenticated in
            self?.complete(source, authenticated: authenticated)
        }
    }

    private func complete(_ source: String, authenticated: Bool) {
            guard let login = logins.removeValue(forKey: source) else { return }
            login.terminal.onExit = nil
            login.terminal.stop()
            try? FileManager.default.removeItem(at: login.receipt)
            if authenticated { login.window.close() }
            // On failure, leave the terminal's explanation visible until the user closes it.
            else { self.failedWindows.append(login.window) }
            login.completions.forEach { $0(authenticated) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        failedWindows.removeAll { $0 === window }
        guard
              let source = logins.first(where: { $0.value.window === window })?.key,
              let login = logins.removeValue(forKey: source) else { return }
        login.terminal.onExit = nil; login.terminal.stop()
        try? FileManager.default.removeItem(at: login.receipt)
        login.completions.forEach { $0(false) }
    }
}
