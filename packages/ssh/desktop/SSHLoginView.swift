import AppKit

final class SSHPlugin: FPlugin, FProcessProvider {
    let id = "ssh", title = "SSH", symbol = "network"
    let placement = PluginPlacement.bottom
    let projectAssociation = PluginProjectAssociation.project
    let processDefaultName = "ssh"
    let panel: SSHPanelView
    /// 只有注册表里的模块实例负责结束共享 SSH 会话；停靠区里的进程只结束自己。
    private let ownsSharedSessions: Bool
    var view: NSView { panel }
    var browser: RemoteBrowserView { panel.browser }
    var sidebarView: NSView? { browser }
    var onRequestSidebar: (() -> Void)? { get { nil } set {} }
    init(ownsSharedSessions: Bool = true) {
        self.ownsSharedSessions = ownsSharedSessions
        panel = SSHPanelView(frame: .zero)
    }
    func makeProcess(project: URL) -> FPlugin { SSHPlugin(ownsSharedSessions: false) }
    func activate() { panel.activate() }
    func applyAppearance(dark: Bool) { panel.applyTheme(dark: dark) }
    func reselect() { panel.showLogin() }
    func projectDidChange(_ project: URL) { panel.bindProject(RemoteProjects.load(project)) }
    func shutdown() { if ownsSharedSessions { SSHSessions.shared.shutdown() } }
    func confirmClose(_ completion: @escaping (Bool) -> Void) { panel.confirmClose(completion) }
}

