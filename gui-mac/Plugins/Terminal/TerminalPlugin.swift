import AppKit
import AVKit
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

// MARK: - 终端

private final class TerminalMessageBridge: NSObject, WKScriptMessageHandler {
    weak var owner: TerminalView?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receiveTerminalMessage(message) }
}

final class TerminalView: NSView {
    private let webView: WKWebView
    private let terminalBridge = TerminalMessageBridge()
    private var ready = false
    private var pendingOutput = Data()
    private var pendingFocus = false
    private(set) var renderedText = ""
    private(set) var terminalState: [String: Any] = [:]
    private var columns = 100
    private var rows = 20
    private var master: Int32 = -1
    private var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var generation = 0
    var onOutput: ((Data) -> Void)?
    var onExit: (() -> Void)?
    private(set) var directory: URL?
    private var shellSupportDirectory: URL?
    /// 终端配色跟随 F 的黑白主题；新建的终端也按当前主题初始化。
    private var darkTheme = AppearanceStore.dark

    var isRunning: Bool { pid > 0 && master >= 0 }

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        let root = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("terminal")
        configuration.setURLSchemeHandler(WhiteboardSchemeHandler(root: root), forURLScheme: "fterm")
        webView = WKWebView(frame: frameRect, configuration: configuration)
        super.init(frame: frameRect)
        configuration.userContentController.add(terminalBridge, name: "fterm")
        terminalBridge.owner = self
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        webView.load(URLRequest(url: URL(string: "fterm://app/index.html")!))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    convenience init(frame: NSRect, shellSupportDirectory: URL) {
        self.init(frame: frame)
        self.shellSupportDirectory = shellSupportDirectory
    }

    deinit {
        stop()
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
        if ready { webView.evaluateJavaScript("window.FT.fit()", completionHandler: nil) }
        updateWindowSize()
    }

    func focus() {
        pendingFocus = true
        window?.makeFirstResponder(webView)
        if ready { webView.evaluateJavaScript("window.FT.focus()", completionHandler: nil) }
    }

    /// 切换黑白主题：背景、前景和 ANSI 配色一起换，不重建会话。
    func applyTheme(dark: Bool) {
        darkTheme = dark
        guard ready else { return }
        webView.evaluateJavaScript("window.FT.setTheme('\(dark ? "dark" : "light")')", completionHandler: nil)
    }

    func start(in directory: URL) {
        let support = prepareShell()
        let resolvedPath = Self.realPath(directory.path)
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["F_PROJECT"] = resolvedPath
        try? FileManager.default.createDirectory(
            at: BoardStore.directory(for: directory),
            withIntermediateDirectories: true
        )
        environment["F_BOARD_DIR"] = BoardStore.directory(for: directory).path
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:" + inheritedPath
        if let support { environment["ZDOTDIR"] = support.path }

        startCommand("/bin/zsh", arguments: ["-i"], in: directory, environment: environment)
    }

    func startCommand(_ executable: String, arguments: [String], in directory: URL,
                      environment: [String: String]? = nil) {
        stop()
        self.directory = directory
        renderedText = ""; terminalState = [:]; pendingOutput.removeAll()
        if ready { webView.evaluateJavaScript("window.FT.reset(\(generation))", completionHandler: nil) }
        let resolvedPath = Self.realPath(directory.path)
        var environment = environment ?? ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let envStrings = environment.map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { envp.compactMap { $0 }.forEach { free($0) }; argv.compactMap { $0 }.forEach { free($0) } }
        let executablePointer = strdup(executable)
        defer { free(executablePointer) }
        var masterFD: Int32 = -1
        let child = forkpty(&masterFD, nil, nil, nil)
        if child == 0 {
            _ = chdir(resolvedPath)
            execve(executablePointer!, &argv, &envp)
            _exit(127)
        }

        guard child > 0 else {
            appendPlain("无法启动终端。\n")
            return
        }

        master = masterFD
        pid = child
        updateWindowSize()
        startReading(fd: masterFD)
        focus()
    }

