// Production modules + real OpenSSH multiplexed PTY, isolated from user hosts and config.
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func eventually(_ name: String, _ predicate: @escaping () -> Bool, _ next: @escaping () -> Void) {
    let deadline = Date().addingTimeInterval(10)
    var timer: Timer?
    timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
        if predicate() { timer?.invalidate(); next() }
        else if Date() > deadline { fputs("FAIL: timeout \(name)\n", stderr); exit(1) }
    }
}
func success<T>(_ result: Result<T, Error>) -> T {
    switch result { case .success(let value): return value; case .failure(let error): fputs("FAIL: \(error)\n", stderr); exit(1) }
}
func failure<T>(_ result: Result<T, Error>, containing text: String) {
    if case .failure(let error) = result { expect(error.localizedDescription.contains(text), "unexpected failure: \(error)") }
    else { expect(false, "expected error containing \(text)") }
}
final class FixturePlugin: FPlugin {
    let id: String
    let title: String
    let symbol = "terminal"
    let placement = PluginPlacement.bottom
    let projectAssociation = PluginProjectAssociation.project
    let view = NSView()
    var activated = 0, deactivated = 0, stopped = 0, confirmations = 0
    var allowClose = true
    var project: URL?
    init(_ id: String) { self.id = id; title = id }
    func activate() { activated += 1 }
    func deactivate() { deactivated += 1 }
    func projectDidChange(_ url: URL) { project = url }
    func shutdown() { stopped += 1 }
    func confirmClose(_ completion: @escaping (Bool) -> Void) { confirmations += 1; completion(allowClose) }
}
extension TerminalView {
    static func canonicalForTest(_ path: String) -> String { realPath(path) }
    var visibleOutputForTest: String { renderedText }
    var rendererReadyForTest: Bool { ready }
    var pidForTest: pid_t { pid }
    func inputForTerminalTest(_ value: String) {
        let json = String(data: try! JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)!
        webView.evaluateJavaScript("window.FT.input(\(json).at(0))", completionHandler: nil)
    }
    static func checkClearSequences(_ done: @escaping () -> Void) {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        terminal.layoutSubtreeIfNeeded()
        eventually("terminal renderer ready", { terminal.ready }) {
            terminal.feed(Data(String(repeating: "OLD_SCROLLBACK\r\n", count: 160).utf8))
            eventually("terminal history", { terminal.renderedText.contains("OLD_SCROLLBACK") }) {
                for byte in Data("\u{1B}[H\u{1B}[2J\u{1B}[3J~ % 中文".utf8) { terminal.feed(Data([byte])) }
                eventually("fragmented clear", { terminal.renderedText == "~ % 中文" }) {
                    expect(terminal.terminalState["baseY"] as? Int == 0, "clear resets the saved history")
                    terminal.feed(Data("\r\u{1B}[K~ % \u{1B}]0;window".utf8))
                    terminal.feed(Data(" title\u{1B}".utf8)); terminal.feed(Data("\\OK".utf8))
                    eventually("split title and line clearing", { terminal.renderedText == "~ % OK" }) {
                        print("PASS: complete VT renderer, fragmented ANSI/UTF-8, clear, scrollback and line redraw")
                        done()
                    }
                }
            }
        }
    }
}

