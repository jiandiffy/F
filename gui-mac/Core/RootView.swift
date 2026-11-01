import AppKit
import AVKit
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

// MARK: - 拖入文件夹提示

/// 把文件夹拖到窗口上时出现：松开即按该文件夹新建一条对话。
final class FolderDropHintView: NSView {
    private let label = NSTextField(labelWithString: "松开以新建对话")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 12, y: floor((bounds.height - 18) / 2), width: max(0, bounds.width - 24), height: 18)
    }

    /// 提示只是视觉反馈，不能挡住拖放目标。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }
}

// MARK: - 窗口内容

final class RootView: NSView {
    private enum WorkspaceMode: Equatable {
        case application(String)
        case conversation
    }

    private let leftButton = SidebarButton(symbol: "sidebar.left", label: "对话记录")
    private let addButton = SidebarButton(symbol: "plus", label: "新建对话")
    private let rightButton = SidebarButton(symbol: "sidebar.right", label: "右侧边栏")
    private let bottomButton = SidebarButton(symbol: "rectangle.bottomthird.inset.filled", label: "下边栏")
    private let chatView: ChatListView
    private let leftSidebar: LeftSidebarView
    private let fileBrowser: FileBrowserView
    private let leftPanel: SidebarPanel
    private let rightPanel: SidebarPanel
    private let bottomPanel: BottomPanel
    let plugins: PluginRegistry
    var onPluginsChanged: (() -> Void)?
    private let bottomHost: BottomPluginHost
    private let rightContent = NSView()
    /// 一个文件夹下的多个会话各自运行，切换显示不停止后台任务。
    private var conversations: [String: ConversationView]
    private var lastProjectConversations: [String: String] = [:]
    private var activeConversation: ConversationView
    var conversationView: ConversationView { activeConversation }
    private let whiteboardPlugin: WhiteboardPlugin
    private let dropHint = FolderDropHintView(frame: .zero)
    private var whiteboardView: WhiteboardView { whiteboardPlugin.board }
    private var darkTheme = false
    private var lastActivitySignature = ""
    private var boardDrafts: [String: String] = [:]
    private var initialConversationAvailable = true

    private var projectURL = ProjectStore.initial()
    private var mode: WorkspaceMode = .application("whiteboard")
    private var pendingBoardStorageReload = false
    private var projectMenu: NSMenu?
    private var hostObserver: NSObjectProtocol?
    private var folderPicker: RemoteFolderPicker?

    private var windowDragMonitor: Any?
    private var windowDragTimer: Timer?
    private var windowDragging = false
    private var windowDragStartScreen = NSPoint.zero
    private var windowDragOrigin = NSPoint.zero
    private var windowDragTarget: NSView?

    private var leftOpen = false
    private var rightOpen = false
    private var bottomOpen = false
    private var animatingCount = 0

    private var leftWidth: CGFloat = 272
    private var rightWidth: CGFloat = 272
    private var bottomHeight: CGFloat = 240

