import AppKit
import AVKit
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

// MARK: - 模型 / 思考强度选择

final class AgentOptionsBar: NSView {
    var onModelClick: (() -> Void)?
    var onThinkingClick: (() -> Void)?

    private let modelButton = NSButton()
    private let thinkingButton = NSButton()
    private let dot = NSTextField(labelWithString: "·")
    private let fontSize: CGFloat = 11
    private var modelText = "pi"
    private var thinkingText = "high"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        dot.font = .systemFont(ofSize: fontSize)
        dot.textColor = .tertiaryLabelColor
        dot.isEditable = false
        dot.isSelectable = false
        dot.isBordered = false
        dot.drawsBackground = false
        addSubview(dot)

        for button in [modelButton, thinkingButton] {
            button.isBordered = false
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: fontSize)
            button.contentTintColor = .secondaryLabelColor
            button.cell?.lineBreakMode = .byTruncatingTail
            button.cell?.truncatesLastVisibleLine = true
            addSubview(button)
        }
        modelButton.target = self
        modelButton.action = #selector(modelTapped)
        thinkingButton.target = self
        thinkingButton.action = #selector(thinkingTapped)

        setModel("pi")
        setThinking("high")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()

        let height: CGFloat = 16
        let gap: CGFloat = 5
        modelButton.sizeToFit()
        thinkingButton.sizeToFit()
        dot.sizeToFit()

        let available = max(0, bounds.width - dot.frame.width - thinkingButton.frame.width - gap * 2)
        let modelWidth = min(modelButton.frame.width, 200, available)
        let total = modelWidth + dot.frame.width + thinkingButton.frame.width + gap * 2
        var x = max(0, bounds.width - total)

        modelButton.frame = NSRect(x: x, y: floor((bounds.height - height) / 2), width: modelWidth, height: height)
        x += modelWidth + gap

        dot.frame = NSRect(
            x: x,
            y: floor((bounds.height - dot.frame.height) / 2),
            width: dot.frame.width,
            height: dot.frame.height
        )
        x += dot.frame.width + gap

        thinkingButton.frame = NSRect(
            x: x,
            y: floor((bounds.height - height) / 2),
            width: max(0, min(thinkingButton.frame.width, bounds.width - x)),
            height: height
        )
    }

    func fittingWidth() -> CGFloat {
        modelButton.sizeToFit()
        thinkingButton.sizeToFit()
        dot.sizeToFit()
        return min(modelButton.frame.width, 200) + dot.frame.width + thinkingButton.frame.width + 12
    }

    func setModel(_ name: String) {
        modelText = name
        modelButton.attributedTitle = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        needsLayout = true
    }

    func setThinking(_ level: String) {
        thinkingText = level
        thinkingButton.attributedTitle = NSAttributedString(string: level, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setModel(modelText)
        setThinking(thinkingText)
        dot.textColor = .tertiaryLabelColor
    }

    func popUpModelMenu(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: modelButton.frame.minX, y: modelButton.frame.minY - 2), in: self)
    }

    func popUpThinkingMenu(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: thinkingButton.frame.minX, y: thinkingButton.frame.minY - 2), in: self)
    }

    @objc private func modelTapped() { onModelClick?() }
    @objc private func thinkingTapped() { onThinkingClick?() }
}

// MARK: - 玻璃输入框

/// Enter 发送，Shift+Enter 换行（输入法组合中不触发发送）
final class ComposerTextView: NSTextView {
    // Each prompt editor owns its undo history, not the window's file editors
    // or another project's composer.
    private let inputUndoManager = UndoManager()
    override var undoManager: UndoManager? { inputUndoManager }
    var onPlainReturn: (() -> Void)?
    var onHistory: ((Bool) -> Bool)?