extension RootView {
    func checkNativeWorkspaceChromeForTest() {
        let saved = frame, wasLeft = leftOpen, wasRight = rightOpen, wasBottom = bottomOpen
        defer { frame = saved; leftOpen = wasLeft; rightOpen = wasRight; bottomOpen = wasBottom; layout() }
        showApplication("browser")
        for width in [CGFloat(520), CGFloat(900)] {
            for (left, right) in [(false,false), (true,false), (false,true), (true,true)] {
                frame.size = NSSize(width: width, height: 600)
                leftOpen = left; rightOpen = right; bottomOpen = false; layout()
                let controlsBottom = min(bottomButton.frame.minY, rightButton.frame.minY)
                for id in ["gmail", "daily-paper"] {
                    let application = plugins.plugin(id)!.view
                    expect(application.frame.maxY <= controlsBottom - 8, "\(id) content stays clear of F host controls")
                }
                let browser = plugins.plugin("browser") as! BrowserPlugin
                browser.view.layout()
                let toolbar = browser.toolbarView!
                toolbar.layout()
                let field = toolbar.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }!
                expect(browser.view.frame == conversationFrame(), "browser page stays in the workspace")
                expect(toolbar.superview === self && toolbar.frame.minX >= browser.view.frame.minX && toolbar.frame.maxX <= browser.view.frame.maxX, "browser toolbar stays between the expanded sidebars")
                expect(field.placeholderString?.isEmpty != false, "search field has no placeholder")
                expect(!field.isHidden, "narrow windows keep room for navigation and search with both sidebars open")
                if !field.isHidden {
                    let rect = convert(field.frame, from: toolbar)
                    expect(abs(rect.midY - bottomButton.frame.midY) < 1, "search aligns with sidebar and bottom buttons")
                    expect(rect.minX >= addButton.frame.maxX + 8 && rect.maxX <= bottomButton.frame.minX - 8, "search never covers host buttons with either sidebar open")
                    expect(abs(rect.maxX - (min(browser.view.frame.maxX, bottomButton.frame.minX) - 20)) < 1, "search fills the available row up to the sidebar or software buttons")
                    let back = toolbar.subviews.first { $0.identifier?.rawValue == "back" }!
                    expect(abs(convert(back.frame, from: toolbar).minX - (max(browser.view.frame.minX, addButton.frame.maxX) + 8)) < 1, "navigation begins after the sidebar or software buttons with one inset")
                    for item in toolbar.subviews {
                        let itemRect = convert(item.frame, from: toolbar)
                        expect(!left || !itemRect.intersects(leftPanel.frame), "browser control never overlaps the open left sidebar")
                        expect(!right || !itemRect.intersects(rightPanel.frame), "browser control never overlaps the open right sidebar")
                        expect(!itemRect.intersects(addButton.frame) && !itemRect.intersects(bottomButton.frame), "browser control never overlaps software buttons")
                    }
                    expect(field.toolTip == nil && toolbar.toolTip == nil, "browser input has no hover shortcut hint")
                }
                expect(whiteboardView.frame == conversationFrame(), "whiteboard keeps its existing web chrome insets")
            }
        }
        showApplication("browser")
        expect(plugins.plugin("browser")!.toolbarView?.isHidden == false, "browser toolbar is visible only with its workspace")
        showConversation(nil)
        expect(plugins.plugin("browser")!.toolbarView?.isHidden == true, "browser toolbar hides when returning to chat")
    }
    func resumeFixtureDrafts() {
        conversationView.setUpdateFixture()
        whiteboardView.draftText = "board draft"
    }
    /// 输入框悬停不应出现快捷键提示：合成器里任何控件的 tooltip 都不能讲按键。
    func checkComposerHasNoShortcutHints() {
        let composer = GlassComposer(frame: NSRect(x: 0, y: 0, width: 700, height: 80))
        composer.layoutSubtreeIfNeeded()
        var hints: [String] = []
        var textViews = 0
        func walk(_ view: NSView) {
            if view is NSTextView { textViews += 1 }
            if let tip = view.toolTip { hints.append(tip) }
            view.subviews.forEach(walk)
        }
        walk(composer)
        expect(textViews >= 1, "composer keeps its text input")
        expect(hints.allSatisfy { hint in !["Enter", "↩", "⌘", "Cmd", "Shift"].contains { hint.contains($0) } },
               "composer never shows a shortcut hint on hover")
    }
    func checkUpdateAnnouncement(_ notice: String, _ done: @escaping () -> Void) {
        conversationView.updateAnnouncementForTest(notice, done)
    }
}
extension ConversationView {
    func setUpdateFixture() {
        composer.draftText = "main draft"
        selectedModel = AgentModel(provider: "fixture", id: "test-model", name: "Fixture Model", reasoning: true)
        selectedThinking = "high"
        busy = true; expect(!canRestartForUpdate, "updates must wait for the active task"); busy = false
        queue = [QueuedPrompt(id: 99, text: "queued")]
        expect(!canRestartForUpdate, "updates must wait for queued prompts"); queue.removeAll()
    }
    func updateAnnouncementForTest(_ notice: String, _ done: @escaping () -> Void) {
        expect(composer.draftText == "main draft" && selectedModel?.id == "test-model", "update restores draft and model")
        // Reopening history after a restart must not erase the application's update receipt.
        present([])
        webView.evaluateJavaScript("document.body.textContent.includes(\(Self.jsString(notice)))") { result, error in
            expect(error == nil && result as? Bool == true, "update notice appears in the main conversation")
            done()
        }
    }
}
func updateResumeChecks(_ done: @escaping () -> Void) {
    let defaults = UserDefaults.standard, previous = defaults.object(forKey: PluginPreferences.disabledKey)
    defaults.set(["ssh"], forKey: PluginPreferences.disabledKey)
    ProjectStore.remember(root)
    let original = RootView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    original.resumeFixtureDrafts()
    let notice = "终端编辑已修复，原功能保留。"
    let state = original.prepareUpdateResume(id: "abc-123", announcement: notice)
    let decoded = try! JSONDecoder().decode(UpdateResume.self, from: JSONEncoder().encode(state))
    let restored = RootView(frame: original.frame)
    restored.restoreAfterUpdate(decoded)
    eventually("restored update conversation", { restored.isUpdateUIReady }) {
        restored.checkUpdateAnnouncement(notice) {
            expect(restored.boardForTest.draftText == "board draft" && restored.visibleAppForTest == nil, "restart restores board draft and opens the main chat")
            original.shutdownPlugins(); restored.shutdownPlugins()
            if let previous { defaults.set(previous, forKey: PluginPreferences.disabledKey) } else { defaults.removeObject(forKey: PluginPreferences.disabledKey) }
            print("PASS: update waits for task/queue, restores project/model/drafts and announces in the main chat")
            done()
        }
    }
}
func terminalEditing(_ terminal: TerminalView, label: String, _ done: @escaping () -> Void) {
    eventually("\(label) renderer", { terminal.rendererReadyForTest }) {
        terminal.inputForTerminalTest("printf 'EDIT:%s\\n' axc\u{1b}[D\u{7f}b\u{1b}[C\r")
        eventually("\(label) left/right and backspace", { terminal.visibleOutputForTest.contains("EDIT:abc") }) {
            terminal.inputForTerminalTest("printf 'DELETE:%s\\n' abxc\u{1b}[D\u{1b}[D\u{1b}[3~\r")
            eventually("\(label) forward delete", { terminal.visibleOutputForTest.contains("DELETE:abc") }) {
                terminal.inputForTerminalTest("\u{1b}[A\r")
                eventually("\(label) up history", { terminal.visibleOutputForTest.components(separatedBy: "DELETE:abc").count >= 3 }) {
                    terminal.inputForTerminalTest("\u{1b}[A\u{1b}[Bprintf 'DOWN:%s\\n' yes\r")
                    eventually("\(label) down history", { terminal.visibleOutputForTest.contains("DOWN:yes") }) {
                        terminal.inputForTerminalTest("cat completion-targ\t\r")
                        eventually("\(label) Tab filename completion", { terminal.visibleOutputForTest.contains("COMPLETE_READY") && terminal.visibleOutputForTest.contains("completion-target.txt") }) {
                            print("PASS: \(label) arrows, Backspace, forward Delete, history up/down and Tab completion through the real terminal input bridge")
                            done()
                        }
                    }
                }
            }
        }
    }
}

extension RemoteBrowserView {
    var busyForTest: Bool { loading }
    var textForTest: String { editor.string }
    var statusForTest: String { status.stringValue }
    func editForTest(_ text: String) { editor.string = text; textDidChange(Notification(name: NSText.didChangeNotification)) }
}
extension SSHSession {
    func passwordFixture(_ root: URL, _ done: @escaping () -> Void) {
        let productionOutput = terminal.onOutput
        var output = ""
        terminal.onOutput = { data in productionOutput?(data); output += String(decoding: data, as: UTF8.self) }
        terminal.startCommand("/bin/sh", arguments: ["-c", "stty -echo; printf 'Password:'; IFS= read -r answer; if [ \"$answer\" = fixture-password ]; then printf '\\nAUTH_OK\\n'; fi"], in: root)
        eventually("white login password challenge", { if case .password = self.phase { return true }; return false }) {
            self.answer("fixture-password")
            eventually("password PTY", { output.contains("AUTH_OK") && !self.terminal.isRunning }) {
                expect(!output.contains("fixture-password"), "password must not echo into terminal output")
                print("PASS: Enter-driven password challenge uses PTY without argv/config/history exposure")
                done()
            }
        }
    }
}
extension BottomPluginHost {
    var choiceCountForTest: Int { buttons.values.filter { !$0.isHidden }.count }
    var fullContentForTest: Bool {
        layoutSubtreeIfNeeded()
        // 底栏仍在窗口底部：左侧是占满高度的进程页面，右侧是一列纵向进程标签。
        return !content.isHidden && !tabBar.isHidden && !addButton.isHidden
            && content.frame.height >= bounds.height - 1
            && content.frame.minX >= -0.5
            && tabBar.frame.minX >= content.frame.maxX - 0.5
            && tabBar.frame.maxY <= bounds.height + 0.5
    }
    var tabFramesForTest: [NSRect] {
        layoutSubtreeIfNeeded()
        return processes.compactMap { tabs[$0.id]?.frame }
    }
    /// 模拟拖动灰色分隔线，用来验证标签列可调宽。
    func resizeStripForTest(_ delta: CGFloat) { stripHandle.onDrag?(delta) }
    /// 标签列与进程页面在停靠区坐标系中的位置，用来确认标签在右侧。
    var tabColumnForTest: (bar: NSRect, content: NSRect) {
        layoutSubtreeIfNeeded()
        return (tabBar.frame, content.frame)
    }
    var processNamesForTest: [String] { processes.map(\.name) }
    /// 取到某个进程当前的标签，用来验证原位改名。
    func tabForTest(_ id: String) -> DockTabView? { tabs[id] }
}