    override init(frame frameRect: NSRect) {
        let project = ProjectStore.initial()
        let chat = ChatListView(frame: .zero)
        let registry = BuiltInPlugins.make(project: project)
        let browser = (registry.plugin("files") as! FilesPlugin).browser
        let sidebar = LeftSidebarView(chatList: chat)
        chatView = chat
        leftSidebar = sidebar
        fileBrowser = browser
        leftPanel = SidebarPanel(separatorOnRight: true, content: sidebar)
        rightPanel = SidebarPanel(separatorOnRight: false, content: rightContent)
        bottomPanel = BottomPanel(frame: .zero)
        let startView = ConversationView(frame: .zero)
        startView.prepareProject(project, boardID: UUID().uuidString.lowercased())
        conversations = [startView.workspaceKey: startView]
        activeConversation = startView
        plugins = registry
        whiteboardPlugin = registry.plugin("whiteboard") as! WhiteboardPlugin
        bottomHost = BottomPluginHost(registry: registry, project: project)
        projectURL = project
        super.init(frame: frameRect)

        wantsLayer = true
        // 文件夹可以直接拖到窗口任意位置（包括网页视图上方）。
        registerForDraggedTypes([.fileURL])
        (registry.plugins.filter { $0.placement == .workspace }.map(\.view) +
         [activeConversation, bottomPanel, leftPanel, rightPanel, leftButton, addButton, bottomButton, rightButton, dropHint]).forEach(addSubview)
        bottomPanel.addSubview(bottomHost)
        refreshRightSidebar()
        hostObserver = NotificationCenter.default.addObserver(forName: .fSSHChanged, object: nil, queue: .main) { [weak self] _ in self?.populateProjectMenu() }
        whiteboardPlugin.bindConversation(startView.boardID, project: project)
        plugins.projectDidChange(project)
        if registry.isEnabled("ssh") { SSHSessions.shared.refresh() }
        if registry.isEnabled("ssh"), let remote = RemoteProjects.load(project) {
            SSHSessions.shared.refresh()
            SSHSessions.shared.ensure(remote.connection) { _ in }
        }
        bottomHost.onLayoutChange = { [weak self] in
            guard let self else { return }
            self.applyFrames()
            self.needsLayout = true
        }
        bottomHost.onProcessesChanged = { [weak self] in self?.refreshRightSidebar() }
        bottomHost.onRequestSidebar = { [weak self] _ in
            guard let self, !self.rightOpen else { return }
            self.rightOpen = true
            self.rightButton.isActive = true
            self.animateLayout()
        }
        bottomHost.transcriptProvider = { [weak self] in self?.activeConversation.recentTranscript() ?? "" }
        bottomHost.boardDirectoryProvider = { [weak self] in
            self?.activeConversation.boardDirectory ?? BoardStore.directory(for: ProjectStore.initial())
        }
        for plugin in registry.bottomPlugins {
            plugin.onRequestSidebar = { [weak self, weak plugin] in
                guard let self, let plugin else { return }
                _ = self.bottomHost.createProcess(plugin.id)
                if !self.rightOpen {
                    self.rightOpen = true
                    self.rightButton.isActive = true
                    self.animateLayout()
                }
            }
        }

        activeConversation.isHidden = true
        whiteboardView.isHidden = false
        leftSidebar.setAppSelected(true)

        wireConversation(activeConversation)
        whiteboardView.connectOptions(to: activeConversation)

        leftSidebar.onOpenApplication = { [weak self] id in self?.showApplication(id) }
        leftSidebar.onOpenChat = { [weak self] chat in
            self?.showConversation(chat)
        }
        chat.onOpenProject = { [weak self] project in self?.selectProject(project) }
        chat.onNewConversation = { [weak self] project in self?.openProject(project) }
        chat.onProjectCommand = { [weak self] project, command in
            guard let self, self.flushFileEdits() else { return }
            self.selectProject(project)
            self.performApplicationCommand("versions", command: command)
        }
        ProjectStore.remember(project)
        chat.selectProject(project, session: startView.sessionPath)
        chat.reload()

        whiteboardView.onPrompt = { [weak self] text in
            self?.conversationView.askWhiteboard(text)
        }
        whiteboardView.onOpenConversation = { [weak self] in
            self?.showConversation(nil)
        }

        leftButton.target = self
        leftButton.action = #selector(toggleLeft)
        addButton.target = self
        addButton.action = #selector(newChat)
        rightButton.target = self
        rightButton.action = #selector(toggleRight)
        bottomButton.target = self
        bottomButton.action = #selector(toggleBottom)

        browser.rootURL = RemoteProjects.load(projectURL) == nil ? projectURL : nil
        registry.onChange = { [weak self] in self?.refreshPluginState() }
        refreshPluginState()

        leftPanel.onResize = { [weak self] delta in
            guard let self, self.leftOpen else { return }
            self.leftWidth = self.clampWidth(self.leftWidth + delta)
            self.applyFrames()
        }
        rightPanel.onResize = { [weak self] delta in
            guard let self, self.rightOpen else { return }
            self.rightWidth = self.clampWidth(self.rightWidth - delta)
            self.applyFrames()
        }
        bottomPanel.onResize = { [weak self] delta in
            guard let self, self.bottomOpen else { return }
            self.bottomHeight = self.clampHeight(self.bottomHeight + delta)
            self.applyFrames()
        }

        windowDragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            if AgentInterruptShortcut.matches(event), self.conversationView.interruptCurrent() { return nil }
            return self.handleWindowDrag(event)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let hostObserver { NotificationCenter.default.removeObserver(hostObserver) }
        if let windowDragMonitor { NSEvent.removeMonitor(windowDragMonitor) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDynamicLayerColors()
    }

    private func updateDynamicLayerColors() {
        func walk(_ view: NSView) {
            if let layer = view.layer, layer.borderWidth > 0 {
                layer.borderColor = ThemeColors.glassBorder.cgColor
            }
            view.subviews.forEach(walk)
        }
        walk(self)
    }

    func applyAppearance(dark: Bool) {
        darkTheme = dark
        conversations.values.forEach { $0.setTheme(dark) }
        plugins.applyAppearance(dark: dark)
        bottomPanel.applyTheme(dark: dark)
        bottomHost.applyAppearance(dark: dark)
        leftSidebar.applyTheme()
        chatView.reload(busySessions: busySessionPaths)
        needsDisplay = true
        updateDynamicLayerColors()
    }

    /// 保存位置变了：当前项目的画板从新路径重新读一遍。
    func reloadBoardStorage() {
        if conversations.values.contains(where: { $0.isProcessing }) { pendingBoardStorageReload = true }
        else { whiteboardView.reloadFromStorage() }
    }

    func flushWhiteboard(_ completion: @escaping () -> Void) {
        bottomHost.prepareToClose { [weak self] in
            guard let self else { completion(); return }
            self.plugins.prepareToClose(completion)
        }
    }

    /// Only the publishing conversation must finish; other conversations get durable continuations.
    /// Dock processes retain their existing idle gate (PTY/shell state is not serializable).
    private var pluginsHavePendingWork: Bool {
        plugins.plugins.compactMap { $0 as? FProcessActivity }.contains { $0.hasPendingWork }
    }
    func canBeginUpdate(originSession: String?) -> Bool {
        guard !bottomHost.hasPendingWork, !pluginsHavePendingWork else { return false }
        if let originSession, let origin = conversations.values.first(where: { $0.ownsSession(originSession) }) {
            return !origin.hasPendingWork
        }
        // Unknown/legacy publisher: do not risk interrupting the Agent hosting the update.
        return conversations.values.allSatisfy { !$0.hasPendingWork }
    }
    var canRestartForUpdate: Bool {
        conversations.values.allSatisfy { $0.canRestartForUpdate } && !bottomHost.hasPendingWork && !pluginsHavePendingWork
    }
    func interruptForUpdate(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let group = DispatchGroup()
        var failure: Error?
        for view in conversations.values {
            group.enter()
            view.interruptForUpdate(id: id) { result in
                if case .failure(let error) = result { failure = error }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if let failure { completion(.failure(failure)) }
            else { completion(.success(())) }
        }
    }
    func continueAfterUpdate() {
        conversations.values.forEach { $0.continueAfterUpdate() }
    }
    var isUpdateUIReady: Bool { conversationView.isUpdateUIReady }
    func prepareUpdateResume(id: String, announcement: String) -> UpdateResume {
        var resume = conversationView.updateResume(id: id, announcement: announcement)
        resume.project = projectURL.path
        resume.boardDraft = whiteboardView.draftText
        resume.background = conversations.values.filter { $0 !== activeConversation }.map { view in
            var state = view.updateResume(id: id, announcement: "")
            state.boardDraft = boardDrafts[view.workspaceKey] ?? ""
            return state
        }
        return resume
    }
    func restoreAfterUpdate(_ resume: UpdateResume) {
        guard flushFileEdits() else { return }
        let project = URL(fileURLWithPath: resume.project)
        activateConversation(conversation(for: project, session: resume.session, boardID: resume.boardID))
        setProject(project)
        conversationView.restoreUpdate(resume)
        whiteboardView.draftText = resume.boardDraft
        initialConversationAvailable = false
        for state in resume.background ?? [] {
            let view = conversation(for: URL(fileURLWithPath: state.project), session: state.session, boardID: state.boardID)
            view.restoreUpdate(state)
            boardDrafts[view.workspaceKey] = state.boardDraft
        }
        if let origin = resume.noticeProject, resume.noticeSession != resume.session || origin != resume.project {
            conversation(for: URL(fileURLWithPath: origin), session: resume.noticeSession).attachUpdateNotice(resume.announcement, session: resume.noticeSession)
        }
    }
    func showUpdateError(_ text: String) { showConversation(nil); conversationView.showUpdateError(text) }

    func shutdownPlugins() {
        bottomHost.shutdown()
        plugins.shutdown()
    }
    func flushFileEdits() -> Bool { fileBrowser.flushPendingEdits() }

    func confirmPluginClose(_ completion: @escaping (Bool) -> Void) {
        guard flushFileEdits() else { completion(false); return }
        plugins.confirmClose { [weak self] allowed in
            guard allowed, let self else { completion(allowed); return }
            self.bottomHost.confirmClose(completion)
        }
    }

    private func refreshRightSidebar() {
        let remote = RemoteProjects.load(projectURL) != nil
        let available = remote ? plugins.isEnabled("ssh") : plugins.isEnabled("files")
        rightButton.isEnabled = available
        guard available else {
            rightOpen = false; rightButton.isActive = false
            rightContent.subviews.forEach { $0.removeFromSuperview() }
            needsLayout = true
            return
        }
        let view = remote ? (plugins.plugin("ssh")?.sidebarView ?? fileBrowser) : fileBrowser
        guard rightContent.subviews.first !== view else { return }
        rightContent.subviews.forEach { $0.removeFromSuperview() }
        view.frame = rightContent.bounds
        view.autoresizingMask = [.width, .height]
        rightContent.addSubview(view)
    }

    func requestPluginEnabled(_ id: String, _ enabled: Bool) {
        guard enabled || (conversations.values.allSatisfy({ !$0.hasPendingWork }) && !bottomHost.hasPendingWork && !pluginsHavePendingWork) else {
            let alert = NSAlert()
            alert.messageText = "请先停止各项目及停靠区的任务和队列，再关闭插件"
            alert.informativeText = "可按 Ctrl+C 中断当前任务。"
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        plugins.setEnabled(id, enabled) { [weak self] changed in
            if changed, enabled, id == "ssh" { SSHSessions.shared.refresh() }
            if changed, enabled, self?.plugins.plugin(id)?.placement == .workspace { self?.showApplication(id) }
        }
    }
    private func refreshPluginState() {
        if plugins.isEnabled("whiteboard") { whiteboardPlugin.bindConversation(activeConversation.boardID, project: projectURL) }
        leftSidebar.setApplications(plugins.applicationPlugins)
        bottomHost.refreshPlugins()
        bottomButton.isEnabled = !plugins.bottomPlugins.isEmpty
        if plugins.bottomPlugins.isEmpty { bottomOpen = false; bottomButton.isActive = false; bottomHost.setVisible(false) }
        if case .application(let id) = mode, !plugins.isEnabled(id) { showConversation(nil) }
        for plugin in plugins.plugins where plugin.placement == .workspace {
            plugin.view.isHidden = mode != .application(plugin.id) || !plugins.isEnabled(plugin.id)
        }
        if case .application(let id) = mode { leftSidebar.selectApplication(id) }
        refreshRightSidebar()
        onPluginsChanged?()
        needsLayout = true
    }
    func performApplicationCommand(_ id: String, command: String) {
        guard plugins.isEnabled(id), let plugin = plugins.applicationPlugins.first(where: { $0.id == id }) else { return }
        showApplication(id)
        plugin.performMenuCommand(command)
    }
    func performWhiteboardAction(_ action: String) { performApplicationCommand("whiteboard", command: action) }

    // MARK: 工作区切换

    /// 画板等按项目关联的模块始终跟随当前对话所在的项目。
    /// 窗口缓存的 projectURL 只用来记住最近打开的项目，不单独决定画板归属。
    private var activeProjectURL: URL { URL(fileURLWithPath: activeConversation.projectPath) }

    private func showApplication(_ id: String) {
        guard flushFileEdits() else { return }
        guard let plugin = plugins.applicationPlugins.first(where: { $0.id == id }) else { return }
        if case .application(let previous) = mode, previous != id { plugins.plugin(previous)?.deactivate() }
        mode = .application(id)
        let project = activeProjectURL
        if id == "whiteboard" { whiteboardPlugin.bindConversation(activeConversation.boardID, project: project) }
        if project.path != projectURL.path { setProject(project) }
        else if plugin.projectAssociation == .project { plugin.projectDidChange(projectURL) }
        conversations.values.forEach { $0.isHidden = true }
        for application in plugins.plugins where application.placement == .workspace { application.view.isHidden = application.id != id }
        leftSidebar.selectApplication(id)
        plugin.activate()
    }

    // MARK: 多项目并行

    /// Each conversation owns its RPC, queue and draft; folder membership never merges them.
    private func conversation(for project: URL, session: String? = nil, boardID: String? = nil, fresh: Bool = false) -> ConversationView {
        if !fresh {
            if let session, let existing = conversations.values.first(where: { $0.ownsSession(session) }) { return existing }
            if let boardID, let existing = conversations[boardID] { return existing }
            if session == nil, boardID == nil,
               let existing = conversations.values.first(where: { $0.projectPath == project.standardizedFileURL.path }) { return existing }
        }
        let id = boardID ?? session.map { ConversationBoards.id(for: $0) } ?? UUID().uuidString.lowercased()
        if let session { ConversationBoards.migrateLegacy(project: project, session: session, id: id) }
        // Reuse only the untouched initial view; never reuse a running conversation because cwd matches.
        if initialConversationAvailable, activeConversation.isUnused, activeConversation.projectPath == project.standardizedFileURL.path {
            initialConversationAvailable = false
            let view = activeConversation
            conversations.removeValue(forKey: view.workspaceKey)
            view.prepareProject(project, boardID: id, session: session)
            conversations[id] = view
            whiteboardView.connectOptions(to: view)
            return view
        }
        let view = ConversationView(frame: .zero)
        view.prepareProject(project, boardID: id, session: session)
        conversations[id] = view
        wireConversation(view)
        addSubview(view, positioned: .below, relativeTo: leftPanel)
        view.isHidden = true
        view.setTheme(darkTheme)
        view.frame = conversationFrame()
        return view
    }

    private func wireConversation(_ view: ConversationView) {
        view.onProjectChanged = { [weak self, weak view] url in
            guard let self, let view, view === self.activeConversation else { return }
            self.setProject(url)
        }
        view.onHistoryChanged = { [weak self] in
            guard let self else { return }
            let busy = self.busySessionPaths
            self.lastActivitySignature = busy.sorted().joined(separator: "|")
            self.chatView.reload(busySessions: busy)
            self.chatView.selectProject(self.activeProjectURL, session: self.activeConversation.sessionPath)
        }
        view.onAgentActivity = { [weak self, weak view] text, busy in
            guard let self else { return }
            if self.pendingBoardStorageReload, self.conversations.values.allSatisfy({ !$0.isProcessing }) {
                self.pendingBoardStorageReload = false
                self.whiteboardView.reloadFromStorage()
            }
            if view === self.activeConversation { self.whiteboardView.setStatus(text, busy: busy) }
            self.refreshActivityIndicators()
        }
        view.onRemoteLoginRequired = { [weak self, weak view] connection in
            guard let self, let view, self.plugins.isEnabled("ssh"), self.flushFileEdits() else { return }
            self.activateConversation(view)
            self.setProject(URL(fileURLWithPath: view.projectPath))
            self.bottomOpen = true; self.bottomButton.isActive = true
            self.bottomHost.setVisible(true)
            self.bottomHost.createProcess("ssh")
            (self.bottomHost.process(kind: "ssh")?.plugin as? SSHPlugin)?.panel.prefill(connection)
            self.animateLayout()
        }
        view.onRequestProjectView = { [weak self] url in self?.openProject(url) }
    }

    private var busySessionPaths: Set<String> {
        Set(conversations.values.filter { $0.hasPendingWork }.compactMap(\.sessionPath))
    }

    /// 左侧列表用小圆点提示哪些项目还在后台跑。
    private func refreshActivityIndicators() {
        let signature = busySessionPaths.sorted().joined(separator: "|")
        guard signature != lastActivitySignature else { return }
        lastActivitySignature = signature
        chatView.reload(busySessions: busySessionPaths)
    }

    /// 切换活动会话：只改变显示，不触碰其他项目正在运行的 Agent。
    private func activateConversation(_ view: ConversationView) {
        if view !== activeConversation {
            boardDrafts[activeConversation.workspaceKey] = whiteboardView.draftText
            activeConversation.detachBoardOptions()
            whiteboardView.connectOptions(to: view)
            whiteboardView.draftText = boardDrafts[view.workspaceKey] ?? ""
            whiteboardView.clearStatus()
        }
        activeConversation = view
        lastProjectConversations[view.projectPath] = view.workspaceKey
        mode = .conversation
        for plugin in plugins.plugins where plugin.placement == .workspace {
            plugin.view.isHidden = true
            plugin.deactivate()
        }
        for other in conversations.values where other !== view { other.isHidden = true }
        view.isHidden = false
        view.frame = conversationFrame()
        view.needsLayout = true
        leftSidebar.setAppSelected(false)
        chatView.selectProject(URL(fileURLWithPath: view.projectPath), session: view.sessionPath)
    }

    private func selectProject(_ project: URL) {
        guard flushFileEdits() else { return }
        let path = project.standardizedFileURL.path
        if let key = lastProjectConversations[path], let view = conversations[key] {
            activateConversation(view); setProject(project); view.focusComposer()
        } else if let chat = PiHistory.load().first(where: { $0.cwd.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) == path }) {
            showConversation(chat)
        } else if let view = conversations.values.first(where: { $0.projectPath == path }) {
            activateConversation(view); setProject(project); view.focusComposer()
        } else { openProject(project) }
    }

    /// 新建项目：当前项目还在跑时照样可以开另一个项目，各跑各的 Agent。
    private func openProject(_ url: URL) {
        guard flushFileEdits() else { return }
        let view = conversation(for: url, fresh: true)
        activateConversation(view)
        setProject(url)
        view.beginFreshProject(url)
    }

    private func showConversation(_ chat: PiChat?) {
        guard flushFileEdits() else { return }
        guard let chat else {
            activateConversation(activeConversation)
            activeConversation.focusComposer()
            return
        }
        let project = chat.cwd.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? projectURL
        let view = conversation(for: project, session: chat.path.path)
        guard view.canOpen(chat) else { return }
        activateConversation(view)
        setProject(project)
        view.show(chat)
    }

    /// 窗口内任意位置长按（约 0.35 秒）后再滑动，整个页面跟随指针移动；
    /// 按下后立刻拖动则保持原交互，文字输入、按钮和分隔条不受影响。
    private func handleWindowDrag(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }

        switch event.type {
        case .leftMouseDown:
            windowDragTimer?.invalidate()
            windowDragTimer = nil
            windowDragStartScreen = window.convertPoint(toScreen: event.locationInWindow)
            windowDragTarget = window.contentView?.hitTest(event.locationInWindow)
            // 输入框、按钮、滚动条和可拖动分隔条保留自己的鼠标交互。
            guard !blocksPageDrag(windowDragTarget) else { return event }

            let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
                self?.beginWindowDrag()
            }
            RunLoop.main.add(timer, forMode: .common)
            windowDragTimer = timer
            return event

        case .leftMouseDragged:
            if windowDragging {
                let now = NSEvent.mouseLocation
                window.setFrameOrigin(NSPoint(
                    x: windowDragOrigin.x + (now.x - windowDragStartScreen.x),
                    y: windowDragOrigin.y + (now.y - windowDragStartScreen.y)
                ))
                return nil
            }
            let now = NSEvent.mouseLocation
            if hypot(now.x - windowDragStartScreen.x, now.y - windowDragStartScreen.y) > 6 {
                windowDragTimer?.invalidate()
                windowDragTimer = nil
            }
            return event

        case .leftMouseUp:
            windowDragTimer?.invalidate()
            windowDragTimer = nil
            windowDragTarget = nil
            if windowDragging {
                windowDragging = false
                conversationView.clearSelection()
                return nil
            }
            return event

        default:
            return event
        }
    }

