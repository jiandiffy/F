// Compiled beside production source: six independent processes, 300 queued prompts, 500 switches.
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func wait(_ label: String, timeout: TimeInterval = 40, _ condition: @escaping () -> Bool, _ done: @escaping () -> Void) {
    let end = Date().addingTimeInterval(timeout)
    var timer: Timer?
    timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
        if condition() { timer?.invalidate(); done() }
        else if Date() > end { fputs("FAIL: timeout \(label)\n", stderr); exit(1) }
    }
}
func commands() -> [[String: Any]] {
    let data = (try? Data(contentsOf: logFile)) ?? Data()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
}
extension GlassComposer {
    func typeForStress(_ value: String) { draftText = value; submit() }
    func arrowForStress(older: Bool) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: older ? "\u{f700}" : "\u{f701}",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: older ? 126 : 125)!
        textView.keyDown(with: event)
    }
    func cursorForStress(_ offset: Int) { textView.setSelectedRange(NSRange(location: offset, length: 0)) }
    func editForStress(_ value: String) {
        textView.string = value
        textDidChange(Notification(name: NSText.didChangeNotification))
    }
    func markedForStress(_ value: String) {
        textView.setMarkedText(value, selectedRange: NSRange(location: (value as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func unmarkForStress() { textView.unmarkText() }
    var queueForStress: [QueuedPrompt] { queueView.items }
}
extension ConversationView {
    var composerForStress: GlassComposer { composer }
    var sentForStress: Bool { turnPromptSent }
    func finishForStress() { agent.request(["type": "finish"]) }
    func stopForStress() { agent.stop() }
    func noticesForStress(session: String, _ done: @escaping (Bool) -> Void) {
        currentChat = PiChat(id: session, title: "test", date: Date(), path: URL(fileURLWithPath: session), cwd: projectPath)
        present([])
        webView.evaluateJavaScript("document.body.textContent.includes('专属更新公告')") { value, _ in done(value as? Bool == true) }
    }
}
extension WhiteboardView {
    var readyForStress: Bool { webReady }
    var documentForStress: URL? { sceneURL }
    var inputForStress: GlassComposer { composer! }
    func evalForStress(_ script: String, _ done: @escaping (Any?) -> Void) {
        webView.evaluateJavaScript(script) { value, error in
            require(error == nil, "board JS: \(String(describing: error))")
            done(value)
        }
    }
}
extension RootView {
    var boardForStress: WhiteboardView { whiteboardView }
    var viewsForStress: [ConversationView] { Array(conversations.values) }
    func fileForStress(_ project: URL) -> URL {
        conversations.values.first { $0.projectPath == project.path }!.boardDirectory.appendingPathComponent("scene.json")
    }
    func selectViewForStress(_ view: ConversationView) {
        activateConversation(view)
        setProject(URL(fileURLWithPath: view.projectPath))
        showApplication("whiteboard")
    }
    func openForStress(_ url: URL) { openProject(url) }
    func openChatForStress(_ chat: PiChat) { showConversation(chat) }
    func selectForStress(_ url: URL) {
        activateConversation(conversation(for: url))
        setProject(url)
        showApplication("whiteboard")
    }
}

extension ChatListDocumentView {
    var visibleSessionsForStress: [String] { items.compactMap { ($0.view as? ChatRowView)?.session.id } }
    var folderCountForStress: Int { items.filter { $0.inset == 6 }.count }
}

func folderHierarchyChecks() {
    let list = ChatListDocumentView()
    let rows = [("a1", projects[0]), ("a2", projects[0]), ("b1", projects[1])].map { id, project in
        PiChat(id: id, title: id, date: Date(), path: root.appendingPathComponent(id + ".jsonl"), cwd: project.path)
    }
    ProjectStore.remember(projects[2]) // Empty projects are first-class sidebar entries.
    list.setChats(rows)
    list.setSelection(project: projects[0], session: rows[1].path.path)
    require(list.visibleSessionsForStress == ["a1", "a2"], "only selected folder expands its conversations")
    require(list.folderCountForStress >= 3, "folders with no messages remain in the sidebar")
    list.setSelection(project: projects[1], session: rows[2].path.path)
    require(list.visibleSessionsForStress == ["b1"], "selecting another folder collapses all earlier conversations")
    list.setSelection(project: projects[2], session: nil)
    require(list.visibleSessionsForStress.isEmpty, "empty project does not leak another folder's conversation")
    print("PASS: project folder grouping, one expanded folder, multiple conversations, immediate empty-project visibility")
}

func historyChecks() {
    let store = PromptHistory(project: projects[0])
    let composer = GlassComposer(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
    composer.history = store
    composer.layoutSubtreeIfNeeded()
    composer.typeForStress("中文一")
    composer.typeForStress("中文二")
    composer.draftText = "未发送草稿"
    composer.arrowForStress(older: true); require(composer.draftText == "中文二", "Up recalls latest")
    composer.arrowForStress(older: true); require(composer.draftText == "中文一", "Up recalls older")
    composer.arrowForStress(older: false); require(composer.draftText == "中文二", "Down recalls newer")
    composer.arrowForStress(older: false); require(composer.draftText == "未发送草稿", "Down restores draft")
    composer.draftText = "第一行\n第二行"
    composer.cursorForStress(4)
    composer.arrowForStress(older: true)
    require(composer.draftText == "第一行\n第二行", "multiline Up remains cursor movement")
    composer.draftText = ""
    composer.arrowForStress(older: true)
    composer.editForStress("修改后的草稿")
    composer.arrowForStress(older: false)
    require(composer.draftText == "修改后的草稿", "edited recall is not discarded")
    for i in 0..<5000 { store.record("history-\(i)") }
    require(store.entries.count == 200 && store.entries.first == "history-4800", "5000 records stay bounded")
    require(PromptHistory(project: projects[0]).entries == store.entries, "history survives recreation")
    require(PromptHistory(project: projects[1]).entries.isEmpty, "history isolated per project")
    composer.draftText = ""
    composer.markedForStress("zhong")
    composer.arrowForStress(older: true)
    require(composer.draftText == "zhong", "IME arrows must not recall prompt history")
    composer.unmarkForStress()
    let before = store.entries
    store.record(String(repeating: "x", count: 1_000_001))
    require(store.entries == before, "oversized paste does not grow persistent history")
    print("PASS: native Up/Down, draft restore, multiline editing, Chinese, persistence, 5000-record history stress")
}

func boardChecks(_ done: @escaping () -> Void) {
    // A → B → A in the same runloop is the former stale-flush race.
    host.selectForStress(projects[0])
    wait("first board", { host.boardForStress.documentForStress == host.fileForStress(projects[0]) }) {
        for i in 0..<500 { host.selectForStress(projects[i % projects.count]) }
        host.selectForStress(projects[0])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let view = host.boardForStress
            view.evalForStress("window.FWB.getDocumentSnapshot()") { value in
                let snapshot = value as? [String: Any]
                require(snapshot?["documentID"] as? String == host.fileForStress(projects[0]).path, "last requested project wins")
                let scene = snapshot?["scene"] as? [String: Any]
                require((scene?["elements"] as? [[String: Any]])?.first?["id"] as? String == "marker-0", "displayed content belongs to project A")
                for (i, project) in projects.enumerated() {
                    let data = try! Data(contentsOf: host.fileForStress(project))
                    let scene = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                    require((scene["elements"] as! [[String: Any]]).first?["id"] as? String == "marker-\(i)", "no cross-project overwrite after stress")
                }
                print("PASS: 500 rapid project/board switches including A-B-A, correct final document, no cross-project writes")
                done()
            }
        }
    }
}

func sameFolderConversationChecks(_ done: @escaping () -> Void) {
    let cwd = root.appendingPathComponent("same-folder-two-conversations")
    try! FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    ProjectStore.remember(cwd)
    let ui = RootView(frame: host.frame)
    ui.openForStress(cwd)
    let a = ui.conversationView
    a.composerForStress.typeForStress("HOLD-AIOS")
    for i in 0..<8 { a.composerForStress.typeForStress("AIOS-\(i)") }
    ui.openForStress(cwd) // Must create another view even while AIOS is still busy in the SAME folder.
    let b = ui.conversationView
    require(a !== b && a.boardDirectory != b.boardDirectory && a.boardDirectory == a.conversationDirectory && b.boardDirectory == b.conversationDirectory,
            "same folder conversations own separate boards and never merge conversation state")
    b.composerForStress.typeForStress("HOLD-agent")
    for i in 0..<8 { b.composerForStress.typeForStress("agent-\(i)") }
    wait("same folder agents", { a.sentForStress && b.sentForStress && a.sessionPath != nil && b.sessionPath != nil }) {
        require(a.sessionPath != b.sessionPath, "distinct conversations have distinct sessions")
        let first = PiChat(id: "aios", title: "AIOS设计思路", date: Date(), path: URL(fileURLWithPath: a.sessionPath!), cwd: cwd.path)
        let second = PiChat(id: "agent", title: "agent设计思路", date: Date(), path: URL(fileURLWithPath: b.sessionPath!), cwd: cwd.path)
        require(ConversationBoards.id(for: first.path.path) == a.boardID && ConversationBoards.id(for: second.path.path) == b.boardID,
                "new conversation board IDs bind to backend session files")
        let save = { (view: ConversationView, marker: String) in
            let file = view.boardDirectory.appendingPathComponent("scene.json")
            var scene = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            let element: [String: Any] = ["id": marker, "type": "rectangle", "x": 0, "y": 0, "width": 40, "height": 20,
                "angle": 0, "strokeColor": "#111111", "backgroundColor": "transparent", "fillStyle": "solid", "strokeWidth": 1,
                "strokeStyle": "solid", "roughness": 0, "opacity": 100, "version": 1, "versionNonce": 1,
                "isDeleted": false, "groupIds": [], "seed": 1]
            scene["elements"] = (scene["elements"] as? [[String: Any]] ?? []) + [element]
            scene["revision"] = (scene["revision"] as? Int ?? 0) + 1
            try! JSONSerialization.data(withJSONObject: scene).write(to: file, options: .atomic)
        }
        save(a, "aios-diagram"); save(b, "agent-diagram")
        ui.boardForStress.inputForStress.draftText = "agent board draft"
        ui.openChatForStress(first)
        ui.boardForStress.inputForStress.draftText = "aios board draft"
        for i in 0..<200 { ui.openChatForStress(i % 2 == 0 ? first : second) }
        ui.openChatForStress(first)
        ui.performApplicationCommand("whiteboard", command: "open")
        wait("AIOS document selected", { ui.boardForStress.documentForStress == a.boardDirectory.appendingPathComponent("scene.json") }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                ui.boardForStress.evalForStress("window.FWB.getScene().map(e => e.id).sort().join(',')") { value in
                    require(value as? String == "aios-diagram", "AIOS conversation sees only its own diagram")
                    ui.openChatForStress(second)
                    ui.performApplicationCommand("whiteboard", command: "open")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        ui.boardForStress.evalForStress("window.FWB.getScene().map(e => e.id).sort().join(',')") { value in
                            require(value as? String == "agent-diagram", "second conversation keeps its own diagram")
                            require(a.hasPendingWork && b.hasPendingWork, "200 history selections do not stop either agent")
                            a.finishForStress(); b.finishForStress()
                            wait("same folder queues drain", { !a.hasPendingWork && !b.hasPendingWork }) {
                                let resume = ui.prepareUpdateResume(id: "cafe-123", announcement: "")
                                require(resume.background?.contains(where: { $0.project == cwd.path && $0.boardID == a.boardID }) == true,
                                        "same-cwd background conversation included in update snapshot")
                                let restored = RootView(frame: host.frame)
                                let decoded = try! JSONDecoder().decode(UpdateResume.self, from: JSONEncoder().encode(resume))
                                restored.restoreAfterUpdate(decoded)
                                require(restored.viewsForStress.count == 2, "update does not merge same-cwd conversations")
                                let restoredA = restored.viewsForStress.first { $0.boardID == a.boardID }!
                                let restoredB = restored.viewsForStress.first { $0.boardID == b.boardID }!
                                restored.selectViewForStress(restoredA)
                                require(restored.boardForStress.inputForStress.draftText == "aios board draft", "AIOS board draft survives same-cwd restart")
                                restored.selectViewForStress(restoredB)
                                require(restored.boardForStress.inputForStress.draftText == "agent board draft", "agent board draft survives same-cwd restart")
                                restored.shutdownPlugins()
                                a.stopForStress(); b.stopForStress(); ui.shutdownPlugins()
                                print("PASS: folder conversations keep separate boards and sessions, concurrent queues, restart drafts through 200 switches")
                                done()
                            }
                        }
                    }
                }
            }
        }
    }
}

func resumeChecks(_ done: @escaping () -> Void) {
    host.selectForStress(projects[0])
    host.conversationView.composerForStress.draftText = "foreground draft"
    let origin = host.viewsForStress.first { $0.projectPath == projects[3].path }!
    var resume = host.prepareUpdateResume(id: "abc-123", announcement: "专属更新公告")
    resume.noticeProject = projects[3].path
    resume.noticeSession = origin.sessionPath
    let decoded = try! JSONDecoder().decode(UpdateResume.self, from: JSONEncoder().encode(resume))
    let restored = RootView(frame: host.frame)
    restored.restoreAfterUpdate(decoded)
    require(restored.viewsForStress.count == 6, "all background projects restored")
    for original in host.viewsForStress {
        let reopened = restored.viewsForStress.first { $0.projectPath == original.projectPath }!
        let before = original.updateResume(id: "test", announcement: "")
        let after = reopened.updateResume(id: "test", announcement: "")
        require(before.session == after.session && before.model == after.model && before.provider == after.provider &&
                before.thinking == after.thinking && before.mainDraft == after.mainDraft, "each project's session/model/thinking/draft restored")
    }
    require(restored.conversationView.composerForStress.draftText == "foreground draft", "foreground draft restored")
    let requestView = restored.viewsForStress.first { $0.projectPath == projects[3].path }!
    let foreground = restored.conversationView
    wait("restored receipt views", { foreground.isUpdateUIReady && requestView.isUpdateUIReady }) {
        foreground.noticesForStress(session: foreground.sessionPath!) { leaked in
            require(!leaked, "updating from background must not announce in foreground")
            requestView.noticesForStress(session: decoded.noticeSession!) { shown in
                require(shown, "receipt reaches original background request conversation")
                restored.selectForStress(projects[5])
                require(restored.boardForStress.inputForStress.draftText == "board draft 5", "background board draft restored")
                restored.shutdownPlugins()
                print("PASS: restart roundtrip restores all six projects/drafts; only original background conversation gets receipt")
                done()
            }
        }
    }
}

func noticeChecks(_ done: @escaping () -> Void) {
    let view = host.conversationView
    wait("conversation ready", { view.isUpdateUIReady }) {
        view.attachUpdateNotice("专属更新公告", session: root.appendingPathComponent("request.session").path)
        view.noticesForStress(session: root.appendingPathComponent("other.session").path) { leaked in
            require(!leaked, "announcement must not leak to another chat of the same project")
            view.noticesForStress(session: root.appendingPathComponent("request.session").path) { shown in
                require(shown, "request conversation retains its announcement")
                let other = host.viewsForStress.first { $0 !== view }!
                wait("other conversation ready", { other.isUpdateUIReady }) {
                    other.noticesForStress(session: root.appendingPathComponent("request.session").path) { leaked in
                        require(!leaked, "announcement must not leak to another project")
                        print("PASS: update announcement is bound to exactly the request conversation")
                        done()
                    }
                }
            }
        }
    }
}

let app = NSApplication.shared
setbuf(stdout, nil)
app.setActivationPolicy(.accessory)
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_STRESS_ROOT"]!)
let logFile = URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_QUEUE_TEST_LOG"]!)
let projects = (0..<6).map { root.appendingPathComponent("project-\($0)") }
BoardStore.setRoot(root.appendingPathComponent("boards"))
UserDefaults.standard.set(["ssh", "terminal"], forKey: PluginPreferences.disabledKey)
func stressScene(_ index: Int, _ project: URL) -> [String: Any] {
    let element: [String: Any] = ["id": "marker-\(index)", "type": "rectangle", "x": 0, "y": 0, "width": 80, "height": 40,
        "angle": 0, "strokeColor": "#111111", "backgroundColor": "transparent", "fillStyle": "solid", "strokeWidth": 1,
        "strokeStyle": "solid", "roughness": 0, "opacity": 100, "version": 1, "versionNonce": 1,
        "isDeleted": false, "groupIds": [], "seed": 1]
    return ["type": "f-whiteboard", "elements": [element], "appState": [:], "files": [:], "project": project.path]
}
for project in projects {
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
}
historyChecks()
folderHierarchyChecks()
ProjectStore.remember(projects[0])
let host = RootView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = host
for (i, project) in projects.enumerated() {
    host.openForStress(project)
    let destination = host.conversationView.boardDirectory.appendingPathComponent("scene.json")
    try! FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: stressScene(i, project)).write(to: destination, options: .atomic)
    host.conversationView.composerForStress.typeForStress("HOLD-project-\(i)")
    for j in 0..<50 { host.conversationView.composerForStress.typeForStress("project-\(i)-prompt-\(j)") }
}
wait("six live independent agents", {
    host.viewsForStress.count == 6 && host.viewsForStress.allSatisfy { $0.sentForStress } &&
        commands().filter { $0["type"] as? String == "prompt" }.count == 6
}) {
    require(!host.canRestartForUpdate, "updates wait for every background project")
    let prompts = commands().filter { $0["type"] as? String == "prompt" }
    require(Set(prompts.compactMap { $0["pid"] as? Int }).count == 6, "six actual independent RPC processes")
    let active = host.conversationView
    host.boardForStress.inputForStress.draftText = "board draft 5"
    host.selectForStress(projects[0])
    let shownQueue = host.boardForStress.inputForStress.queueForStress
    active.composerForStress.typeForStress("background-extra")
    require(host.boardForStress.inputForStress.queueForStress == shownQueue, "background callbacks cannot mutate foreground board queue")
    host.selectForStress(projects[5])
    require(host.boardForStress.inputForStress.draftText == "board draft 5", "board drafts stay with the project")
    for view in host.viewsForStress { view.finishForStress() }
    wait("301 queued prompts finish", timeout: 50, { host.viewsForStress.allSatisfy { !$0.hasPendingWork } }) {
        let sent = commands().filter { $0["type"] as? String == "prompt" }
        require(sent.count == 307, "all six held prompts and 301 queued prompts execute once")
        for i in 0..<6 {
            let expected = (0..<50).map { "project-\(i)-prompt-\($0)" }
            let actual = sent.compactMap { $0["message"] as? String }.filter { $0.hasPrefix("project-\(i)-prompt-") }
            require(actual == expected, "project \(i) keeps queue ordering")
            let records = sent.filter { ($0["message"] as? String)?.hasPrefix("project-\(i)-prompt-") == true }
            let cwd = projects[i].resolvingSymlinksInPath().path
            let board = host.fileForStress(projects[i]).deletingLastPathComponent().path
            require(records.allSatisfy { URL(fileURLWithPath: $0["project"] as! String).resolvingSymlinksInPath().path == cwd && $0["board"] as? String == board },
                    "prompt environment mismatch: expected \(cwd), \(board); got \(String(describing: records.first))")
        }
        require(host.canRestartForUpdate, "restart only after every project becomes idle")
        print("PASS: six concurrent Agent processes, 301 queued prompts, exactly-once ordered dispatch, isolated board callbacks/drafts")
        wait("board ready", { host.boardForStress.readyForStress }) {
            boardChecks {
                noticeChecks {
                    sameFolderConversationChecks {
                      resumeChecks {
                        host.viewsForStress.forEach { $0.stopForStress() }
                        host.shutdownPlugins()
                        print("PASS: all bounded multi-project, history, board and announcement stress checks")
                        exit(0)
                      }
                    }
                }
            }
        }
    }
}
app.run()
