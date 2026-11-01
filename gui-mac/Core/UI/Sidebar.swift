import AppKit
import AVKit
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

// MARK: - 聊天记录列表

final class ChatRowView: NSView, NSTextFieldDelegate {
    let session: PiChat
    var onSelect: ((ChatRowView) -> Void)?
    var onRename: ((ChatRowView, String) -> Void)?
    var onDelete: ((ChatRowView) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let activity = NSView()
    private var hover = false
    private var renaming = false

    var title: String {
        didSet { if !renaming { label.stringValue = title } }
    }

    /// 项目 Agent 正在后台运行。
    var isRunning = false {
        didSet {
            activity.isHidden = !isRunning
            needsLayout = true
        }
    }

    var isSelected = false {
        didSet { applyStyle() }
    }

    init(session: PiChat, title: String? = nil) {
        self.session = session
        self.title = title ?? session.title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        label.stringValue = self.title
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.wantsLayer = true
        label.delegate = self
        addSubview(label)

        activity.wantsLayer = true
        activity.layer?.cornerRadius = 3
        activity.layer?.backgroundColor = NSColor.systemOrange.cgColor
        activity.isHidden = true
        addSubview(activity)

        // 双指按压（右键）菜单
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename…", action: #selector(beginRename), keyEquivalent: "")
        rename.target = self
        let delete = NSMenuItem(title: "Delete", action: #selector(deleteSelf), keyEquivalent: "")
        delete.target = self
        menu.addItem(rename)
        menu.addItem(.separator())
        menu.addItem(delete)
        self.menu = menu

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        toolTip = "\(self.title)\n\(formatter.string(from: session.date))\n\(session.path.path)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let indent: CGFloat = isRunning ? 17 : 10
        label.frame = NSRect(x: indent, y: (bounds.height - 16) / 2, width: max(0, bounds.width - indent - 10), height: 16)
        activity.frame = NSRect(x: 6, y: floor((bounds.height - 6) / 2), width: 6, height: 6)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { hover = true; applyStyle() }
    override func mouseExited(with event: NSEvent) { hover = false; applyStyle() }
    override func mouseDown(with event: NSEvent) {
        onSelect?(self)
        if event.modifierFlags.contains(.control), let menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onSelect?(self)
        super.rightMouseDown(with: event)
    }

    // MARK: 重命名 / 删除

    @objc private func beginRename() {
        guard !renaming else { return }
        renaming = true
        label.isEditable = true
        label.isSelectable = true
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.layer?.cornerRadius = 4
        label.layer?.masksToBounds = true
        window?.makeFirstResponder(label)
        label.currentEditor()?.selectAll(nil)
    }

    @objc private func deleteSelf() {
        onDelete?(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishRename(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishRename(commit: false)
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func finishRename(commit: Bool) {
        guard renaming else { return }
        renaming = false
        let value = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.layer?.masksToBounds = false
        if commit, !value.isEmpty, value != title {
            onRename?(self, value)
        } else {
            label.stringValue = title
        }
    }

    private func applyStyle() {
        if isSelected {
            layer?.backgroundColor = ThemeColors.selected.cgColor
            label.textColor = .labelColor
        } else if hover {
            layer?.backgroundColor = ThemeColors.hover.cgColor
            label.textColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = .secondaryLabelColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

final class ChatListDocumentView: NSView {
    override var isFlipped: Bool { true }
    private struct Item {
        let view: NSView
        let inset: CGFloat
    }
    private var items: [Item] = []
    private var chats: [PiChat] = []
    private var busyProjects: Set<String> = []
    private var busySessions: Set<String> = []
    private var selectedProject: String?
    private var selectedSession: String?
    var onOpen: ((PiChat) -> Void)?
    var onOpenProject: ((URL) -> Void)?
    var onNewConversation: ((URL) -> Void)?
    var onProjectCommand: ((URL, String) -> Void)?

    func setSelection(project: URL, session: String?) {
        selectedProject = project.standardizedFileURL.path
        selectedSession = session
        render()
    }
    func setChats(_ chats: [PiChat], busyProjects: Set<String> = [], busySessions: Set<String> = []) {
        self.chats = chats; self.busyProjects = busyProjects; self.busySessions = busySessions
        render()
    }
    private func render() {
        subviews.forEach { $0.removeFromSuperview() }; items.removeAll()
        for project in ProjectStore.folders(chats: chats) {
            let row = AppRowView(title: ProjectStore.title(for: project), symbol: "folder")
            row.isSelected = selectedProject == project.path
            row.toolTip = project.path
            row.onOpen = { [weak self] _ in
                self?.selectedProject = project.path
                self?.render()
                self?.onOpenProject?(project)
            }
            let menu = NSMenu()
            for (title, command) in [("新建对话", "new"), ("开启树状版本管理", "enable"), ("上传 GitHub", "publish")] {
                let item = NSMenuItem(title: title, action: #selector(projectAction(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = ["project": project.path, "command": command]
                menu.addItem(item)
            }
            row.menu = menu
            append(row, inset: 6)
            guard selectedProject == project.path else { continue }
            for chat in chats where chat.cwd.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) == project.path {
                let chatRow = ChatRowView(session: chat, title: ChatTitles.title(for: chat.id) ?? chat.title)
                chatRow.isSelected = selectedSession == chat.path.path
                chatRow.isRunning = busySessions.contains(chat.path.path) || busyProjects.contains(project.path)
                chatRow.onSelect = { [weak self] row in
                    self?.selectedSession = row.session.path.path
                    self?.render()
                    self?.onOpen?(row.session)
                }
                chatRow.onRename = { row, title in ChatTitles.set(title, for: row.session.id); row.title = title }
                chatRow.onDelete = { [weak self] row in self?.delete(row) }
                append(chatRow, inset: 25)
            }
            let new = AppRowView(title: "新对话", symbol: "plus")
            new.onOpen = { [weak self] _ in self?.onNewConversation?(project) }
            append(new, inset: 25)
        }
        frame.size.height = max(1, CGFloat(items.count) * 32)
        needsLayout = true
    }
    private func append(_ row: NSView, inset: CGFloat) {
        addSubview(row); items.append(Item(view: row, inset: inset))
    }
    @objc private func projectAction(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String: String], let path = value["project"], let command = value["command"] else { return }
        let project = URL(fileURLWithPath: path)
        if command == "new" { onNewConversation?(project) }
        else { onProjectCommand?(project, command) }
    }
    private func delete(_ row: ChatRowView) {
        NSWorkspace.shared.recycle([row.session.path]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard error == nil, let self else { return }
                ChatTitles.remove(for: row.session.id)
                self.chats.removeAll { $0.path == row.session.path }
                if self.selectedSession == row.session.path.path { self.selectedSession = nil }
                self.render()
            }
        }
    }
    override func layout() {
        super.layout()
        for (index, item) in items.enumerated() {
            item.view.frame = NSRect(x: item.inset, y: CGFloat(index) * 32,
                                    width: max(0, bounds.width - item.inset - 6), height: 30)
        }
    }
    func clearSelection() { selectedSession = nil; render() }
}

final class ChatListView: NSView {
    override var isFlipped: Bool { true }
    private let scrollView = NSScrollView()
    private let listView = ChatListDocumentView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = listView
        addSubview(scrollView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); scrollView.frame = bounds
        let width = scrollView.contentView.bounds.width
        if listView.frame.width != width { listView.frame.size.width = width; listView.needsLayout = true }
    }
    func reload(busyProjects: Set<String> = [], busySessions: Set<String> = []) {
        listView.setChats(PiHistory.load(), busyProjects: busyProjects, busySessions: busySessions)
        needsLayout = true; layoutSubtreeIfNeeded(); listView.layoutSubtreeIfNeeded()
    }
    func selectProject(_ project: URL, session: String?) { listView.setSelection(project: project, session: session) }
    var onOpen: ((PiChat) -> Void)? { get { listView.onOpen } set { listView.onOpen = newValue } }
    var onOpenProject: ((URL) -> Void)? { get { listView.onOpenProject } set { listView.onOpenProject = newValue } }
    var onNewConversation: ((URL) -> Void)? { get { listView.onNewConversation } set { listView.onNewConversation = newValue } }
    var onProjectCommand: ((URL, String) -> Void)? { get { listView.onProjectCommand } set { listView.onProjectCommand = newValue } }
    func clearSelection() { listView.clearSelection() }
}

// MARK: - 左侧分类与画板入口

final class SidebarSectionHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let line = NSView()

    init(title: String) {
        super.init(frame: .zero)
        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = ThemeColors.sectionTitle
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        addSubview(label)

        line.wantsLayer = true
        line.layer?.backgroundColor = ThemeColors.sectionLine.cgColor
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let textWidth = min(bounds.width, ceil(label.intrinsicContentSize.width))
        label.frame = NSRect(x: 10, y: floor((bounds.height - 15) / 2), width: textWidth, height: 15)
        let lineX = min(bounds.width - 10, 10 + textWidth + 9)
        line.frame = NSRect(
            x: lineX,
            y: floor(bounds.height / 2),
            width: max(0, bounds.width - lineX - 10),
            height: 1
        )
    }
}

final class AppRowView: NSView {
    var onOpen: ((AppRowView) -> Void)?
    var isSelected = false { didSet { applyStyle() } }
    private var hover = false

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let title: String

    init(title: String, symbol: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)

        label.stringValue = title
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        addSubview(label)

        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: floor((bounds.height - 17) / 2), width: 17, height: 17)
        label.frame = NSRect(x: 34, y: floor((bounds.height - 17) / 2), width: max(0, bounds.width - 44), height: 17)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { hover = true; applyStyle() }
    override func mouseExited(with event: NSEvent) { hover = false; applyStyle() }
    override func mouseDown(with event: NSEvent) { onOpen?(self) }

    private func applyStyle() {
        if isSelected {
            layer?.backgroundColor = ThemeColors.selected.cgColor
            label.textColor = .labelColor
            icon.contentTintColor = .labelColor
        } else if hover {
            layer?.backgroundColor = ThemeColors.hover.cgColor
            label.textColor = .labelColor
            icon.contentTintColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = .secondaryLabelColor
            icon.contentTintColor = .secondaryLabelColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

final class LeftSidebarView: NSView {
    var onOpenApp: (() -> Void)?
    var onOpenApplication: ((String) -> Void)?
    var onNewChat: (() -> Void)?
    var onOpenChat: ((PiChat) -> Void)?
    private let appHeader = SidebarSectionHeaderView(title: "应用")
    private let projectHeader = SidebarSectionHeaderView(title: "项目")
    private var appRows: [(id: String, view: AppRowView)] = []
    private var selectedID: String?
    private let chatList: ChatListView

    init(chatList: ChatListView) {
        self.chatList = chatList
        super.init(frame: .zero)
        addSubview(appHeader); addSubview(projectHeader); addSubview(chatList)
        chatList.onOpen = { [weak self] chat in
            self?.selectApplication(nil)
            self?.onOpenChat?(chat)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setApplications(_ plugins: [FPlugin]) {
        appRows.forEach { $0.view.removeFromSuperview() }
        appRows = plugins.map { plugin in
            let row = AppRowView(title: plugin.title, symbol: plugin.symbol)
            row.onOpen = { [weak self] _ in
                self?.selectApplication(plugin.id)
                self?.onOpenApplication?(plugin.id)
            }
            row.isSelected = selectedID == plugin.id
            addSubview(row)
            return (plugin.id, row)
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let headerHeight: CGFloat = 22, rowHeight: CGFloat = 30
        var y = bounds.height - headerHeight
        appHeader.frame = NSRect(x: 0, y: y, width: bounds.width, height: headerHeight)
        for item in appRows {
            y -= rowHeight + 1
            item.view.frame = NSRect(x: 8, y: y, width: max(0, bounds.width - 16), height: rowHeight)
        }
        y -= 18
        projectHeader.frame = NSRect(x: 0, y: y, width: bounds.width, height: headerHeight)
        y -= 6
        chatList.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, y))
    }
    func selectApplication(_ id: String?) {
        selectedID = id
        appRows.forEach { $0.view.isSelected = $0.id == id }
        if id != nil { chatList.clearSelection() }
    }
    func setAppSelected(_ selected: Bool) { selectApplication(selected ? "whiteboard" : nil) }
    func applyTheme() {
        appHeader.needsLayout = true; projectHeader.needsLayout = true
        appRows.forEach { $0.view.needsLayout = true }
    }
    func reload() { chatList.reload(); needsLayout = true }
}