    /// 长按后接管拖动时，先给原来的视图补一个抬起事件：
    /// 网页（画板、对话记录）收到按下却收不到抬起会停留在拖动或选中状态。
    private func releaseDragTarget() {
        defer { windowDragTarget = nil }
        guard let window, let target = windowDragTarget else { return }
        var web: WKWebView?
        var current: NSView? = target
        while let view = current {
            if let match = view as? WKWebView { web = match; break }
            current = view.superview
        }
        guard let web else { return }
        guard let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: window.convertPoint(fromScreen: windowDragStartScreen),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else { return }
        web.mouseUp(with: up)
    }

    /// 页面拖动的例外：文字输入、按钮、滚动条和可拖动分隔条。
    private func blocksPageDrag(_ view: NSView?) -> Bool {
        var current = view
        while let currentView = current {
            if currentView is NSText || currentView is NSTextView
                || currentView is NSControl || currentView is ResizeHandle { return true }
            current = currentView.superview
        }
        return false
    }

    private func beginWindowDrag() {
        windowDragTimer = nil
        guard NSEvent.pressedMouseButtons & 1 == 1, let window else { return }
        windowDragging = true
        windowDragStartScreen = NSEvent.mouseLocation
        windowDragOrigin = window.frame.origin
        releaseDragTarget()
    }