extension DockTabView {
    /// 直接读写标签里的输入框文字，模拟用户键入。
    var labelTextForTest: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
}

/// 一个可以多次启动的底栏模块，用来验证多进程和默认命名。
final class FixtureProcessModule: FPlugin, FProcessProvider {
    let id: String
    let title: String
    let symbol = "square.on.square"
    let placement = PluginPlacement.bottom
    let processDefaultName = "worker"
    let view = NSView()
    private(set) var made: [FixturePlugin] = []
    init(_ id: String) { self.id = id; title = id }
    func makeProcess(project: URL) -> FPlugin {
        let process = FixturePlugin(id + "-process")
        made.append(process)
        return process
    }
}
final class FixtureApplication: FPlugin {
    let id = "fixture-app", title = "测试应用", symbol = "square"
    let placement = PluginPlacement.workspace
    let view = NSView()
    var receivedProject = false
    var performed: String?
    var menuCommands: [PluginMenuCommand] { [PluginMenuCommand(title: "打开", id: "open"), PluginMenuCommand(title: "设置…", id: "settings")] }
    func projectDidChange(_ project: URL) { receivedProject = true }
    func performMenuCommand(_ command: String) { performed = command }
}
extension RootView {
    func refreshPluginsForTest() { refreshPluginState() }
    func projectForTest(_ project: URL) { setProject(project) }
    var visibleAppForTest: String? { if case .application(let id) = mode { return id }; return nil }
    var appRowsForTest: [String] { leftSidebar.idsForTest }
    var boardForTest: WhiteboardView { whiteboardView }
    func toggleBottomForTest() { toggleBottom() }
    func newChatForTest() { newChat() }
    func applyFramesForTest() { applyFrames() }
    var bottomOpenForTest: Bool { bottomOpen }
    var bottomPanelFrameForTest: NSRect { bottomPanel.frame }
    var bottomPanelForTest: BottomPanel { bottomPanel }
    var bottomHostForTest: BottomPluginHost { bottomHost }
    var conversationFrameForTest: NSRect { conversationFrame() }
}
extension SSHPanelView {
    var shellTerminalForTest: TerminalView? { shellTerminal }
    var terminalHostForTest: NSView { terminalHost }
}
extension SideAgentView {
    var pageTextForTest: String { transcript.string }
    func setPendingWorkForTest(busy: Bool) {
        self.busy = busy
    }
}
extension LeftSidebarView { var idsForTest: [String] { appRows.map(\.id) } }
extension WhiteboardView {
    var sceneForPluginTest: URL? { sceneURL }
    var watchingForPluginTest: Bool { watchTimer != nil }
}
extension AppDelegate {
    func menusForTest(_ root: RootView) { rootView = root; buildMenu(); rebuildPluginMenus() }
    var appMenuTitlesForTest: [String] { applicationsMenu?.items.map(\.title) ?? [] }
    var checkedPluginsForTest: [String] { pluginMenu?.items.filter { $0.state == .on }.compactMap { $0.representedObject as? String } ?? [] }
    func openFoldersForTest(_ urls: [URL]) { application(NSApp, open: urls) }
    func cleanupMenusForTest() { rootView = nil; NSApp.mainMenu = nil }
}
extension ChatListDocumentView {
    var titlesForTest: [String] { items.compactMap { ($0.view as? ChatRowView)?.title } }
    var projectPathsForTest: [String] { items.filter { $0.inset == 6 }.compactMap { $0.view.toolTip } }
}
extension ChatListView {
    var titlesForTest: [String] { listView.titlesForTest }
    var projectPathsForTest: [String] { listView.projectPathsForTest }
}
extension RootView {
    var chatTitlesForTest: [String] { chatView.titlesForTest }
    var chatProjectPathsForTest: [String] { chatView.projectPathsForTest }
    func reloadHistoryForTest() { chatView.reload(busySessions: []) }
    var dropHintHiddenForTest: Bool { dropHint.isHidden }
    var dropHintForTest: FolderDropHintView { dropHint }
    func showDropHintForTest() { showDropHint() }
    func hideDropHintForTest() { hideDropHint() }
}
func folderDropChecks(_ done: @escaping () -> Void) {
    // 拖入的只能是真实存在的文件夹；文件、链接和已消失的目录都不应开新对话。
    let folder = root.appendingPathComponent("拖入的 文件夹")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("note.txt")
    try! "note".write(to: file, atomically: true, encoding: .utf8)
    expect(RootView.droppedFolder(from: [folder])?.path == folder.standardizedFileURL.path,
           "a dropped folder becomes the conversation project")
    expect(RootView.droppedFolder(from: [file]) == nil,
           "a dropped file never starts a conversation")
    expect(RootView.droppedFolder(from: [URL(string: "https://example.com")!]) == nil,
           "only local folders open a conversation")
    expect(RootView.droppedFolder(from: [folder.appendingPathComponent("missing")]) == nil,
           "a folder that no longer exists is ignored")

    ProjectStore.remember(root)
    let host = RootView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let delegate = AppDelegate()
    delegate.menusForTest(host)
    expect(host.registeredDraggedTypes.contains(.fileURL),
           "the window registers folder drags so any position accepts them")
    host.reloadHistoryForTest()
    let before = host.chatTitlesForTest
    expect(host.dropHintHiddenForTest, "the drop hint stays hidden until a folder is dragged over the window")
    host.showDropHintForTest()
    expect(!host.dropHintHiddenForTest && host.dropHintForTest.hitTest(NSPoint(x: 5, y: 5)) == nil,
           "the drop hint appears without stealing the drag target")
    host.hideDropHintForTest()
    expect(host.dropHintHiddenForTest, "leaving the window hides the drop hint")

    // Dock 图标与窗口拖放走同一个入口。
    delegate.openFoldersForTest([file, folder])
    expect(host.conversationView.projectPath == folder.standardizedFileURL.path,
           "dropping a folder on the window or Dock icon opens a conversation for it")
    expect(host.conversationView.sessionPath == nil && host.conversationView.boardID != nil,
           "the dropped conversation starts empty with its own identity")
    expect(host.chatProjectPathsForTest.contains(folder.standardizedFileURL.path),
           "an opened project folder appears immediately before its first message")
    expect(host.chatTitlesForTest == before && !host.chatTitlesForTest.contains("第一句话"),
           "an empty conversation does not invent a persisted history message")

    // 第一句话写入会话文件后，出现在已存在的文件夹项目下面。
    let sessions = PiHistory.agentDirectory()!
    let sessionFolder = sessions.appendingPathComponent("drop-check")
    try! FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
    let session = sessionFolder.appendingPathComponent("drop-check.jsonl")
    let header: [String: Any] = ["type": "session", "id": "drop-check", "cwd": folder.path]
    let message: [String: Any] = ["type": "message", "message": ["role": "user", "content": "第一句话"]]
    func jsonLine(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
    try! (jsonLine(header) + "\n" + jsonLine(message) + "\n").write(to: session, atomically: true, encoding: .utf8)
    host.reloadHistoryForTest()
    expect(host.chatTitlesForTest.contains("第一句话"),
           "the first conversation appears beneath its project folder")
    try? FileManager.default.removeItem(at: sessionFolder)

    host.shutdownPlugins()
    delegate.cleanupMenusForTest()
    print("PASS: folder drop immediately adds a project; its first message adds an indented conversation")
    done()
}
func pluginToggleChecks() {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: PluginPreferences.disabledKey)
    defaults.set(["ssh"], forKey: PluginPreferences.disabledKey)
    ProjectStore.remember(root)
    let rootView = RootView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    rootView.checkNativeWorkspaceChromeForTest()
    rootView.checkComposerHasNoShortcutHints()
    let menus = AppDelegate()
    rootView.onPluginsChanged = { menus.menusForTest(rootView) }
    menus.menusForTest(rootView)
    expect(Set(menus.appMenuTitlesForTest) == ["画板", "版本", "Daily Paper", "Gmail", "浏览器"] && Set(menus.checkedPluginsForTest) == ["whiteboard", "terminal", "side-agent", "skills", "subagent", "workflow", "files", "versions", "aios", "datasets", "daily-paper", "gmail", "browser"], "application menus and checked plugin states")
    rootView.plugins.setEnabled("whiteboard", false)
    expect(!rootView.appRowsForTest.contains("whiteboard") && Set(menus.appMenuTitlesForTest) == ["版本", "Daily Paper", "Gmail", "浏览器"] && rootView.visibleAppForTest == nil, "disabled board disappears from application list, menus and workspace")
    expect(!rootView.boardForTest.watchingForPluginTest, "disabled board stops polling")
    let next = root.appendingPathComponent("after-disabled-project")
    try! FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
    let file = BoardStore.sceneFile(for: next)
    try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = Data("{\"elements\":[],\"files\":{},\"type\":\"f-whiteboard\"}".utf8)
    try! data.write(to: file)
    rootView.projectForTest(next)
    rootView.plugins.setEnabled("whiteboard", true)
    expect(rootView.boardForTest.sceneForPluginTest == file && rootView.boardForTest.watchingForPluginTest, "re-enabled board binds to the latest project and resumes polling")
    expect((try! Data(contentsOf: file)) == data, "plugin toggle must preserve centralized board data")
    let fresh = PluginRegistry()
    expect(!fresh.isEnabled("ssh") && fresh.isEnabled("whiteboard"), "plugin state survives creating a fresh registry")
    let application = FixtureApplication()
    rootView.plugins.register(application)
    rootView.refreshPluginsForTest()
    expect(rootView.appRowsForTest.contains(application.id) && menus.appMenuTitlesForTest.contains(application.title), "new workspace plugin automatically gets a sidebar row and application menu")
    rootView.performApplicationCommand(application.id, command: "settings")
    expect(application.performed == "settings" && rootView.visibleAppForTest == application.id && !application.receivedProject, "independent application receives its settings action without project binding")
    expect(PluginStorage.directory(for: "fixture-app", project: root) != PluginStorage.directory(for: "fixture-app", project: next), "project plugin storage isolation")
    rootView.plugins.setEnabled("terminal", false)
    expect(rootView.plugins.bottomPlugins.map(\.id) == ["side-agent"], "disabled bottom plugins disappear from choices")
    rootView.toggleBottomForTest()
    expect(rootView.bottomOpenForTest && !rootView.bottomHostForTest.hasProcesses, "empty bottom bar opens the chooser at the bottom")
    let dockProcess = rootView.bottomHostForTest.createProcess("side-agent")
    rootView.applyFramesForTest()
    expect(rootView.bottomPanelFrameForTest.minY == 0 && rootView.bottomPanelFrameForTest.height > 0,
           "the first process keeps the bottom bar at the bottom")
    expect(rootView.conversationFrameForTest.width == rootView.bounds.width,
           "the bottom bar never takes width from the workspace")
    expect(rootView.conversationFrameForTest.height < rootView.bounds.height,
           "main content shrinks vertically for the bottom bar")
    let tallMain = rootView.conversationFrameForTest.height
    rootView.bottomPanelForTest.onResize?(40)
    rootView.applyFramesForTest()
    expect(rootView.conversationFrameForTest.height == tallMain - 40 && rootView.bottomPanelFrameForTest.minY == 0,
           "dragging the top edge resizes the bottom bar and keeps it docked at the bottom")
    rootView.bottomPanelForTest.onResize?(-40)
    rootView.applyFramesForTest()
    expect(rootView.conversationFrameForTest.height == tallMain, "dragging back restores the bottom bar height")
    expect(rootView.bottomHostForTest.fullContentForTest, "the bottom bar shows vertical process tabs right of the page")
    let tabFrames = rootView.bottomHostForTest.tabFramesForTest
    let columns = rootView.bottomHostForTest.tabColumnForTest
    expect(tabFrames.count == 1 && columns.bar.minX >= columns.content.maxX - 0.5
           && columns.bar.minX >= rootView.bottomHostForTest.bounds.width / 2,
           "process tabs stay in the right column of the bottom bar")
    if let side = dockProcess?.plugin as? SideAgentPlugin {
        expect(rootView.canRestartForUpdate, "an idle side agent does not block updates")
        side.agentView.setPendingWorkForTest(busy: true)
        expect(!rootView.canRestartForUpdate, "updates wait for a running side agent task")
        side.agentView.setPendingWorkForTest(busy: false)
        expect(rootView.canRestartForUpdate, "updates resume after the side agent task ends")
    }
    rootView.toggleBottomForTest()
    rootView.applyFramesForTest()
    expect(!rootView.bottomOpenForTest && rootView.conversationFrameForTest.height == rootView.bounds.height,
           "closing the bottom bar keeps the process but frees the workspace")
    expect(rootView.bottomHostForTest.hasProcesses, "closing the bottom bar keeps the process")
    rootView.toggleBottomForTest()
    rootView.applyFramesForTest()
    expect(rootView.bottomOpenForTest && rootView.bottomHostForTest.selectedID != nil,
           "reopening with processes skips the chooser and stays at the bottom")
    if let dockProcess { rootView.bottomHostForTest.closeProcess(dockProcess.id) }
    rootView.applyFramesForTest()
    expect(rootView.bottomOpenForTest && rootView.bottomHostForTest.choosing,
           "closing every process restores the chooser in the same bottom bar")
    let confirmModule = FixtureProcessModule("fixture-confirm")
    rootView.plugins.register(confirmModule)
    rootView.refreshPluginsForTest()
    if let confirmProcess = rootView.bottomHostForTest.createProcess(confirmModule.id) {
        (confirmProcess.plugin as? FixturePlugin)?.allowClose = false
        rootView.newChatForTest()
        expect((confirmProcess.plugin as? FixturePlugin)?.confirmations == 1,
               "new chat asks dock processes before opening the project menu")
        (confirmProcess.plugin as? FixturePlugin)?.allowClose = true
        rootView.bottomHostForTest.closeProcess(confirmProcess.id)
    }
    rootView.toggleBottomForTest()
    rootView.shutdownPlugins()
    rootView.onPluginsChanged = nil
    menus.cleanupMenusForTest()
    if let previous { defaults.set(previous, forKey: PluginPreferences.disabledKey) } else { defaults.removeObject(forKey: PluginPreferences.disabledKey) }
    print("PASS: plugin checkmarks, persisted toggles, hidden/restored board, latest project binding, independent app registration and menu routing")
}
func configAndLifecycle() {
    expect(try! SSHConnection.parse("user@host:433") == SSHConnection(host: "host", user: "user", port: 433), "user/host/port parser")
    expect(try! SSHConnection.parse("host") == SSHConnection(host: "host"), "missing user/port must keep OpenSSH defaults")
    expect(try! SSHConnection.parse("host:433") == SSHConnection(host: "host", port: 433), "port without user")
    expect(try! SSHConnection.parse("user@[::1]:433") == SSHConnection(host: "::1", user: "user", port: 433), "IPv6 parser")
    let one = try! RemoteProjects.create(RemoteProject(connection: SSHConnection(host: "one"), endpoint: "u@one:22", path: "/project"), root: root.appendingPathComponent("remote-projects"))
    let same = try! RemoteProjects.create(RemoteProject(connection: SSHConnection(host: "alias"), endpoint: "u@one:22", path: "/project"), root: root.appendingPathComponent("remote-projects"))
    let other = try! RemoteProjects.create(RemoteProject(connection: SSHConnection(host: "other"), endpoint: "u@two:22", path: "/project"), root: root.appendingPathComponent("remote-projects"))
    expect(one == same && one != other, "remote identity uses canonical endpoint plus path, and preserves alias equivalence")
    expect(BoardStore.sceneFile(for: one) == BoardStore.sceneFile(for: same) && BoardStore.sceneFile(for: one) != BoardStore.sceneFile(for: other), "remote project board binding and isolation")
    let config = root.appendingPathComponent("parser-config")
    let includes = root.appendingPathComponent("conf.d")
    try! FileManager.default.createDirectory(at: includes, withIntermediateDirectories: true)
    try! "Host included alias-two\nInclude parser-config\n".write(to: includes.appendingPathComponent("01.conf"), atomically: true, encoding: .utf8)
    try! "HOST = first second # comment\nHost * !skip *.domain\nInclude \"conf.d/*.conf\"\nHost first\nHost bad;host -bad\n".write(to: config, atomically: true, encoding: .utf8)
    expect(SSHConfig.hosts(in: config) == ["first", "second", "included", "alias-two"], "config aliases, Include, quotes, wildcards, duplicate/cycle handling")
    expect(SSHConfig.tokens("HostName=\"value # quoted\" # comment") == ["HostName", "value # quoted"], "config comment tokenizer")
    do { _ = try SSHTransport(connection: SSHConnection(host: "-oProxyCommand=bad")); expect(false, "option-injection host accepted") } catch {}
    let registry = PluginRegistry(), first = FixturePlugin("terminal"), second = FixturePlugin("test-extension")
    registry.register(first); registry.register(second)
    let host = BottomPluginHost(registry: registry)
    host.frame = NSRect(x: 0, y: 0, width: 520, height: 150)
    host.layoutSubtreeIfNeeded()
    host.setVisible(true)
    expect(host.choosing && first.activated == 0 && second.activated == 0, "opening bottom panel only offers choices")
    host.createProcess(second.id)
    expect(!host.choosing && host.choiceCountForTest == 0 && host.fullContentForTest, "selection hides every icon and puts vertical tabs right of the process page")
    expect(second.activated == 1, "the selected process starts")
    host.setVisible(false); host.setVisible(true)
    expect(!host.choosing && host.choiceCountForTest == 0 && host.hasProcesses, "reopening with processes skips the choices")
    host.createProcess(first.id)
    expect(host.processes.count == 2 && first.activated == 1, "one bottom bar can host several process kinds")
    let tabFrames = host.tabFramesForTest
    expect(tabFrames.count == 2 && tabFrames[0].minX == tabFrames[1].minX && tabFrames[0].minY < tabFrames[1].minY,
           "process tabs line up top to bottom in one column")
    let narrowColumn = host.tabColumnForTest.bar.width
    host.resizeStripForTest(-40)
    let wideColumn = host.tabColumnForTest.bar.width
    let wideContent = host.tabColumnForTest.content.width
    host.resizeStripForTest(40)
    expect(wideColumn > narrowColumn && abs(host.tabColumnForTest.bar.width - narrowColumn) < 0.5
           && abs(wideContent + wideColumn - host.bounds.width) < 0.5,
           "dragging the dock separator resizes the tab column and the process page")
    host.selectProcess(host.processes[0].id)
    expect(host.selectedID == host.processes[0].id && host.fullContentForTest, "selecting a tab switches the process page")
    host.selectProcess(host.processes[1].id)
    expect(host.selectedID == host.processes[1].id, "switching back restores the other process")
    host.rename(host.processes[1].id, to: "  我的终端  ")
    expect(host.processes[1].name == "我的终端", "right-click rename trims and updates the process name")
    // 标签本身就是输入框：原位改名，Enter 保存，Esc 放弃。
    if let tab = host.tabForTest(host.processes[1].id) {
        tab.beginRenaming()
        expect(tab.isEditingName, "clicking the selected tab turns its label into a text field")
        tab.labelTextForTest = "  内联名称  "
        tab.endRenaming(commit: true)
        expect(!tab.isEditingName && host.processes[1].name == "内联名称",
               "pressing Enter saves the inline name and leaves the field")
        tab.beginRenaming()
        tab.labelTextForTest = "放弃的名称"
        tab.endRenaming(commit: false)
        expect(host.processes[1].name == "内联名称" && tab.name == "内联名称",
               "Esc restores the previous name without a rename dialog")
        tab.beginRenaming()
        tab.labelTextForTest = "   "
        tab.endRenaming(commit: true)
        expect(host.processes[1].name == "内联名称", "a blank inline name never replaces the old one")
    } else {
        expect(false, "the selected process keeps an editable tab")
    }
    host.projectDidChange(root)
    expect(first.project == root && second.project == root, "processes follow project changes")
    host.closeProcess(host.processes[0].id)
    expect(host.processes.count == 1 && second.stopped == 1, "closing one process stops only that process")
    expect(host.selectedID == host.processes[0].id && host.fullContentForTest, "closing another process keeps the selected content")
    host.closeProcess(host.processes[0].id)
    expect(host.choosing && !host.hasProcesses, "closing the last process returns to the choices")
    registry.shutdown()
    expect(first.stopped == 2 && second.stopped == 2, "module shutdown stops each process once")

    let providerRegistry = PluginRegistry(), provider = FixtureProcessModule("worker")
    providerRegistry.register(provider)
    let dock = BottomPluginHost(registry: providerRegistry)
    dock.setVisible(true)
    let firstProcess = dock.createProcess("worker"), secondProcess = dock.createProcess("worker")
    expect(firstProcess != nil && secondProcess != nil && firstProcess?.id != secondProcess?.id && provider.made.count == 2, "process providers create independent instances")
    expect(dock.processNamesForTest == ["worker", "worker 2"], "default process names are numbered")
    if let firstProcess, let secondProcess { dock.closeProcess(firstProcess.id); dock.closeProcess(secondProcess.id) }
    expect(dock.choosing && !dock.hasProcesses, "provider processes close independently")
    providerRegistry.shutdown()

    let contextView = SideAgentView(project: root)
    var context = "主对话第一版"
    contextView.contextProvider = { context }
    let promptOne = contextView.composePrompt("分析")
    expect(promptOne.contains("主对话第一版"), "side agent request includes the main conversation context")
    context = "主对话第二版"
    let promptTwo = contextView.composePrompt("继续")
    expect(promptTwo.contains("主对话第二版") && !promptTwo.contains("主对话第一版"), "each side agent request reads the latest main conversation context")
    expect(contextView.pageTextForTest == "% " && contextView.pageTextForTest.filter { $0 == "%" }.count == 1,
           "side agent page opens with one prompt at the top and no welcome text")
    contextView.stop()
    expect(contextView.pageTextForTest == "% ", "stopping an idle side agent keeps the single prompt")

    let builtins = BuiltInPlugins.make(project: root)
    expect(builtins.plugins.map(\.id) == ["whiteboard", "terminal", "ssh", "side-agent", "files", "versions", "browser", "daily-paper", "gmail", "aios", "datasets", "skills", "subagent", "workflow"], "built-in module registration")
    expect(builtins.plugin("gmail")?.projectAssociation == .independent && builtins.plugin("gmail")?.placement == .workspace, "Gmail has an independent mailbox workspace")
    expect(builtins.plugin("ssh")?.sidebarView is RemoteBrowserView, "SSH sidebar is provided through plugin contract")
    expect((builtins.plugin("side-agent") as? FProcessProvider)?.processDefaultName == "side agent", "side agent exposes its default process name")
    builtins.shutdown()

    let sideRegistry = PluginRegistry(), sideModule = SideAgentPlugin(project: root)
    sideRegistry.register(sideModule)
    let sideDock = BottomPluginHost(registry: sideRegistry)
    sideDock.setVisible(true)
    let sideProcess = sideDock.createProcess("side-agent")
    expect(sideProcess?.plugin !== sideModule && sideProcess?.name == "side agent", "side agent starts as an independent dock process")
    if let sideProcess { sideDock.closeProcess(sideProcess.id) }
    sideRegistry.shutdown()
    pluginToggleChecks()
    print("PASS: host config parsing, input validation, extensible registration and lifecycle")
}
func localTerminal() {
    let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 200), shellSupportDirectory: root.appendingPathComponent("term-support"))
    var output = ""
    terminal.onOutput = { output += String(decoding: $0, as: UTF8.self) }
    terminal.start(in: root)
    terminal.send(Data("printf '\\nLOCAL_CHECK:%s:%s\\n' \"$PWD\" \"$F_BOARD_DIR\"\n".utf8))
    eventually("local terminal", { output.contains("LOCAL_CHECK:" + TerminalView.canonicalForTest(root.path) + ":" + BoardStore.directory(for: root).path) }) {
        print("PASS: real local PTY preserves project working directory and board environment")
        terminal.send(Data("printf 'LOCAL_CLEAR_BEFORE\\n'; clear; printf 'LOCAL_CLEAR_AFTER\\n'\n".utf8))
        eventually("real local clear", {
            terminal.visibleOutputForTest.contains("LOCAL_CLEAR_AFTER") && !terminal.visibleOutputForTest.contains("LOCAL_CLEAR_BEFORE") && !terminal.visibleOutputForTest.contains("LOCAL_CHECK:")
        }) {
            print("PASS: clear executed by the local shell removes the previous terminal contents")
            terminalEditing(terminal, label: "local") {
                terminal.stop()
                expect(!terminal.isRunning, "local terminal must stop")
                let session = try! SSHSession(connection: SSHConnection(host: "password-fixture"))
                session.passwordFixture(root) { connectRemote() }
            }
        }
    }
}
func connectRemote() {
    transport = try! SSHTransport(connection: SSHConnection(host: "f-loopback"), config: root.appendingPathComponent("config"))
    expect(!transport.terminalArguments.contains("fixture-password"), "no password in SSH arguments")
    remoteTerminal.startCommand("/usr/bin/ssh", arguments: transport.terminalArguments, in: root)
    eventually("real SSH control socket", { FileManager.default.fileExists(atPath: transport.socket) }) {
        transport.home { result in
            let home = success(result)
            expect(home.hasPrefix("/"), "remote home must be absolute")
            transport.list(fixture.path) { result in
                let (path, entries) = success(result)
                expect(path == fixture.path, "remote canonical directory")
                expect(entries.first?.name == "nested", "remote directories sort first")
                expect(entries.contains { $0.name == "new\nline.txt" } && entries.contains { $0.name == "text ' 中文.txt" }, "remote quoting and NUL-delimited filenames")
                print("PASS: real OpenSSH login, shared authenticated connection, remote directory and Unicode filenames")
                remoteTerminal.send(Data("printf 'SSH_CLEAR_BEFORE\\n'; clear; printf 'SSH_CLEAR_AFTER\\n'\n".utf8))
                eventually("real SSH clear", {
                    remoteTerminal.visibleOutputForTest.contains("SSH_CLEAR_AFTER") && !remoteTerminal.visibleOutputForTest.contains("SSH_CLEAR_BEFORE")
                }) {
                    print("PASS: clear executed on a real SSH terminal removes the previous contents")
                    remoteTerminal.send(Data(("cd " + SSHTransport.quote(fixture.path) + "\r").utf8))
                    terminalEditing(remoteTerminal, label: "SSH") { editRemote() }
                }
            }
        }
    }
}
func editRemote() {
    transport.readText(textPath) { result in
        let file = success(result)
        expect(file.text == "first line\n中文\n", "remote UTF-8 read")
        let modified = "edited remotely\n中文 ' $() `literal`\n"
        transport.save(file, text: modified) { result in
            let saved = success(result)
            expect(try! String(contentsOfFile: textPath, encoding: .utf8) == modified, "remote save must persist exact contents")
            let mode = (try! FileManager.default.attributesOfItem(atPath: textPath)[.posixPermissions] as! NSNumber).intValue & 0o777
            expect(mode == 0o640, "save must retain file permissions")
            try! "external change".write(toFile: textPath, atomically: false, encoding: .utf8)
            transport.save(saved, text: "must not overwrite") { result in
                failure(result, containing: "已被修改")
                expect(try! String(contentsOfFile: textPath, encoding: .utf8) == "external change", "conflict must preserve the other writer")
                transport.readText(fixture.appendingPathComponent("zero.bin").path) { result in
                    failure(result, containing: "UTF-8")
                    transport.readText(fixture.appendingPathComponent("big.txt").path) { result in
                        failure(result, containing: "2 MB")
                        transport.readText(fixture.appendingPathComponent("link.txt").path) { result in
                            transport.save(success(result), text: "must not replace link") { result in
                                failure(result, containing: "符号链接")
                                print("PASS: remote atomic save, exact contents, permission preservation, conflict, binary and symlink protection")
                                nativeRemoteBrowser()
                            }
                        }
                    }
                }
            }
        }
    }
}
func nativeRemoteBrowser() {
    browser.attach(transport, home: fixture.path)
    eventually("native remote browser listing", { !browser.busyForTest && browser.directory == fixture.path }) {
        browser.openFile(textPath)
        eventually("native remote file editor", { browser.file?.path == textPath && !browser.busyForTest }) {
            expect(browser.textForTest == "external change", "native editor displays remote contents")
            browser.editForTest("saved from native editor\n")
            expect(browser.hasUnsavedChanges, "editor tracks dirty state")
            browser.save {
                expect(!browser.hasUnsavedChanges, "successful save clears dirty state")
                expect(try! String(contentsOfFile: textPath, encoding: .utf8) == "saved from native editor\n", "native save writes remote contents")
                print("PASS: native remote browser, editable text and save lifecycle")
                remoteAgent()
            }
        }
    }
}
func remoteAgent() {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_TEST_NODE"]!)
    process.arguments = [ProcessInfo.processInfo.environment["F_REMOTE_TEST_SCRIPT"]!]
    process.standardOutput = output
    var environment = ProcessInfo.processInfo.environment
    let descriptor: [String: Any] = ["arguments": transport.commandArguments, "cwd": fixture.path, "endpoint": "loopback", "socket": transport.socket]
    environment["F_REMOTE_PROJECT"] = String(data: try! JSONSerialization.data(withJSONObject: descriptor), encoding: .utf8)!
    environment["F_BOARD_DIR"] = root.appendingPathComponent("remote-agent-board").path
    let local = root.appendingPathComponent("local-proxy")
    try! FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    environment["F_LOCAL_PROXY"] = local.path
    process.environment = environment
    process.terminationHandler = { child in
        let data = output.fileHandleForReading.readDataToEndOfFile()
        DispatchQueue.main.async {
            print(String(decoding: data, as: UTF8.self))
            expect(child.terminationStatus == 0, "production remote agent adapter regression")
            managedRemoteProject()
        }
    }
    try! process.run()
}
func sshProcessCommand(_ pid: pid_t) -> String {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "command=", "-p", String(pid)]
    process.standardOutput = output
    try? process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// 同一端点和项目下的两个 SSH 进程必须各自拥有真实终端视图，并复用同一个 ControlMaster。
