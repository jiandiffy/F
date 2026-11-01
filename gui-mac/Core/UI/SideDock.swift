import AppKit

// MARK: - 底栏停靠区

/// 停靠区里的一个进程。名称可改，插件实例彼此独立。
final class DockProcess {
    let id: String
    let kind: String
    var name: String
    let plugin: FPlugin

    var view: NSView { plugin.view }

    init(id: String = UUID().uuidString.lowercased(), kind: String, name: String, plugin: FPlugin) {
        self.id = id
        self.kind = kind
        self.name = name
        self.plugin = plugin
    }
}

/// 进程名称标签。左键选择，右侧 × 关闭。
/// 名称就在标签原位修改：单击已选中的标签（或双指按压标签）后标签变成输入框，
/// Enter 保存、Esc 取消，不再弹出重命名对话框。
final class DockTabView: NSView, NSTextFieldDelegate {
    let id: String
    var onSelect: (() -> Void)?
    /// 请求宿主开始原位改名；宿主用最新的标签实例执行，避免重建后改到已移除的视图。
    var onRequestRename: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var hovering = false
    private var editing = false
    private var storedName: String

    var name: String {
        get { label.stringValue }
        set {
            guard !editing else { return }
            storedName = newValue
            label.stringValue = newValue
            needsLayout = true
        }
    }

    /// 标签此刻是一个正在输入的文本框。
    var isEditingName: Bool { editing }

    var isSelected = false {
        didSet { refresh() }
    }

    init(id: String, name: String) {
        self.id = id
        storedName = name
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.stringValue = name
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.textColor = .secondaryLabelColor
        label.delegate = self
        label.toolTip = "点击已选中的标签改名，Enter 保存"
        addSubview(label)
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭进程")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "关闭"
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        addSubview(closeButton)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    /// 未编辑时标签本身不单独接收点击，整行一起处理选择；编辑时才把点击交给输入框。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if !editing, let hit, hit === label { return self }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        guard !editing else { return }
        let wasSelected = isSelected
        onSelect?()
        // 第一次点击只切换进程；已经选中的标签再点一次直接变成输入框。
        if wasSelected { onRequestRename?() }
    }

    /// 双指按压进程名称时直接改名。
    override func rightMouseDown(with event: NSEvent) {
        guard !editing else { return }
        if !isSelected { onSelect?() }
        onRequestRename?()
    }

    // MARK: 原位改名

    /// 标签变成输入框并全选，等待 Enter 保存。
    func beginRenaming() {
        guard !editing else { return }
        editing = true
        label.stringValue = storedName
        label.isEditable = true
        label.isSelectable = true
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.layer?.cornerRadius = 4
        label.layer?.masksToBounds = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(label)
        label.currentEditor()?.selectAll(nil)
    }