    override func layout() {
        super.layout()

        leftWidth = clampWidth(leftWidth)
        rightWidth = clampWidth(rightWidth)
        bottomHeight = clampHeight(bottomHeight)

        // 固定在最左上 / 最右上，不随边栏移动
        leftButton.frame = NSRect(x: 12, y: bounds.height - 38, width: 32, height: 26)
        addButton.frame = NSRect(x: 52, y: bounds.height - 38, width: 32, height: 26)
        rightButton.frame = NSRect(x: bounds.width - 44, y: bounds.height - 38, width: 32, height: 26)
        bottomButton.frame = NSRect(x: bounds.width - 84, y: bounds.height - 38, width: 32, height: 26)
        let hintWidth = min(240, max(0, bounds.width - 40))
        dropHint.frame = NSRect(
            x: floor((bounds.width - hintWidth) / 2),
            y: floor((bounds.height - 60) / 2),
            width: hintWidth,
            height: 60
        )

        guard animatingCount == 0 else { return }
        applyFrames()
    }

    // MARK: 尺寸

    private func clampWidth(_ value: CGFloat) -> CGFloat {
        min(max(value, 220), max(240, bounds.width * 0.45))
    }

    private func clampHeight(_ value: CGFloat) -> CGFloat {
        min(max(value, 120), max(140, bounds.height * 0.7))
    }