func independentSSHPanels(project: RemoteProject, session: SSHSession, _ done: @escaping () -> Void) {
    let panelA = SSHPanelView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    let panelB = SSHPanelView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    panelA.layoutSubtreeIfNeeded()
    panelB.layoutSubtreeIfNeeded()
    panelA.bindProject(project)
    panelB.bindProject(project)
    panelA.present(session)
    panelB.present(session)
    guard let a = panelA.shellTerminalForTest, let b = panelB.shellTerminalForTest else {
        expect(false, "SSH panels must create real terminals")
        return
    }
    var outA = "", outB = ""
    a.onOutput = { outA += String(decoding: $0, as: UTF8.self) }
    b.onOutput = { outB += String(decoding: $0, as: UTF8.self) }
    eventually("two SSH panels", { a.isRunning && b.isRunning }) {
        expect(a !== b, "each SSH process owns a distinct terminal view")
        expect(a.superview === panelA.terminalHostForTest && b.superview === panelB.terminalHostForTest,
               "attaching one SSH terminal does not move the other")
        expect(session.terminal !== a && session.terminal !== b && session.terminal.isRunning,
               "the authenticated terminal is not reused as a process view")
        let markerA = "PANEL_A:" + project.path + ":"
        let markerB = "PANEL_B:" + project.path + ":"
        let commandA = Data("printf 'PANEL_A:%s:%s\\n' \"$PWD\" \"$$\"\n".utf8)
        let commandB = Data("printf 'PANEL_B:%s:%s\\n' \"$PWD\" \"$$\"\n".utf8)
        var lastSend = Date.distantPast
        eventually("independent SSH shells", {
            // 新开的 ssh 会话可能比 PTY 稍晚就绪，重发同一条只读命令。
            if Date().timeIntervalSince(lastSend) > 0.5 {
                lastSend = Date()
                if !outA.contains(markerA) { a.send(commandA) }
                if !outB.contains(markerB) { b.send(commandB) }
            }
            if !a.isRunning && !outA.contains(markerA) { expect(false, "SSH panel A exited early: \(outA.debugDescription)") }
            if !b.isRunning && !outB.contains(markerB) { expect(false, "SSH panel B exited early: \(outB.debugDescription)") }
            return outA.contains(markerA) && outB.contains(markerB)
        }) { [panelA, panelB] in
            // Keep both owners alive until the asynchronous shell assertions finish.
            // Their deinit intentionally stops their own SSH channel.
            expect(a.superview === panelA.terminalHostForTest && b.superview === panelB.terminalHostForTest,
                   "SSH panels remain alive throughout the asynchronous check")
            func shellPID(_ output: String, _ marker: String) -> String {
                let suffix = output.components(separatedBy: marker + project.path + ":").last ?? ""
                return String(suffix.prefix { $0.isNumber })
            }
            let pidA = shellPID(outA, "PANEL_A:"), pidB = shellPID(outB, "PANEL_B:")
            expect(!pidA.isEmpty && !pidB.isEmpty && pidA != pidB, "the two SSH panels have independent remote shells")
            let commandA = sshProcessCommand(a.pidForTest), commandB = sshProcessCommand(b.pidForTest)
            expect(commandA.contains("-S " + session.transport.socket) && commandB.contains("-S " + session.transport.socket),
                   "both SSH processes reuse the same ControlMaster socket")
            expect(!commandA.contains("-M ") && !commandB.contains("-M "),
                   "extra SSH processes do not start another master")
            print("PASS: multiple SSH processes keep independent terminal views and shells while sharing one ControlMaster")
            a.stop(); b.stop()
            done()
        }
    }
}