    /// Enter 或失去焦点保存，Esc 放弃；空白名称不覆盖原名。
    func endRenaming(commit: Bool) {
        guard editing else { return }
        editing = false
        let value = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.layer?.masksToBounds = false
        refresh()
        if commit, !value.isEmpty {
            onRename?(value)
        } else {
            label.stringValue = storedName
            needsLayout = true
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endRenaming(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            endRenaming(commit: true)
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.insertTab(_:)):
            endRenaming(commit: true)
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endRenaming(commit: false)
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    @objc private func closeTapped() { onClose?() }

    /// 主题切换后重新取一次动态颜色，黑色模式下标签不会停在浅色底。
    func applyTheme() { refresh() }

    private func refresh() {
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill = isSelected ? ThemeColors.selected : NSColor.clear
            layer?.backgroundColor = fill.cgColor
        }
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.isHidden = !(isSelected || hovering)
    }

    override func layout() {
        super.layout()
        let buttonWidth: CGFloat = closeButton.isHidden ? 0 : 18
        label.frame = NSRect(x: 8, y: max(0, (bounds.height - 16) / 2),
                             width: max(0, bounds.width - 12 - buttonWidth), height: 16)
        closeButton.frame = NSRect(x: bounds.width - 20, y: max(0, (bounds.height - 18) / 2),
                                   width: 18, height: 18)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
}

/// 进程标签容器：标签从左到右排列，空白处双指按压新建进程。
private final class DockListContent: NSView {
    override var isFlipped: Bool { true }
}

private final class DockListView: NSScrollView {
    var onBlankRightClick: ((NSEvent) -> Void)?

    override func rightMouseDown(with event: NSEvent) { onBlankRightClick?(event) }
}

/// 底栏停靠区：没有进程时显示功能选择页；已有进程时底栏仍在窗口底部，
/// 左侧是当前进程页面，右侧是纵向进程标签。中间的灰色分隔线可以拖动，
/// 用来加宽或收窄标签列。
/// 左键选择进程，标签本身就是名称输入框（Enter 保存），
/// 双指按压标签空白处或点 + 新建进程。
final class BottomPluginHost: NSView {
    private let registry: PluginRegistry
    private let content = NSView()
    private let tabBar = DockListView()
    private let tabContent = DockListContent()
    private let separator = NSView()
    private let stripHandle = ResizeHandle(axis: .horizontal)
    private let addButton = NSButton()
    private var buttons: [String: NSButton] = [:]
    private var tabs: [String: DockTabView] = [:]
    private(set) var processes: [DockProcess] = []
    private(set) var selectedID: String?
    private(set) var choosing = true
    private var visible = false
    private var project: URL
    private var dark = AppearanceStore.dark

    /// 标签列宽度的取值范围与记忆键：拖动灰色分隔线后下次启动沿用。
    private static let stripWidthKey = "FDockStripWidth"
    static let defaultStripWidth: CGFloat = 132
    static let minStripWidth: CGFloat = 88
    static let maxStripWidth: CGFloat = 420

    /// 右侧进程标签列宽度，可拖动灰色分隔线调整。
    private var stripWidth: CGFloat = BottomPluginHost.storedStripWidth

    static var storedStripWidth: CGFloat {
        let stored = UserDefaults.standard.object(forKey: stripWidthKey) as? Double
        let value = CGFloat(stored ?? Double(defaultStripWidth))
        return min(max(value, minStripWidth), maxStripWidth)
    }

    /// 选择页/进程区切换时通知宿主重新布局。
    var onLayoutChange: (() -> Void)?
    /// 进程增删、改名后通知宿主。
    var onProcessesChanged: (() -> Void)?
    /// 主对话文字记录，side agent 在每次新会话开始时读取。
    var transcriptProvider: (() -> String)?
    /// 当前对话专属画板目录。
    var boardDirectoryProvider: (() -> URL)?
    /// 进程请求宿主显示右侧辅助栏。
    var onRequestSidebar: ((String) -> Void)?

    var hasProcesses: Bool { !processes.isEmpty }
    /// 任一进程仍有未完成任务或队列时，更新重启必须继续等待。
    var hasPendingWork: Bool { processes.contains { ($0.plugin as? FProcessActivity)?.hasPendingWork == true } }

    init(registry: PluginRegistry, project: URL = ProjectStore.initial()) {
        self.registry = registry
        self.project = project
        super.init(frame: .zero)
        wantsLayer = true

        tabBar.drawsBackground = false
        tabBar.hasHorizontalScroller = false
        tabBar.hasVerticalScroller = true
        tabBar.autohidesScrollers = true
        tabBar.verticalScrollElasticity = .allowed
        tabBar.horizontalScrollElasticity = .none
        tabBar.documentView = tabContent
        tabBar.onBlankRightClick = { [weak self] event in self?.showAddMenu(event) }
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Self.separatorColor(dark: dark).cgColor
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新建进程")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "新建进程"
        addButton.setAccessibilityLabel("新建进程")
        addButton.target = self
        addButton.action = #selector(addProcessTapped)
        addSubview(content)
        addSubview(separator)
        addSubview(tabBar)
        addSubview(addButton)
        addSubview(stripHandle)
        stripHandle.toolTip = "拖动调整标签列宽度"
        stripHandle.setAccessibilityLabel("调整标签列宽度")
        stripHandle.onDrag = { [weak self] delta in self?.resizeStrip(by: delta) }
        applyTheme(dark: dark)
        refreshPlugins()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 选择页

    func refreshPlugins() {
        let enabled = Set(registry.bottomPlugins.map(\.id))
        for process in processes.filter({ !enabled.contains($0.kind) }) {
            removeProcess(process.id, shutdown: true, notify: false)
        }
        buttons.values.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        for plugin in registry.bottomPlugins {
            let button = NSButton()
            button.isBordered = false
            button.image = NSImage(systemSymbolName: plugin.symbol, accessibilityDescription: plugin.title)
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = plugin.title
            button.setAccessibilityLabel(plugin.id == "ssh" ? "SSH 登录" : plugin.title)
            button.identifier = NSUserInterfaceItemIdentifier(plugin.id)
            button.target = self
            button.action = #selector(selectKind(_:))
            buttons[plugin.id] = button
            addSubview(button)
        }
        if registry.bottomPlugins.isEmpty {
            processes.forEach { removeProcess($0.id, shutdown: true, notify: false) }
            choosing = true
            selectedID = nil
        } else if processes.isEmpty {
            choosing = true
            selectedID = nil
        }
        rebuildTabs()
        updateVisibility()
        needsLayout = true
    }

    @objc private func selectKind(_ sender: NSButton) {
        guard let kind = sender.identifier?.rawValue else { return }
        createProcess(kind)
    }

    // MARK: 进程

    @discardableResult
    func createProcess(_ kind: String) -> DockProcess? {
        guard let type = registry.bottomPlugins.first(where: { $0.id == kind }) else { return nil }
        // 未实现 FProcessProvider 的模块只保留一个实例，重复选择时切回已有进程。
        if !(type is FProcessProvider), let existing = processes.first(where: { $0.kind == kind }) {
            selectProcess(existing.id)
            return existing
        }
        let plugin: FPlugin
        if let provider = type as? FProcessProvider {
            plugin = provider.makeProcess(project: project)
        } else {
            plugin = type
        }
        let base = (type as? FProcessProvider)?.processDefaultName ?? type.title
        let process = DockProcess(kind: kind, name: uniqueName(base), plugin: plugin)
        plugin.onRequestSidebar = { [weak self] in self?.onRequestSidebar?(kind) }
        if plugin.projectAssociation == .project { plugin.projectDidChange(project) }
        if let contextual = plugin as? FContextualProcess {
            let fallbackBoard = BoardStore.directory(for: project)
            contextual.contextProvider = { [weak self] in self?.transcriptProvider?() ?? "" }
            contextual.boardDirectoryProvider = { [weak self] in self?.boardDirectoryProvider?() ?? fallbackBoard }
        }
        processes.append(process)
        show(process, activate: visible)
        choosing = false
        rebuildTabs()
        updateVisibility()
        onProcessesChanged?()
        onLayoutChange?()
        return process
    }

    func selectProcess(_ id: String) {
        guard let process = processes.first(where: { $0.id == id }) else { return }
        if selectedID == id {
            if visible { process.plugin.reselect() }
            return
        }
        show(process, activate: visible)
        rebuildTabs()
        updateVisibility()
    }

    private func show(_ process: DockProcess, activate: Bool) {
        if let previous = processes.first(where: { $0.id == selectedID }) { previous.plugin.deactivate() }
        selectedID = process.id
        content.subviews.forEach { $0.removeFromSuperview() }
        let view = process.view
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        if activate { process.plugin.activate() }
    }

    /// 重命名进程；空白名称被忽略。
    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let process = processes.first(where: { $0.id == id }) else { return }
        process.name = trimmed
        tabs[id]?.name = trimmed
        layoutTabs()
        onProcessesChanged?()
    }

    func closeProcess(_ id: String) {
        guard let process = processes.first(where: { $0.id == id }) else { return }
        process.plugin.confirmClose { [weak self] allowed in
            guard allowed else { return }
            process.plugin.prepareToClose { [weak self] in
                self?.removeProcess(id, shutdown: true, notify: true)
            }
        }
    }

    private func removeProcess(_ id: String, shutdown: Bool, notify: Bool) {
        guard let index = processes.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedID == id
        let process = processes.remove(at: index)
        if shutdown { process.plugin.shutdown() }
        process.view.removeFromSuperview()
        tabs[id]?.removeFromSuperview()
        tabs.removeValue(forKey: id)
        if wasSelected {
            selectedID = nil
            content.subviews.forEach { $0.removeFromSuperview() }
            if let next = processes.first {
                show(next, activate: visible)
            } else {
                choosing = true
            }
        }
        rebuildTabs()
        updateVisibility()
        needsLayout = true
        if notify {
            onProcessesChanged?()
            onLayoutChange?()
        }
    }

    func process(kind: String) -> DockProcess? {
        processes.first { $0.kind == kind }
    }

    // MARK: 显示

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if visible {
            choosing = !hasProcesses
            if let id = selectedID ?? processes.first?.id, !choosing {
                if let process = processes.first(where: { $0.id == id }) {
                    show(process, activate: true)
                }
            }
        } else if let process = processes.first(where: { $0.id == selectedID }) {
            process.plugin.deactivate()
        }
        updateVisibility()
        needsLayout = true
    }

    func projectDidChange(_ project: URL) {
        self.project = project
        for process in processes where process.plugin.projectAssociation == .project {
            process.plugin.projectDidChange(project)
        }
    }

    func applyAppearance(dark: Bool) { applyTheme(dark: dark); processes.forEach { $0.plugin.applyAppearance(dark: dark) } }

    /// 底栏面板、标签列和新建按钮一起跟随黑白主题。
    /// 深色模式下宿主背景透明，露出底栏与侧边栏共用的那块玻璃。
    func applyTheme(dark: Bool) {
        self.dark = dark
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        layer?.backgroundColor = BottomPanel.background(dark: dark).cgColor
        separator.layer?.backgroundColor = Self.separatorColor(dark: dark).cgColor
        addButton.contentTintColor = .secondaryLabelColor
        buttons.values.forEach { $0.contentTintColor = .secondaryLabelColor }
        tabs.values.forEach { $0.applyTheme() }
    }

    private static func separatorColor(dark: Bool) -> NSColor {
        dark ? NSColor(white: 0.3, alpha: 1) : NSColor(white: 0.9, alpha: 1)
    }

    func confirmClose(_ completion: @escaping (Bool) -> Void) {
        let active = processes
        func check(_ index: Int) {
            guard index < active.count else { completion(true); return }
            active[index].plugin.confirmClose { allowed in
                if allowed { check(index + 1) } else { completion(false) }
            }
        }
        check(0)
    }

    func prepareToClose(_ completion: @escaping () -> Void) {
        let group = DispatchGroup()
        for process in processes { group.enter(); process.plugin.prepareToClose { group.leave() } }
        group.notify(queue: .main, execute: completion)
    }

    func shutdown() {
        processes.forEach { $0.plugin.shutdown() }
        processes.removeAll()
        selectedID = nil
        choosing = true
        content.subviews.forEach { $0.removeFromSuperview() }
        rebuildTabs()
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(processes.map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func updateVisibility() {
        content.isHidden = choosing || !visible
        separator.isHidden = choosing || !visible
        stripHandle.isHidden = choosing || !visible
        tabBar.isHidden = choosing || !visible
        addButton.isHidden = choosing || !visible
        for button in buttons.values { button.isHidden = !choosing || !visible }
        needsLayout = true
    }

    /// 拖动灰色分隔线调整标签列宽度：往左拖标签更宽，往右拖更窄。
    private func resizeStrip(by delta: CGFloat) {
        guard !choosing, delta != 0 else { return }
        let limit = max(Self.minStripWidth, min(Self.maxStripWidth, bounds.width - Self.minStripWidth))
        let next = min(max(stripWidth - delta, Self.minStripWidth), limit)
        guard next != stripWidth else { return }
        stripWidth = next
        UserDefaults.standard.set(Double(next), forKey: Self.stripWidthKey)
        needsLayout = true
        layoutSubtreeIfNeeded()
        onLayoutChange?()
    }

    // MARK: 标签栏

    private func rebuildTabs() {
        // 没按 Enter 就切换标签时，按输入框里的名称保存，避免丢失刚输入的内容。
        tabs.values.forEach { $0.endRenaming(commit: true) }
        tabs.values.forEach { $0.removeFromSuperview() }
        tabs.removeAll()
        for process in processes {
            let tab = DockTabView(id: process.id, name: process.name)
            tab.isSelected = process.id == selectedID
            tab.onSelect = { [weak self] in self?.selectProcess(process.id) }
            tab.onRequestRename = { [weak self] in self?.beginRenaming(process.id) }
            tab.onRename = { [weak self] name in self?.rename(process.id, to: name) }
            tab.onClose = { [weak self] in self?.closeProcess(process.id) }
            tabs[process.id] = tab
            tabContent.addSubview(tab)
        }
        layoutTabs()
    }

    /// 纵向进程标签：从上到下依次排列，宽度固定，超出时纵向滚动。
    private func layoutTabs() {
        let width = max(1, tabBar.contentSize.width)
        let height: CGFloat = 26
        var y: CGFloat = 2
        for process in processes {
            guard let tab = tabs[process.id] else { continue }
            tab.frame = NSRect(x: 2, y: y, width: max(1, width - 4), height: height)
            y += height + 3
        }
        tabContent.frame = NSRect(x: 0, y: 0, width: width, height: max(y, tabBar.contentSize.height))
        scrollSelectedIntoView()
    }

    /// 选中的标签始终保持在可见范围内。
    private func scrollSelectedIntoView() {
        guard !tabBar.isHidden, tabBar.bounds.height > 0,
              let id = selectedID, let tab = tabs[id] else { return }
        tabBar.contentView.scrollToVisible(tab.frame.insetBy(dx: 0, dy: -6))
    }

    // MARK: 右键菜单

    private func showAddMenu(_ event: NSEvent) {
        guard !registry.bottomPlugins.isEmpty else { return }
        NSMenu.popUpContextMenu(makeAddMenu(), with: event, for: self)
    }

    @objc private func addProcessTapped() {
        guard !registry.bottomPlugins.isEmpty else { return }
        makeAddMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.height + 4), in: addButton)
    }

    private func makeAddMenu() -> NSMenu {
        let menu = NSMenu()
        for plugin in registry.bottomPlugins {
            let item = NSMenuItem(
                title: (plugin as? FProcessProvider)?.processDefaultName ?? plugin.title,
                action: #selector(addProcess(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = plugin.id
            item.image = NSImage(systemSymbolName: plugin.symbol, accessibilityDescription: plugin.title)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func addProcess(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        createProcess(kind)
    }

    /// 标签原位改名：直接让当前标签变成输入框，不再弹出对话框。
    private func beginRenaming(_ id: String) {
        guard let tab = tabs[id] else { return }
        tab.beginRenaming()
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        if choosing {
            let choices = registry.bottomPlugins
            let width = CGFloat(choices.count) * 40
            for (index, plugin) in choices.enumerated() {
                buttons[plugin.id]?.frame = NSRect(x: max(8, (bounds.width - width) / 2) + CGFloat(index) * 40,
                                                   y: max(0, (bounds.height - 28) / 2), width: 28, height: 28)
            }
            content.frame = bounds
            separator.frame = .zero
            stripHandle.frame = .zero
            tabBar.frame = .zero
            addButton.frame = .zero
        } else {
            buttons.values.forEach { $0.frame = .zero }
            // 底栏始终在底部：右侧一列是进程标签，左侧是当前进程页面。
            let strip = min(stripWidth, bounds.width)
            let size = min(22, max(0, strip - 8))
            addButton.frame = NSRect(x: max(6, bounds.width - strip + 6), y: 6, width: size, height: size)
            let tabsHeight = max(0, bounds.height - size - 16)
            tabBar.frame = NSRect(x: max(0, bounds.width - strip), y: bounds.height - tabsHeight, width: strip, height: tabsHeight)
            separator.frame = NSRect(x: max(0, bounds.width - strip), y: 0, width: 1, height: bounds.height)
            stripHandle.frame = NSRect(x: max(0, bounds.width - strip - 4), y: 0, width: 8, height: bounds.height)
            content.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - strip), height: bounds.height)
            layoutTabs()
            window?.invalidateCursorRects(for: stripHandle)
        }
    }
}