    // Secondary click must not open editing/lookup menus or change the selection.
    // The native responder chain still owns Command-C/V/X/Z and text input.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func rightMouseDown(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { return }
        super.mouseDown(with: event)
    }

    /// Only borrow arrows at the first/last visual line; ordinary multiline editing stays native.
    private func atHistoryBoundary(older: Bool) -> Bool {
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        if string.isEmpty { return true }
        guard let manager = layoutManager, let container = textContainer else { return false }
        manager.ensureLayout(for: container)
        let length = (string as NSString).length
        if selection.location == length, string.hasSuffix("\n") { return !older }
        let glyph = manager.glyphIndexForCharacter(at: min(selection.location, length - 1))
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let edge = older ? 0 : manager.numberOfGlyphs - 1
        let boundary = manager.lineFragmentRect(forGlyphAt: edge, effectiveRange: nil)
        return abs(line.minY - boundary.minY) < 1
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let modifiers = event.modifierFlags.intersection([.shift, .option, .command, .control])
        if (event.keyCode == 126 || event.keyCode == 125), modifiers.isEmpty, !hasMarkedText(),
           atHistoryBoundary(older: event.keyCode == 126), onHistory?(event.keyCode == 126) == true {
            return
        }
        if isReturn, modifiers.isEmpty, !hasMarkedText() {
            onPlainReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

final class GlassComposer: NSView, NSTextViewDelegate {
    var draftText: String {
        get { textView.string }
        set {
            historyIndex = nil
            replaceInput(newValue)
        }
    }
    var history: PromptHistory? {
        didSet {
            historyIndex = nil; historyDraft = ""
            if oldValue !== history {
                // Rebinding a project/session preserves its displayed draft, but
                // old editing actions must not cross that history boundary.
                textView.breakUndoCoalescing()
                textView.undoManager?.removeAllActions()
            }
        }
    }
    private var historyIndex: Int?
    private var historyDraft = ""
    private(set) var modelName = "pi"
    private(set) var thinkingLevel = "high"
    var onOptionsChanged: ((String, String) -> Void)?
    var canSend = true
    var showsOptions = true {
        didSet { optionsBar.isHidden = !showsOptions; needsLayout = true }
    }
    var onSend: ((String) -> Void)?
    var onSizeChange: (() -> Void)?
    var onModelClick: (() -> Void)?
    var onThinkingClick: (() -> Void)?
    /// 点击队列前的符号：打断当前任务并立即发送这条。
    var onQueueTap: ((Int) -> Void)?
    var onQueueEdit: ((Int, String) -> Void)?
    var onQueueDelete: ((Int) -> Void)?
    var onQueueEditing: ((Int, Bool) -> Void)?
    var onEmptySubmit: (() -> Void)?

    private let glass: NSView
    private let scrollView = NSScrollView()
    private let textView = ComposerTextView(frame: .zero)
    private let optionsBar = AgentOptionsBar()
    private let queueView = PromptQueueView()
    private let font = NSFont.systemFont(ofSize: 13.5)

    override init(frame frameRect: NSRect) {
        glass = makeGlassView(cornerRadius: 22, material: .hudWindow)
        super.init(frame: frameRect)

        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        addSubview(scrollView)

        optionsBar.onModelClick = { [weak self] in self?.onModelClick?() }
        optionsBar.onThinkingClick = { [weak self] in self?.onThinkingClick?() }
        addSubview(optionsBar)

        queueView.onTap = { [weak self] id in self?.onQueueTap?(id) }
        queueView.onEdit = { [weak self] id, text in self?.onQueueEdit?(id, text) }
        queueView.onDelete = { [weak self] id in self?.onQueueDelete?(id) }
        queueView.onEditing = { [weak self] id, editing in self?.onQueueEditing?(id, editing) }
        addSubview(queueView)

        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 14, height: 11)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // 自己管理容器宽度：containerSize 必须减去左右 inset，否则每行右侧会被裁掉。
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.delegate = self
        textView.toolTip = "Enter 发送，Shift+Enter 换行；首行 ↑、末行 ↓ 浏览本项目输入历史"
        textView.onPlainReturn = { [weak self] in self?.submit() }
        textView.onHistory = { [weak self] older in self?.recallHistory(older: older) ?? false }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let barWidth = min(optionsBar.fittingWidth(), max(0, bounds.width - 28))
        optionsBar.frame = NSRect(x: bounds.width - barWidth - 12, y: 7, width: barWidth, height: 18)

        let scrollY: CGFloat = showsOptions ? 29 : 6
        // 排队项排在文字输入区上方，整个玻璃随之变高
        let queued = min(queueHeight(forWidth: bounds.width), max(0, bounds.height - 74))
        glass.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - queued))
        if queued > 0 {
            queueView.frame = NSRect(x: 12, y: bounds.height - queued + 4,
                                     width: max(0, bounds.width - 24), height: queued - 8)
        } else {
            queueView.frame = .zero
        }
        scrollView.frame = NSRect(
            x: 6,
            y: scrollY,
            width: bounds.width - 12,
            height: max(0, bounds.height - scrollY - 6 - queued)
        )

        let width = scrollView.contentView.bounds.width
        if width > 0 {
            let inset = textView.textContainerInset.width
            let usable = max(1, width - inset * 2)
            if abs(textView.frame.width - width) > 0.5 {
                textView.frame.size.width = width
            }
            if abs((textView.textContainer?.containerSize.width ?? 0) - usable) > 0.5 {
                textView.textContainer?.containerSize = NSSize(width: usable, height: CGFloat.greatestFiniteMagnitude)
            }
        }
        syncTextHeight()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        // 与 layout() 保持同一套换算：scrollView 左右各 6pt + 文本容器左右 inset。
        let inset = textView.textContainerInset
        let textWidth = max(1, width - 12 - inset.width * 2)
        let string = textView.string.isEmpty ? " " : textView.string
        let bounds = NSAttributedString(string: string, attributes: [.font: font]).boundingRect(
            with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let chrome = (showsOptions ? 29 : 6) + 6 + inset.height * 2
        return min(180, max(74, ceil(bounds.height) + chrome + 1)) + queueHeight(forWidth: width)
    }

    /// 排队区额外占用的高度（0 表示没有排队项）。
    private func queueHeight(forWidth width: CGFloat) -> CGFloat {
        let inner = queueView.height(forWidth: max(1, width - 24))
        return inner > 0 ? inner + 8 : 0
    }

    func setQueue(_ items: [QueuedPrompt], paused: Bool = false) {
        guard items != queueView.items || paused != queueView.paused else { return }
        queueView.update(items, paused: paused)
        needsLayout = true
        onSizeChange?()
    }

    func layoutFrame(in bounds: NSRect) -> NSRect {
        let width = min(640, max(0, bounds.width - 96))
        return NSRect(x: max(12, bounds.width - width - 24), y: 20,
                      width: width, height: min(height(forWidth: width), max(74, bounds.height - 104)))
    }

    func setModel(_ name: String) {
        modelName = name
        optionsBar.setModel(name)
        needsLayout = true
        onOptionsChanged?(modelName, thinkingLevel)
    }

    func setThinking(_ level: String) {
        thinkingLevel = level
        optionsBar.setThinking(level)
        needsLayout = true
        onOptionsChanged?(modelName, thinkingLevel)
    }

    func popUpModelMenu(_ menu: NSMenu) {
        optionsBar.popUpModelMenu(menu)
    }

    func popUpThinkingMenu(_ menu: NSMenu) {
        optionsBar.popUpThinkingMenu(menu)
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    private func syncTextHeight() {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
        let height = max(used, scrollView.contentView.bounds.height)
        if abs(textView.frame.height - height) > 0.5 {
            textView.frame.size.height = height
        }
    }

    private func replaceInput(_ text: String) {
        // Saved drafts, history recall, send and project changes replace the
        // document without generating undoable user edits. Old ranges must not
        // survive that replacement or they can restore another draft/crash.
        textView.breakUndoCoalescing()
        textView.string = text
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        syncTextHeight()
        textView.scrollRangeToVisible(textView.selectedRange())
        onSizeChange?()
    }

    @discardableResult
    private func recallHistory(older: Bool) -> Bool {
        guard let history, !history.entries.isEmpty else { return false }
        if historyIndex == nil {
            guard older else { return false }
            historyDraft = textView.string
            historyIndex = history.entries.count
        }
        let next = min(history.entries.count, max(0, historyIndex! + (older ? -1 : 1)))
        if next == history.entries.count {
            replaceInput(historyDraft)
            historyIndex = nil
        } else {
            historyIndex = next
            replaceInput(history.entries[next])
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        // Editing a recalled prompt starts a new draft; Down must not discard the edit.
        historyIndex = nil
        syncTextHeight()
        // 到高度上限后，保持光标所在行可见（否则换行后视觉上停在上一行）。
        textView.scrollRangeToVisible(textView.selectedRange())
        onSizeChange?()
    }

    private func submit() {
        guard canSend else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { onEmptySubmit?(); return }
        history?.record(text)
        historyIndex = nil
        replaceInput("")
        onSend?(text)
    }
}

// MARK: - 待发送队列

/// 排队中的一条 prompt。
struct QueuedPrompt: Equatable, Codable {
    let id: Int
    var text: String
    var isWhiteboard = false
}

/// AppKit's begin-edit notification arrives on the first change; hold dispatch from focus onward.
final class QueuedPromptTextField: NSTextField {
    var onEditorFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onEditorFocus?()
        super.mouseDown(with: event)
    }

    override func selectText(_ sender: Any?) {
        super.selectText(sender)
        if currentEditor() != nil { onEditorFocus?() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onEditorFocus?() }
        return accepted
    }
}

/// 符号插队、文字原位编辑、右侧删除；每行始终对应同一条指令。
final class QueuedPromptRow: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 24

    var onTap: (() -> Void)?
    var onEdit: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onEditing: ((Bool) -> Void)?
    private(set) var isEditing = false
    private var committedText = ""

    private let symbolLabel = NSButton(title: "↳", target: nil, action: nil)
    private let textLabel = QueuedPromptTextField(string: "")
    private let deleteButton = NSButton(title: "×", target: nil, action: nil)
    private var tracking: NSTrackingArea?
    private var hovered = false {
        didSet { if hovered != oldValue { updateBackground() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        updateBackground()

        symbolLabel.font = .systemFont(ofSize: 12)
        symbolLabel.isBordered = false
        symbolLabel.contentTintColor = .tertiaryLabelColor
        symbolLabel.target = self
        symbolLabel.action = #selector(sendNow)
        symbolLabel.toolTip = "打断当前任务并执行这条指令"
        symbolLabel.alignment = .center
        addSubview(symbolLabel)

        textLabel.isBordered = false
        textLabel.drawsBackground = false
        textLabel.isEditable = true
        textLabel.isSelectable = true
        textLabel.focusRingType = .none
        textLabel.delegate = self
        textLabel.onEditorFocus = { [weak self] in self?.beginEditing() }
        textLabel.toolTip = "点击编辑；Enter 保存，Esc 取消"
        textLabel.setAccessibilityLabel("编辑排队指令")
        textLabel.font = .systemFont(ofSize: 12.5)
        textLabel.textColor = .secondaryLabelColor
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        addSubview(textLabel)

        deleteButton.isBordered = false
        deleteButton.font = .systemFont(ofSize: 14)
        deleteButton.contentTintColor = .tertiaryLabelColor
        deleteButton.target = self
        deleteButton.action = #selector(deletePrompt)
        deleteButton.toolTip = "删除这条排队指令"
        deleteButton.setAccessibilityLabel("删除排队指令")
        addSubview(deleteButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setText(_ value: String) {
        guard !isEditing else { return }
        committedText = value
        textLabel.stringValue = value
        symbolLabel.setAccessibilityLabel("立即执行：" + value)
    }

    private func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        onEditing?(true)
    }

    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        beginEditing()
        return true
    }

    func controlTextDidBeginEditing(_ notification: Notification) { beginEditing() }

    func controlTextDidEndEditing(_ notification: Notification) { finishEditing() }

    private func finishEditing(cancel: Bool = false) {
        guard isEditing else { return }
        let value = textLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        if !cancel && !value.isEmpty && value != committedText {
            committedText = value
            onEdit?(value)
        }
        textLabel.stringValue = committedText
        onEditing?(false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            textLabel.stringValue = textView.string
            finishEditing()
            textView.string = committedText
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing(cancel: true)
            textView.string = committedText
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    func cancelEditing() {
        let editor = textLabel.currentEditor()
        finishEditing(cancel: true)
        if let editor { editor.string = committedText; window?.makeFirstResponder(nil) }
    }

    @objc private func sendNow() {
        let editor = textLabel.currentEditor()
        finishEditing()
        if let editor { editor.string = committedText; window?.makeFirstResponder(nil) }
        onTap?()
    }
    @objc private func deletePrompt() { cancelEditing(); onDelete?() }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        let symbolWidth: CGFloat = 14
        let gap: CGFloat = 6
        let labelHeight: CGFloat = 17
        let y = (bounds.height - labelHeight) / 2
        symbolLabel.frame = NSRect(x: inset, y: y, width: symbolWidth, height: labelHeight)
        let textX = inset + symbolWidth + gap
        let deleteWidth: CGFloat = 18
        textLabel.frame = NSRect(x: textX, y: y, width: max(0, bounds.width - textX - inset - deleteWidth - gap), height: labelHeight)
        deleteButton.frame = NSRect(x: max(textX, bounds.width - inset - deleteWidth), y: y, width: deleteWidth, height: labelHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(symbolLabel.frame, cursor: .pointingHand)
        addCursorRect(deleteButton.frame, cursor: .pointingHand)
        addCursorRect(textLabel.frame, cursor: .iBeam)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = (hovered ? ThemeColors.hover : NSColor.clear).cgColor
    }
}

/// 输入框上方摞起来的待发送列表。
final class PromptQueueView: NSView {
    static let rowGap: CGFloat = 2
    static let maxRows = 4
    private final class Document: NSView { override var isFlipped: Bool { true } }

    var onTap: ((Int) -> Void)?
    var onEdit: ((Int, String) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onEditing: ((Int, Bool) -> Void)?
    private(set) var items: [QueuedPrompt] = []
    private(set) var paused = false
    private var rows: [QueuedPromptRow] = []
    private let scrollView = NSScrollView()
    private let document = Document()
    private let pauseHint = NSTextField(labelWithString: "已暂停 · Enter 继续，Ctrl+C 终止，↳ 优先执行")

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        addSubview(scrollView)
        pauseHint.font = .systemFont(ofSize: 10.5)
        pauseHint.textColor = .tertiaryLabelColor
        pauseHint.lineBreakMode = .byTruncatingTail
        pauseHint.isHidden = true
        addSubview(pauseHint)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ newItems: [QueuedPrompt], paused: Bool = false) {
        // Preserve row identity and its field editor when another prompt arrives.
        let existing = Dictionary(uniqueKeysWithValues: zip(items, rows).map { ($0.0.id, $0.1) })
        let retained = Set(newItems.map(\.id))
        for item in items where !retained.contains(item.id) {
            existing[item.id]?.cancelEditing()
            existing[item.id]?.removeFromSuperview()
        }
        items = newItems
        self.paused = paused
        pauseHint.isHidden = !paused || newItems.isEmpty
        rows = newItems.map { item in
            let row = existing[item.id] ?? QueuedPromptRow(frame: .zero)
            row.setText(item.text)
            row.onTap = { [weak self] in self?.onTap?(item.id) }
            row.onEdit = { [weak self] text in self?.onEdit?(item.id, text) }
            row.onDelete = { [weak self] in self?.onDelete?(item.id) }
            row.onEditing = { [weak self] editing in self?.onEditing?(item.id, editing) }
            if row.superview == nil { document.addSubview(row) }
            return row
        }
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let count = min(rows.count, Self.maxRows)
        guard count > 0 else { return 0 }
        return CGFloat(count) * QueuedPromptRow.height + CGFloat(count - 1) * Self.rowGap + (paused ? 20 : 0)
    }

    override func layout() {
        super.layout()
        let hint: CGFloat = paused && !items.isEmpty ? 20 : 0
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - hint))
        document.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width,
                                height: max(scrollView.contentSize.height, CGFloat(rows.count) * (QueuedPromptRow.height + Self.rowGap)))
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * (QueuedPromptRow.height + Self.rowGap),
                               width: document.bounds.width, height: QueuedPromptRow.height)
        }
        pauseHint.frame = NSRect(x: 8, y: max(0, bounds.height - hint + 2), width: max(0, bounds.width - 16), height: 17)
    }
}