    /// 停靠区默认右小左大，但允许拖到一半以上。
    private func panelWidth(_ value: CGFloat) -> CGFloat { clampWidth(value) }

    private func leftInset() -> CGFloat { leftOpen ? panelWidth(leftWidth) : 0 }
    private func rightInset() -> CGFloat { rightOpen ? panelWidth(rightWidth) : 0 }
    private func bottomInset() -> CGFloat { bottomOpen ? clampHeight(bottomHeight) : 0 }

    private func leftFrame() -> NSRect {
        let width = panelWidth(leftWidth)
        return NSRect(
            x: leftOpen ? 0 : -(width + 48),
            y: 0,
            width: width,
            height: bounds.height
        )
    }

    private func rightFrame() -> NSRect {
        let width = panelWidth(rightWidth)
        return NSRect(
            x: rightOpen ? bounds.width - width : bounds.width + 48,
            y: 0,
            width: width,
            height: bounds.height
        )
    }

    /// 底栏：始终停在窗口底部，不随进程数量改变位置。
    private func bottomFrame() -> NSRect {
        let left = leftInset()
        let right = rightInset()
        let height = clampHeight(bottomHeight)
        return NSRect(
            x: left,
            y: bottomOpen ? 0 : -(height + 48),
            width: max(0, bounds.width - left - right),
            height: height
        )
    }

