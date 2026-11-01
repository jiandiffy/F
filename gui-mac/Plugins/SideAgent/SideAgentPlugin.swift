import AppKit

// MARK: - Side Agent

/// 右侧停靠区里的 side agent：读取主对话最近的文字作为上下文，
/// 在同一个项目里执行分析、命令、文件和其他相关任务。
final class SideAgentPlugin: FPlugin, FProcessProvider, FContextualProcess, FProcessActivity {
    let id = "side-agent"
    let title = "Side Agent"
    let symbol = "sparkles"
    let placement = PluginPlacement.bottom
    let projectAssociation = PluginProjectAssociation.project
    let processDefaultName = "side agent"
    let agentView: SideAgentView
    var view: NSView { agentView }
    var hasPendingWork: Bool { agentView.hasPendingWork }
    var contextProvider: (() -> String)? {
        get { agentView.contextProvider }
        set { agentView.contextProvider = newValue }
    }
    var boardDirectoryProvider: (() -> URL)? {
        get { agentView.boardDirectoryProvider }
        set { agentView.boardDirectoryProvider = newValue }
    }
    private var project: URL

    init(project: URL) {
        self.project = project
        agentView = SideAgentView(project: project)
    }

    func makeProcess(project: URL) -> FPlugin { SideAgentPlugin(project: project) }
    func projectDidChange(_ project: URL) { self.project = project; agentView.setProject(project) }
    func activate() { agentView.activate() }
    func applyAppearance(dark: Bool) { agentView.applyTheme(dark: dark) }
    func deactivate() { agentView.deactivate() }
    func prepareToClose(_ completion: @escaping () -> Void) { agentView.stop(); completion() }
    func shutdown() { agentView.stop() }
}

final class SideAgentView: NSView, NSTextViewDelegate {
    var contextProvider: (() -> String)?
    var boardDirectoryProvider: (() -> URL)?

    private let scroll = NSScrollView()
    private let transcript = NSTextView(frame: .zero)
    private let agent = PiRPC()

    private var project: URL
    private var started = false
    private var busy = false
    private var currentAssistant = ""
    /// 当前输入提示符 "% " 在文本里的起点；它之前的文字只读。
    private var promptStart = 0
    private var promptEnd: Int { promptStart + Self.prompt.count }
    /// 本轮请求开始前光标是否在输入区，结束时据此恢复焦点。
    private var restoreFocus = false

    private static let prompt = "% "
    private static let font = NSFont(name: "Menlo", size: 11.5)
        ?? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let lightInk = NSColor(srgbRed: 0.145, green: 0.145, blue: 0.145, alpha: 1)
    private static let darkInk = NSColor(srgbRed: 0.87, green: 0.87, blue: 0.87, alpha: 1)
    /// 文字颜色跟随 F 的黑白主题。
    private var ink: NSColor { dark ? Self.darkInk : Self.lightInk }
    private var dark = AppearanceStore.dark

    /// 仍有未完成的请求；更新重启必须等它结束。
    var hasPendingWork: Bool { busy }