    func stop() {
        generation += 1
        let hadSource = readSource != nil
        readSource?.cancel()
        readSource = nil

        if pid > 0 {
            kill(-pid, SIGHUP)
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 {
                usleep(60_000)
                kill(-pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
            }
        }
        if master >= 0 && !hadSource { close(master) }
        master = -1
        pid = 0
    }

    // MARK: shell

    private func prepareShell() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = shellSupportDirectory ?? base.appendingPathComponent("F/term", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.zshrc.write(to: dir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return dir
    }

    private static func realPath(_ path: String) -> String {
        guard let pointer = realpath(path, nil) else { return path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static let zshrc = #"""
    setopt prompt_subst
    autoload -Uz add-zsh-hook compinit
    compinit -u -d "${ZDOTDIR}/.zcompdump" 2>/dev/null

    HISTFILE="${ZDOTDIR}/.zsh_history"
    HISTSIZE=5000
    SAVEHIST=5000
    setopt hist_ignore_dups share_history

    PROMPT='${F_PATH} %% '

    _f_refresh_path() {
      local p="$PWD"
      if [[ -n "$F_PROJECT" && "$p" == "$F_PROJECT" ]]; then
        p="~"
      elif [[ -n "$F_PROJECT" && "$p" == "$F_PROJECT"/* ]]; then
        p="~${p#$F_PROJECT}"
      elif [[ "$p" == "$HOME" ]]; then
        p="~"
      elif [[ "$p" == "$HOME"/* ]]; then
        p="~${p#$HOME}"
      fi
      F_PATH="$p"
    }

    add-zsh-hook precmd _f_refresh_path
    _f_refresh_path
    """#

    // MARK: pty

    private func startReading(fd: Int32) {
        let token = generation
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer[0..<count])
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.feed(data)
                    self.onOutput?(data)
                }
            } else if count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN) {
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.stop()
                    self.onExit?()
                }
            }
        }
        source.resume()
        readSource = source
    }

    func send(_ data: Data) { write(data) }

    private func write(_ data: Data) {
        guard master >= 0 else { return }
        data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            _ = Darwin.write(master, base, pointer.count)
        }
    }

    private func updateWindowSize() {
        guard master >= 0 else { return }
        let columns = max(2, self.columns)
        let rows = max(2, self.rows)
        var size = winsize(
            ws_row: UInt16(min(rows, Int(UInt16.max))),
            ws_col: UInt16(min(columns, Int(UInt16.max))),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    // MARK: VT rendering / PTY bridge

    private func feed(_ data: Data) {
        guard ready else { pendingOutput.append(data); return }
        webView.evaluateJavaScript("window.FT.write('\(data.base64EncodedString())',\(generation))", completionHandler: nil)
    }
    private func appendPlain(_ text: String) { feed(Data(text.utf8)) }

    fileprivate func receiveTerminalMessage(_ message: WKScriptMessage) {
        guard let value = message.body as? [String: Any], let kind = value["type"] as? String else { return }
        if kind == "ready" {
            ready = true
            webView.evaluateJavaScript("window.FT.setTheme('\(darkTheme ? "dark" : "light")')", completionHandler: nil)
            webView.evaluateJavaScript("window.FT.reset(\(generation))", completionHandler: nil)
            let output = pendingOutput; pendingOutput.removeAll()
            if !output.isEmpty { feed(output) }
            if pendingFocus { focus() }
            return
        }
        guard value["epoch"] as? Int == generation else { return }
        switch kind {
        case "input": if let text = value["data"] as? String { write(Data(text.utf8)) }
        case "binary": if let text = value["data"] as? String, let data = Data(base64Encoded: text) { write(data) }
        case "resize":
            columns = value["cols"] as? Int ?? columns
            rows = value["rows"] as? Int ?? rows
            updateWindowSize()
        case "screen": renderedText = value["text"] as? String ?? ""; terminalState = value
        case "copy":
            if let text = value["data"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        default: break
        }
    }
}


final class TerminalPlugin: FPlugin, FProcessProvider {
    let id = "terminal"
    let title = "终端"
    let symbol = "terminal"
    let placement = PluginPlacement.bottom
    let projectAssociation = PluginProjectAssociation.project
    let processDefaultName = "terminal"
    let terminal = TerminalView(frame: .zero)
    var view: NSView { terminal }
    private var project: URL
    private var active = false

    init(project: URL) { self.project = RemoteProjects.load(project) == nil ? project : FileManager.default.homeDirectoryForCurrentUser }
    func makeProcess(project: URL) -> FPlugin { TerminalPlugin(project: project) }
    func projectDidChange(_ project: URL) {
        self.project = RemoteProjects.load(project) == nil ? project : FileManager.default.homeDirectoryForCurrentUser
        if active { activate() }
    }
    func activate() {
        active = true
        if !terminal.isRunning || terminal.directory?.path != project.path { terminal.start(in: project) }
        else { terminal.focus() }
    }
    func applyAppearance(dark: Bool) { terminal.applyTheme(dark: dark) }
    func deactivate() { active = false }
    func shutdown() { active = false; terminal.stop() }
}
