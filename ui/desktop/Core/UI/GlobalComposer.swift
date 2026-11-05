import AppKit

// MARK: - 折叠框的箭头行

/// 一行只有最右侧的箭头：向上表示可以展开，向下表示可以折叠。不显示任何文字。
final class OverlayPanelHeader: NSView {
    var onTap: (() -> Void)?

    private let chevron = NSImageView()
    private var expanded = false
    private var hover = false {
        didSet { if hover != oldValue { refreshChevron() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chevron.imageScaling = .scaleProportionallyDown
        addSubview(chevron)
        setAccessibilityRole(.button)
        setExpanded(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setExpanded(_ value: Bool) {
        expanded = value
        setAccessibilityLabel(value ? "折叠对话" : "展开对话")
        refreshChevron()
    }

    private func refreshChevron() {
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.up",
            accessibilityDescription: expanded ? "折叠对话" : "展开对话"
        )
        chevron.contentTintColor = hover ? .secondaryLabelColor : .tertiaryLabelColor
    }

    override func layout() {
        super.layout()
        let size: CGFloat = 11
        chevron.frame = NSRect(x: max(0, bounds.width - 12 - size), y: floor((bounds.height - size) / 2),
                               width: size, height: size)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseDown(with event: NSEvent) { onTap?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChevron()
    }
}

// MARK: - 窗口级对话框

/// 所有应用界面共用的 Agent 输入框：固定在底部右侧，模型和思考程度始终可选。
/// 输入框上方是一个可开合的框：折叠时只有一行箭头，
/// 展开后对话内容和同一个箭头都在这个框里。
final class AgentOverlayDock: NSView {
    static let headerHeight: CGFloat = 22

    let composer = GlassComposer(frame: .zero)
    /// 当前对话最近的消息，按需重新读取会话文件。
    var messagesProvider: (() -> [ChatMessage])?
    private(set) var isExpanded = false
    private var refreshTimer: Timer?

    private let panel: NSView
    private let header = OverlayPanelHeader(frame: .zero)
    private let scrollView = NSScrollView()
    private let transcript = NSTextView(frame: .zero)

    override init(frame frameRect: NSRect) {
        panel = makeGlassView(cornerRadius: 14, material: .hudWindow)
        super.init(frame: frameRect)
        addSubview(panel)

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.font = .systemFont(ofSize: 12)
        transcript.textColor = .labelColor
        transcript.textContainerInset = NSSize(width: 10, height: 4)
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        transcript.minSize = .zero
        transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcript.textContainer?.widthTracksTextView = false
        transcript.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = transcript
        scrollView.isHidden = true
        panel.addSubview(scrollView)

        header.onTap = { [weak self] in self?.toggleExpanded() }
        panel.addSubview(header)

        composer.onSizeChange = { [weak self] in
            self?.needsLayout = true
            self?.onSizeChange?()
        }
        addSubview(composer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var onSizeChange: (() -> Void)?
    /// 画板弹窗打开时隐藏输入框和折叠框，关闭后恢复。
    func setComposerHidden(_ hidden: Bool) {
        composer.isHidden = hidden
        panel.isHidden = hidden
        needsLayout = true
    }

    func toggleExpanded() {
        isExpanded ? collapse() : expand()
    }

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        header.setExpanded(true)
        scrollView.isHidden = false
        reloadTranscript()
        startRefreshing()
        needsLayout = true
        onSizeChange?()
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        header.setExpanded(false)
        scrollView.isHidden = true
        stopRefreshing()
        needsLayout = true
        onSizeChange?()
    }

    /// 切换应用或对话时回到折叠状态。
    func reset() { collapse() }

    private func startRefreshing() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.reloadTranscript() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    deinit { refreshTimer?.invalidate() }

    private func reloadTranscript() {
        guard isExpanded, let messages = messagesProvider?() else { return }
        let text = NSMutableAttributedString()
        let body = messages.suffix(24)
        if body.isEmpty {
            text.append(NSAttributedString(string: "还没有消息。", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        for message in body {
            let isUser = message.role == .user
            let content = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            text.append(NSAttributedString(string: (isUser ? "你" : "F") + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: isUser ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
            ]))
            text.append(NSAttributedString(string: String(content.prefix(1200)) + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: isUser ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]))
        }
        transcript.textStorage?.setAttributedString(text)
        transcript.scrollRangeToVisible(NSRange(location: (transcript.string as NSString).length, length: 0))
    }

    override func layout() {
        super.layout()
        let composerFrame = composer.layoutFrame(in: bounds)
        composer.frame = composerFrame
        let width = max(0, composerFrame.width)
        let top = composerFrame.maxY + 6
        let height = isExpanded ? min(240, max(0, bounds.height - top - 8)) : Self.headerHeight
        panel.frame = NSRect(x: composerFrame.minX, y: top, width: width, height: height)
        header.frame = NSRect(x: 0, y: max(0, height - Self.headerHeight), width: width, height: Self.headerHeight)
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: max(0, height - Self.headerHeight))
        let content = scrollView.contentSize
        if abs(transcript.frame.width - content.width) > 0.5 {
            transcript.frame.size.width = content.width
            transcript.textContainer?.containerSize = NSSize(
                width: max(1, content.width - transcript.textContainerInset.width * 2),
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }

    /// 只有对话框和折叠框接收点击，其余区域留给下面的应用界面。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