/// Enter is the sole submit action. Connected state contains only the remote terminal.
final class SSHPanelView: NSView, NSComboBoxDelegate {
    let browser = RemoteBrowserView(frame: .zero)
    private let address = NSComboBox(frame: .zero)
    private let secret = NSSecureTextField(string: "")
    private let hostKeyAnswer = NSTextField(string: "")
    private let hint = NSTextField(labelWithString: "")
    private let configButton = NSButton()
    private let configEditor = SSHConfigEditor()
    private let terminalHost = NSView()
    private var shellTerminal: TerminalView?
    private var shellKey: String?
    private var usesAuthTerminal = false
    private(set) var session: SSHSession?
    private var observer: NSObjectProtocol?
    private var project: RemoteProject?
    private weak var browserTransport: SSHTransport?
    private var browserProjectID = ""
    /// SSH 登录页和终端一起跟随 F 的黑白主题。
    private var dark = AppearanceStore.dark

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        applyTheme(dark: dark)
        address.isBordered = false; address.drawsBackground = false
        address.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        address.textColor = .labelColor; address.focusRingType = .none
        address.placeholderString = "user@host:port"
        address.completes = true; address.hasVerticalScroller = true
        address.delegate = self
        address.setAccessibilityLabel("SSH 地址")
        addSubview(address)
        for field in [secret, hostKeyAnswer] {
            field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
            field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            field.textColor = .labelColor
            field.target = self; field.action = #selector(submitAnswer)
            addSubview(field)
        }
        secret.placeholderString = "密码 · Enter 登录"
        secret.setAccessibilityLabel("SSH 密码")
        hostKeyAnswer.placeholderString = "输入 yes 确认主机指纹"
        hostKeyAnswer.setAccessibilityLabel("确认 SSH 主机指纹")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 3
        hint.lineBreakMode = .byTruncatingTail
        addSubview(hint)
        configButton.isBordered = false
        configButton.image = NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: "编辑 SSH config")
        configButton.contentTintColor = .secondaryLabelColor
        configButton.toolTip = "编辑 ~/.ssh/config"
        configButton.target = self; configButton.action = #selector(editConfig)
        addSubview(configButton)
        addSubview(terminalHost)
        observer = NotificationCenter.default.addObserver(forName: .fSSHChanged, object: nil, queue: .main) { [weak self] note in
            if let changed = note.object as? SSHSession, changed === self?.session { self?.sync() }
            self?.syncBrowser()
        }
        sync()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; releaseShell() }

    func applyTheme(dark: Bool) {
        self.dark = dark
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        layer?.backgroundColor = BottomPanel.background(dark: dark).cgColor
        shellTerminal?.applyTheme(dark: dark)
    }
    override func layout() {
        super.layout()
        terminalHost.frame = bounds
        let width = min(420, max(80, bounds.width - 56))
        let x = max(12, (bounds.width - width) / 2), y = max(36, bounds.height / 2)
        address.frame = NSRect(x: x, y: y, width: max(40, width - 38), height: 27)
        secret.frame = NSRect(x: x, y: y, width: width, height: 27)
        hostKeyAnswer.frame = secret.frame
        configButton.frame = NSRect(x: x + width - 28, y: y, width: 26, height: 26)
        hint.frame = NSRect(x: x, y: max(0, y - 46), width: width, height: 38)
    }
    func activate() {
        let current = address.stringValue
        address.removeAllItems()
        address.addItems(withObjectValues: SSHConfig.hosts())
        address.stringValue = current
        sync()
        if session?.phase == .connected { (terminalHost.subviews.first as? TerminalView)?.focus() }
        else if case .password = session?.phase { window?.makeFirstResponder(secret) }
        else { window?.makeFirstResponder(address) }
    }
    func prefill(_ connection: SSHConnection) {
        if let existing = SSHSessions.shared.session(connection), existing.phase == .connected { present(existing) }
        else { releaseShell(); session = nil; address.stringValue = connection.address; sync(); window?.makeFirstResponder(address) }
    }
    func present(_ session: SSHSession) {
        if self.session !== session { releaseShell() }
        self.session = session
        address.stringValue = session.connection.address
        sync()
    }
    func showLogin() {
        releaseShell()
        session = nil
        secret.stringValue = ""; hostKeyAnswer.stringValue = ""
        sync(); activate()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === address, selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() {
            address.stringValue = textView.string
            submitAddress()
            return true
        }
        return false
    }
    @objc private func submitAddress() {
        do {
            let connection = try SSHConnection.parse(address.stringValue)
            present(try SSHSessions.shared.connect(connection))
        } catch { hint.stringValue = error.localizedDescription }
    }
    @objc private func submitAnswer() {
        guard let session else { return }
        let answer: String
        if case .password = session.phase { answer = secret.stringValue; secret.stringValue = "" }
        else { answer = hostKeyAnswer.stringValue; hostKeyAnswer.stringValue = "" }
        session.answer(answer)
    }
    @objc private func editConfig() { configEditor.show(relativeTo: window) }
    private func sync() {
        address.isHidden = false; configButton.isHidden = false
        secret.isHidden = true; hostKeyAnswer.isHidden = true
        hint.isHidden = false; hint.stringValue = ""
        terminalHost.isHidden = true
        switch session?.phase {
        case .connected:
            address.isHidden = true; configButton.isHidden = true; hint.isHidden = true
            terminalHost.isHidden = false
            if let session {
                let projectMatch = project.flatMap { value -> RemoteProject? in
                    guard value.connection == session.connection, value.endpoint == session.endpoint else { return nil }
                    return value
                }
                let key = session.transport.socket + "\0" + (projectMatch.map { "project:" + $0.path } ?? "login")
                if shellKey != key || shellTerminal?.isRunning != true {
                    releaseShell()
                    if let projectMatch {
                        // 同一端点和项目下的每个 SSH 进程都创建自己的项目终端。
                        shellTerminal = SSHSessions.shared.makeTerminal(for: session, project: projectMatch)
                    } else if session.authTerminalOwner == nil || session.authTerminalOwner == ObjectIdentifier(self) {
                        // 第一个普通登录面板沿用认证终端，保持原有登录后的 shell 状态。
                        session.authTerminalOwner = ObjectIdentifier(self)
                        shellTerminal = session.terminal
                        usesAuthTerminal = true
                    } else {
                        shellTerminal = SSHSessions.shared.makeTerminal(for: session, project: nil)
                    }
                    shellKey = key
                }
                if let terminal = shellTerminal, terminal.superview !== terminalHost {
                    terminal.applyTheme(dark: dark)
                    terminalHost.subviews.forEach { $0.removeFromSuperview() }
                    terminal.frame = terminalHost.bounds; terminal.autoresizingMask = [.width, .height]
                    terminalHost.addSubview(terminal)
                }
                if window != nil { shellTerminal?.focus() }
            } else {
                releaseShell()
            }
        case .password(let prompt):
            address.isHidden = true; configButton.isHidden = true
            secret.isHidden = false; hint.stringValue = prompt
            window?.makeFirstResponder(secret)
        case .hostKey(let prompt):
            address.isHidden = true; configButton.isHidden = true
            hostKeyAnswer.isHidden = false; hint.stringValue = prompt; hint.toolTip = prompt
            window?.makeFirstResponder(hostKeyAnswer)
        case .connecting: hint.stringValue = "正在连接…"
        case .ended(let message):
            releaseShell()
            hint.stringValue = message; hint.toolTip = message
        case nil: releaseShell()
        }
        needsLayout = true
    }
    func bindProject(_ project: RemoteProject?) {
        self.project = project
        if let project, session == nil { address.stringValue = project.connection.address }
        syncBrowser()
        if session != nil { sync() }
    }
    /// 停靠区里每个 SSH 进程只结束自己的终端视图，不触碰共享的认证终端或 ControlMaster。
    private func releaseShell() {
        if usesAuthTerminal, let session, session.authTerminalOwner == ObjectIdentifier(self) {
            session.authTerminalOwner = nil
        } else {
            shellTerminal?.stop()
        }
        shellTerminal?.removeFromSuperview()
        shellTerminal = nil
        shellKey = nil
        usesAuthTerminal = false
    }
    private func syncBrowser() {
        guard let project else { return }
        guard let session = SSHSessions.shared.session(project.connection), session.phase == .connected, session.endpoint == project.endpoint else {
            if browserTransport != nil { browser.detach(); browserTransport = nil }
            return
        }
        let identity = project.endpoint + project.path
        if browserTransport !== session.transport || browserProjectID != identity {
            browserTransport = session.transport
            browserProjectID = identity
            browser.attach(session.transport, home: project.path)
        }
    }
    func confirmClose(_ completion: @escaping (Bool) -> Void) {
        browser.confirmLeaving { [weak self] allowed in
            guard allowed, let self else { completion(false); return }
            self.configEditor.confirmClose(completion)
        }
    }
}