    private func conversationFrame() -> NSRect {
        let left = leftInset()
        let right = rightInset()
        let bottom = bottomInset()
        return NSRect(
            x: left,
            y: bottom,
            width: max(0, bounds.width - left - right),
            height: max(0, bounds.height - bottom)
        )
    }

    private func applyFrames() {
        leftPanel.frame = leftFrame()
        rightPanel.frame = rightFrame()
        bottomPanel.frame = bottomFrame()
        let workspace = conversationFrame()
        conversations.values.forEach { $0.frame = workspace }
        for plugin in plugins.plugins where plugin.placement == .workspace { plugin.view.frame = workspace }

        let size = bottomPanel.bounds
        bottomHost.frame = NSRect(x: 10, y: 8, width: max(0, size.width - 20), height: max(0, size.height - 22))
    }

    // MARK: 拖入文件夹

    /// 只接受文件夹：文件、文本等其他拖放内容保持原有行为。
    static func droppedFolder(from urls: [URL]) -> URL? {
        for url in urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            return url.standardizedFileURL
        }
        return nil
    }

    /// 拖到窗口或 Dock 图标上的文件夹都走这里：基于该文件夹开一条新对话。
    /// 左侧“项目”列表来自会话文件，所以新对话要等第一句话发出、会话写入后才出现。
    func openDroppedFolder(_ url: URL) {
        guard let folder = Self.droppedFolder(from: [url]) else { return }
        confirmPluginClose { [weak self] allowed in
            guard allowed else { return }
            self?.openProject(folder)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.droppedFolder(from: draggedURLs(sender)) != nil else { return [] }
        showDropHint()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.droppedFolder(from: draggedURLs(sender)) != nil else {
            hideDropHint()
            return []
        }
        showDropHint()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hideDropHint() }
    override func draggingEnded(_ sender: NSDraggingInfo) { hideDropHint() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.droppedFolder(from: draggedURLs(sender)) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDropHint()
        guard let folder = Self.droppedFolder(from: draggedURLs(sender)) else { return false }
        openDroppedFolder(folder)
        return true
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    private func showDropHint() {
        guard dropHint.isHidden else { return }
        dropHint.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func hideDropHint() {
        guard !dropHint.isHidden else { return }
        dropHint.isHidden = true
    }

    // MARK: 按钮

    @objc private func toggleLeft() {
        leftOpen.toggle()
        if leftOpen { chatView.reload(busySessions: busySessionPaths) }
        leftButton.isActive = leftOpen
        animateLayout()
    }

    @objc private func toggleRight() {
        guard rightButton.isEnabled else { return }
        // 保存失败必须保持面板可见，不能丢弃草稿和撤销记录。
        guard fileBrowser.panelVisibilityChanged(open: !rightOpen) else { return }
        rightOpen.toggle()
        rightButton.isActive = rightOpen
        animateLayout()
    }

    @objc private func toggleBottom() {
        bottomOpen.toggle()
        bottomButton.isActive = bottomOpen
        bottomHost.setVisible(bottomOpen)
        animateLayout()
    }

    private func setProject(_ url: URL) {
        guard flushFileEdits() else { return }
        projectURL = url.standardizedFileURL
        ProjectStore.remember(projectURL)
        // The folder owns one shared scene; conversation state remains private.
        if plugins.isEnabled("whiteboard") { whiteboardPlugin.bindConversation(activeConversation.boardID, project: projectURL) }
        fileBrowser.rootURL = RemoteProjects.load(url) == nil ? url : nil
        plugins.projectDidChange(url)
        bottomHost.projectDidChange(url)
        refreshRightSidebar()
        chatView.selectProject(projectURL, session: activeConversation.sessionPath)
    }

    @objc private func newChat() {
        // 新建/切换项目前处理所有未保存的远程编辑：注册表插件和停靠区 SSH 进程都要询问。
        confirmPluginClose { [weak self] allowed in
            guard allowed else { return }
            self?.showProjectMenu()
        }
    }
    private func showProjectMenu() {
        if plugins.isEnabled("ssh") { SSHSessions.shared.refresh() }
        let menu = NSMenu()
        projectMenu = menu
        populateProjectMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: addButton)
        projectMenu = nil
    }

    private func populateProjectMenu() {
        guard let menu = projectMenu else { return }
        menu.removeAllItems()
        let conversation = NSMenuItem(title: "在当前项目新建对话", action: #selector(newConversationInProject), keyEquivalent: "")
        conversation.target = self; menu.addItem(conversation)
        menu.addItem(.separator())
        let local = NSMenuItem(title: "本机文件夹…", action: #selector(newLocalProject), keyEquivalent: "")
        local.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        local.target = self; menu.addItem(local)
        guard plugins.isEnabled("ssh") else { return }
        menu.addItem(.separator())
        for connection in SSHSessions.shared.available {
            let item = NSMenuItem(title: connection.address + "…", action: #selector(newRemoteProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = connection
            item.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
            menu.addItem(item)
        }
        if SSHSessions.shared.probing {
            let item = NSMenuItem(title: "正在检测 SSH 主机…", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
        } else if SSHSessions.shared.available.isEmpty {
            let item = NSMenuItem(title: "暂无免密或已登录的 SSH 主机", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
        }
    }
    @objc private func newLocalProject() {
        conversationView.startNewChat()
    }
    @objc private func newConversationInProject() { openProject(activeProjectURL) }
    @objc private func newRemoteProject(_ sender: NSMenuItem) {
        guard let connection = sender.representedObject as? SSHConnection else { return }
        SSHSessions.shared.ensure(connection) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.bottomOpen = true; self.bottomButton.isActive = true
                self.bottomHost.setVisible(true)
                self.bottomHost.createProcess("ssh")
                self.animateLayout()
            case .success(let session):
                guard let window = self.window else { return }
                let picker = RemoteFolderPicker(session: session)
                self.folderPicker = picker
                picker.show(in: window) { [weak self, weak session] path in
                    guard let self, let session else { return }
                    do {
                        let project = try RemoteProjects.create(RemoteProject(connection: connection, endpoint: session.endpoint, path: path))
                        self.openProject(project)
                        let ssh = self.bottomHost.process(kind: "ssh")?.plugin as? SSHPlugin
                        ssh?.panel.present(session)
                    } catch {
                        let alert = NSAlert(); alert.messageText = error.localizedDescription; alert.beginSheetModal(for: window)
                    }
                }
            }
        }
    }

    private func animateLayout() {
        animatingCount += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            self.leftPanel.animator().frame = self.leftFrame()
            self.rightPanel.animator().frame = self.rightFrame()
            self.bottomPanel.animator().frame = self.bottomFrame()
            let workspace = self.conversationFrame()
            self.conversations.values.forEach { $0.animator().frame = workspace }
            for plugin in self.plugins.plugins where plugin.placement == .workspace { plugin.view.animator().frame = workspace }
            let size = self.bottomPanel.bounds
            self.bottomHost.animator().frame = NSRect(x: 10, y: 8, width: max(0, size.width - 20), height: max(0, size.height - 22))
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.animatingCount -= 1
            if self.animatingCount == 0 { self.needsLayout = true }
        }
    }
}