func managedRemoteProject() {
    let manager = SSHSessions.shared
    let session = try! manager.connect(SSHConnection(host: "f-loopback"), config: root.appendingPathComponent("config"))
    session.wait { result in
        let session = success(result)
        expect(manager.available.contains(session.connection), "logged-in host must be available without a passwordless catalog entry")
        let project = RemoteProject(connection: session.connection, endpoint: session.endpoint, path: fixture.path)
        let proxy = try! RemoteProjects.create(project, root: root.appendingPathComponent("managed-projects"))
        let fake = root.appendingPathComponent("remote-rpc.py")
        let script = """
        #!/usr/bin/python3
        import json,os,sys
        for line in sys.stdin:
            cmd=json.loads(line)
            print(json.dumps(dict(type='response',id=cmd['id'],success=True,data=dict(cwd=os.getcwd(),project=os.environ.get('F_PROJECT'),board=os.environ.get('F_BOARD_DIR'),remote=json.loads(os.environ.get('F_REMOTE_PROJECT','{}'))))),flush=True)
        """
        try! script.write(to: fake, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let rpc = PiRPC()
        expect(rpc.start(cliPath: fake.path, workingDirectory: proxy), "remote project agent startup")
        rpc.request(["type": "get_state"]) { response in
            let data = response["data"] as! [String: Any]
            let descriptor = data["remote"] as! [String: Any]
            expect(data["project"] as? String == fixture.path, "agent environment must identify the remote folder")
            expect(data["board"] as? String == BoardStore.directory(for: proxy).path, "remote agent and GUI must use the same centralized board")
            expect(descriptor["socket"] as? String == session.transport.socket && descriptor["cwd"] as? String == fixture.path, "agent gets the live authenticated SSH descriptor")
            expect(rpc.isConfigured(for: proxy), "remote agent configured socket tracking")
            rpc.stop()
            let terminal = manager.makeTerminal(for: session, project: project)
            var output = ""
            terminal.onOutput = { output += String(decoding: $0, as: UTF8.self) }
            let projectMarker = "PROJECT_PWD:" + fixture.path
            let projectCommand = Data("printf '\\nPROJECT_PWD:%s\\n' \"$PWD\"\n".utf8)
            var lastProjectSend = Date.distantPast
            eventually("remote project terminal cwd", {
                if Date().timeIntervalSince(lastProjectSend) > 0.5 {
                    lastProjectSend = Date()
                    if !output.contains(projectMarker) { terminal.send(projectCommand) }
                }
                if !terminal.isRunning && !output.contains(projectMarker) {
                    expect(false, "project terminal exited early: \(output.debugDescription)")
                }
                return output.contains(projectMarker)
            }) {
                print("PASS: logged-in project selection, canonical metadata, remote RPC environment and project terminal directory")
                independentSSHPanels(project: project, session: session) {
                    manager.refresh(config: root.appendingPathComponent("config"))
                    eventually("passwordless host catalog", { !manager.probing }) {
                        expect(manager.verified[session.connection.key] != nil, "only a successful real passwordless probe enters the catalog")
                        manager.ensure(SSHConnection(host: "not-verified-host")) { result in
                            failure(result, containing: "先在底部")
                            manager.shutdown()
                            disconnected()
                        }
                    }
                }
            }
        }
    }
}
func disconnected() {
    remoteTerminal.stop()
    // An absent master must not silently authenticate a new, independent SSH session.
    eventually("master stopped", { !FileManager.default.fileExists(atPath: transport.socket) }) {
        transport.list(fixture.path) { result in
            if case .success = result { expect(false, "remote operation must fail after interactive master disconnects") }
            browser.detach(); transport.disconnect()
            expect(browser.statusForTest.contains("已断开"), "disconnected browser state")
            print("PASS: disconnect invalidates file operations and cannot fall back to another login")
            print("PASS: all plugin, PTY and real SSH regression scenarios")
            exit(0)
        }
    }
}
func kernelLifecycleChecks() {
    let kernel = FKernel(), provider = FPluginScope()
    var events: [String] = []
    kernel.mount("consumer", requires: ["test.service"]) { scope in
        scope.effect { events.append("start"); return { events.append("stop") } }
    }
    expect(events.isEmpty, "dependent plugin waits for service")
    kernel.provide("test.service", NSObject(), in: provider)
    expect(events == ["start"], "service activates waiting consumer")
    provider.dispose()
    expect(events == ["start", "stop"], "service withdrawal reverses dependent effects")
    let replacement = FPluginScope()
    kernel.provide("test.service", NSObject(), in: replacement)
    expect(events == ["start", "stop", "start"], "service replacement remounts consumer")
    kernel.shutdown(); replacement.dispose()
    expect(events == ["start", "stop", "start", "stop"], "teardown disposes exactly once")
    print("PASS: native microkernel dependency suspension, replacement and reversible effects")
}
kernelLifecycleChecks()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
signal(SIGPIPE, SIG_IGN)
setbuf(stdout, nil)
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_PLUGIN_TEST_ROOT"]!)
let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_PLUGIN_TEST_FIXTURE"]!)
let textPath = fixture.appendingPathComponent("text ' 中文.txt").path
BoardStore.setRoot(root.appendingPathComponent("boards"))
let remoteTerminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
let browser = RemoteBrowserView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
var transport: SSHTransport!
TerminalView.checkClearSequences { updateResumeChecks { folderDropChecks { configAndLifecycle(); localTerminal() } } }
DispatchQueue.main.asyncAfter(deadline: .now() + 100) { fputs("FAIL: plugin suite timed out\n", stderr); exit(1) }
app.run()