    init(project: URL) {
        self.project = project.standardizedFileURL
        super.init(frame: .zero)
        wantsLayer = true
        applyTheme(dark: dark)

        transcript.isEditable = true
        transcript.isSelectable = true
        transcript.isRichText = false
        transcript.drawsBackground = false
        transcript.font = Self.font
        transcript.textColor = ink
        transcript.insertionPointColor = ink
        transcript.allowsUndo = false
        transcript.isContinuousSpellCheckingEnabled = false
        transcript.isAutomaticQuoteSubstitutionEnabled = false
        transcript.isAutomaticDashSubstitutionEnabled = false
        transcript.isAutomaticTextReplacementEnabled = false
        transcript.isAutomaticSpellingCorrectionEnabled = false
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.minSize = NSSize(width: 0, height: 0)
        transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcript.autoresizingMask = [.width]
        transcript.textContainerInset = NSSize(width: 10, height: 8)
        transcript.textContainer?.lineFragmentPadding = 0
        transcript.textContainer?.widthTracksTextView = true
        transcript.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        transcript.typingAttributes = attributes()
        transcript.delegate = self
        scroll.documentView = transcript
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        agent.onEvent = { [weak self] event in self?.handle(event) }
        agent.onExit = { [weak self] message in
            guard let self else { return }
            self.started = false
            self.currentAssistant = ""
            let wasBusy = self.busy
            self.busy = false
            self.write("\n错误：\(message)\n", color: .systemRed)
            if wasBusy { self.appendPrompt() }
        }

        appendPrompt()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 布局

    override func layout() {
        super.layout()
        scroll.frame = bounds
    }

    // MARK: 生命周期

    func activate() { window?.makeFirstResponder(transcript) }
    func deactivate() {}

    func setProject(_ url: URL) {
        let next = url.standardizedFileURL
        guard next.path != project.path else { return }
        agent.stop()
        project = next
        started = false
        busy = false
        currentAssistant = ""
        resetPage()
    }

    func stop() {
        agent.stop()
        started = false
        let wasBusy = busy
        busy = false
        currentAssistant = ""
        transcript.isEditable = true
        if wasBusy { appendPrompt() }
    }

    // MARK: 输入

    /// 只允许改动提示符之后的输入区，历史文字保持只读。
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        affectedCharRange.location >= promptEnd
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === transcript else { return false }
        guard commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) else { return false }
        if textView.hasMarkedText() { return true }
        submit()
        return true
    }

    private func submit() {
        let content = transcript.string as NSString
        guard content.length >= promptEnd else { return }
        let input = content.substring(from: promptEnd).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !busy else { return }
        restoreFocus = window?.firstResponder === transcript
        transcript.isEditable = false
        write("\n")
        dispatch(input)
    }

    private func dispatch(_ text: String) {
        guard startIfNeeded() else {
            appendPrompt()
            return
        }
        busy = true
        currentAssistant = ""
        let prompt = composePrompt(text)
        agent.request(["type": "prompt", "message": prompt]) { [weak self] response in
            guard let self else { return }
            guard response["success"] as? Bool == true else {
                self.finishTurn(error: response["error"] as? String ?? "发送失败")
                return
            }
            if (response["data"] as? [String: Any])?["disposition"] as? String == "handled" {
                self.finishTurn(error: nil)
            }
        }
    }

    /// 每次请求都重新读取主对话的最新内容，避免 side agent 使用过期上下文。
    func composePrompt(_ text: String) -> String {
        let context = contextProvider?().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return """
        你是 F 右侧停靠区里的 side agent，负责协助用户处理主对话框之外的相关任务。
        你可以使用工具读取和修改当前项目、运行命令，也可以操作当前对话的画板。
        下面是主对话框最新的对话内容，仅作为理解上下文，不要逐字复述：
        ---
        \(context.isEmpty ? "（主对话暂无文字内容）" : context)
        ---
        用户的请求：
        \(text)
        """
    }

    private func startIfNeeded() -> Bool {
        if started, agent.isRunning { return true }
        guard let cli = PiPaths.cliPath else {
            write("错误：找不到 pi 命令行。\n", color: .systemRed)
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            write("错误：项目目录不存在。\n", color: .systemRed)
            return false
        }
        let board = boardDirectoryProvider?() ?? BoardStore.directory(for: project)
        guard agent.start(cliPath: cli, workingDirectory: project, boardDirectory: board) else {
            write("错误：无法启动 side agent。\n", color: .systemRed)
            return false
        }
        started = true
        return true
    }

    // MARK: 事件

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message_update":
            guard let update = event["assistantMessageEvent"] as? [String: Any] else { return }
            switch update["type"] as? String {
            case "text_delta":
                guard let delta = update["delta"] as? String else { return }
                currentAssistant += delta
                write(delta)
            case "error":
                write("\n错误：\(update["error"] as? String ?? "未知错误")\n", color: .systemRed)
            default:
                break
            }

        case "message_end":
            guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { return }
            if message["stopReason"] as? String == "error" {
                write("\n错误：\(message["errorMessage"] as? String ?? "模型服务未能完成请求")\n", color: .systemRed)
            } else if currentAssistant.isEmpty, let text = Self.assistantText(from: message), !text.isEmpty {
                currentAssistant = text
                write(text)
            }

        case "agent_settled":
            finishTurn(error: nil)

        default:
            break
        }
    }

    private func finishTurn(error: String?) {
        if let error { write("\n错误：\(error)\n", color: .systemRed) }
        guard busy else { return }
        busy = false
        appendPrompt()
        if restoreFocus, let window { window.makeFirstResponder(transcript) }
        restoreFocus = false
    }

    private static func assistantText(from message: [String: Any]) -> String? {
        if let text = message["content"] as? String { return text }
        guard let parts = message["content"] as? [[String: Any]] else { return nil }
        return parts.compactMap { part in
            part["type"] as? String == "text" ? part["text"] as? String : nil
        }.joined()
    }

    // MARK: 文字

    /// 整页只有当前这一行提示符，回答直接跟在下面。
    private func appendPrompt() {
        guard let storage = transcript.textStorage else { return }
        let separator = storage.length > 0 && !transcript.string.hasSuffix("\n") ? "\n" : ""
        storage.append(NSAttributedString(string: separator + Self.prompt, attributes: attributes()))
        promptStart = storage.length - Self.prompt.count
        transcript.isEditable = true
        moveCursorToEnd()
    }

    private func resetPage() {
        transcript.textStorage?.setAttributedString(NSAttributedString(string: "", attributes: attributes()))
        promptStart = 0
        appendPrompt()
    }

    private func write(_ text: String, color: NSColor? = nil) {
        guard let storage = transcript.textStorage else { return }
        storage.append(NSAttributedString(string: text, attributes: attributes(color)))
        moveCursorToEnd()
    }

    /// 切换主题：背景、光标和已有文字一起换，错误提示的红色保留。
    func applyTheme(dark: Bool) {
        let previous = ink
        self.dark = dark
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        layer?.backgroundColor = BottomPanel.background(dark: dark).cgColor
        transcript.textColor = ink
        transcript.insertionPointColor = ink
        transcript.typingAttributes = attributes()
        guard previous != ink, let storage = transcript.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = value as? NSColor, color == previous else { return }
            storage.addAttribute(.foregroundColor, value: self.ink, range: range)
        }
        storage.endEditing()
    }

    private func moveCursorToEnd() {
        let end = (transcript.string as NSString).length
        transcript.setSelectedRange(NSRange(location: end, length: 0))
        transcript.scrollRangeToVisible(NSRange(location: end, length: 0))
    }

    private func attributes(_ color: NSColor? = nil) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return [.font: Self.font, .foregroundColor: color ?? ink, .paragraphStyle: style]
    }
}
