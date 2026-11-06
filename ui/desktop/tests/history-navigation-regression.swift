func checkHistory(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { fputs("FAIL: \(label)\n", stderr); exit(1) }
}
extension ConversationView {
    var historyReady: Bool { webReady }
    func historyText(_ done: @escaping (String) -> Void) {
        webView.evaluateJavaScript("document.getElementById('messages').textContent") { value, error in
            checkHistory(error == nil, "real history DOM query")
            done(value as? String ?? "")
        }
    }
    func stopHistoryTest() { agent.stop() }
    func testFinalEvents() {
        activeTurnID = 999; requestFailed = false
        for message: [String: Any] in [
            ["role": "assistant", "stopReason": "toolUse", "content": [["type": "text", "text": "内部调度不可见"], ["type": "toolCall", "name": "send_message", "id": "x"]]],
            ["role": "assistant", "stopReason": "stop", "content": "子代理结束前的回复不可见"],
            ["role": "custom", "customType": "agent-message", "content": "代理通信不可见"],
            ["role": "assistant", "stopReason": "stop", "content": "**本轮最终回复**"]
        ] {
            handle(["type": "message_start", "message": message])
            handle(["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "delta": "流式内部文本不可见"]])
            handle(["type": "message_update", "assistantMessageEvent": ["type": "thinking_delta", "delta": "内部思考不可见"]])
            handle(["type": "message_end", "message": message])
        }
    }
    func settleFinalEvents() {
        handle(["type": "agent_settled"])
        handle(["type": "agent_settled"]) // Must not render the final answer twice.
    }
    func nativeSecondaryClicks(_ done: @escaping () -> Void) {
        let selectors = [".bubble", ".content strong", ".content code", ".content a"]
        var index = 0, menus = 0
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
            menus += 1; (notification.object as? NSMenu)?.cancelTracking()
        }
        func next() {
            guard index < selectors.count * 2 else {
                NotificationCenter.default.removeObserver(observer)
                checkHistory(menus == 0, "posted secondary clicks never start AppKit menus")
                done(); return
            }
            let selector = selectors[index / 2], control = index % 2 == 1
            historyJS("""
                (() => {
                  const node=document.querySelector('\(selector)'); node.scrollIntoView({block:'center'});
                  const r=document.createRange(); r.selectNodeContents(node);
                  const s=getSelection(); s.removeAllRanges(); s.addRange(r);
                  window.savedNativeSelection=s.toString();
                  const b=node.getBoundingClientRect(); return {x:b.x+3,y:b.y+b.height/2};
                })()
                """) { value in
                let position = value as! [String: NSNumber]
                let x = position["x"]!.doubleValue, y = position["y"]!.doubleValue
                let point = self.webView.convert(NSPoint(x: x, y: self.webView.isFlipped ? y : self.webView.bounds.height - y), to: nil)
                let down: NSEvent.EventType = control ? .leftMouseDown : .rightMouseDown
                let up: NSEvent.EventType = control ? .leftMouseUp : .rightMouseUp
                for type in [down, up] {
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: control ? .control : [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: self.window!.windowNumber, context: nil, eventNumber: index + 20, clickCount: 1, pressure: type == down ? 1 : 0)!
                    // Use the application's real event queue, where local monitors
                    // run, rather than bypassing it via NSWindow.sendEvent.
                    NSApp.postEvent(event, atStart: false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.historyJS("getSelection().toString() === savedNativeSelection && savedNativeSelection.length > 0") { same in
                        checkHistory(same as? Bool == true, "native secondary click preserves \(selector), Control=\(control)")
                        index += 1; next()
                    }
                }
            }
        }
        historyJS("window.F.setMessages([{role:'user',text:'用户选区中文'},{role:'assistant',text:'**粗体回复** `代码` [链接文字](https://example.invalid)'}])") { _ in next() }
    }
    func historyJS(_ script: String, _ done: @escaping (Any?) -> Void) {
        webView.evaluateJavaScript(script) { value, error in
            checkHistory(error == nil, "real WebKit JS: \(String(describing: error))")
            done(value)
        }
    }
}
extension GlassComposer {
    var inputForHistory: ComposerTextView { textView }
}
extension ConversationView {
    var inputForHistory: ComposerTextView { composer.inputForHistory }
}
extension ChatListDocumentView {
    var projectRowsForHistory: [AppRowView] { items.filter { $0.inset == 6 }.compactMap { $0.view as? AppRowView } }
    var standaloneAddsForHistory: Int { items.filter { ($0.view as? AppRowView)?.onAdd == nil && $0.inset == 25 }.count }
}
extension AppRowView {
    func clickAddForHistory() {
        checkHistory(!addButton.isHidden, "project plus visible")
        let point = convert(NSPoint(x: addButton.frame.midX, y: addButton.frame.midY), to: superview)
        checkHistory(hitTest(point) === addButton, "project plus hit test does not select folder")
        addButton.performClick(nil)
    }
}
let historyWork = URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_HISTORY_ROOT"]!)
let migratedSessions = PiHistory.agentDirectory()!
let migratedFolder = migratedSessions.appendingPathComponent("legacy-project", isDirectory: true)
try! FileManager.default.createDirectory(at: migratedFolder, withIntermediateDirectories: true)
let migratedHistory = migratedFolder.appendingPathComponent("retained.jsonl")
try! Data("retained session bytes".utf8).write(to: migratedHistory)
let legacyHistory = historyWork.appendingPathComponent("removed/runtime/pi/agent/sessions/legacy-project/retained.jsonl").path
checkHistory(PiHistory.canonicalSessionPath(legacyHistory) == migratedHistory.standardizedFileURL.path, "removed runtime path resolves to the original centralized history")
let legacyPending = historyWork.appendingPathComponent("removed/runtime/pi/agent/sessions/legacy-project/pending.jsonl").path
let pendingHistory = migratedFolder.appendingPathComponent("pending.jsonl")
let mappedPending = URL(fileURLWithPath: PiHistory.canonicalSessionPath(legacyPending))
checkHistory(mappedPending.deletingLastPathComponent().standardizedFileURL == migratedFolder.standardizedFileURL && mappedPending.lastPathComponent == "pending.jsonl", "pending sessions resolve before their first history write")
try! Data("pending session bytes".utf8).write(to: mappedPending)
checkHistory((try! String(contentsOf: pendingHistory, encoding: .utf8)) == "pending session bytes" && !FileManager.default.fileExists(atPath: legacyPending), "first history write uses centralized data without recreating the removed runtime")
let migrationDefaults = UserDefaults(suiteName: "local.f.runtime-migration." + UUID().uuidString)!
migrationDefaults.set([legacyHistory: "11111111-2222-3333-4444-555555555555"], forKey: "FConversationBoardIDs")
checkHistory(ConversationBoards.id(for: migratedHistory.path, defaults: migrationDefaults) == "11111111-2222-3333-4444-555555555555", "existing board identity survives runtime relocation")
checkHistory(ConversationBoards.sessionPath(project: historyWork, id: "11111111-2222-3333-4444-555555555555", defaults: migrationDefaults) == migratedHistory.standardizedFileURL.path, "board lookup follows relocated history")
checkHistory((try! String(contentsOf: migratedHistory, encoding: .utf8)) == "retained session bytes", "migration preserves original history bytes")
migrationDefaults.removeObject(forKey: "FConversationBoardIDs")
let runtimeFixture = historyWork.appendingPathComponent("F/runtime", isDirectory: true)
let runtimeCLI = runtimeFixture.appendingPathComponent("agent/bin/f")
let fixtureNode = runtimeFixture.appendingPathComponent("node/bin/node")
try! FileManager.default.createDirectory(at: runtimeCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: fixtureNode.deletingLastPathComponent(), withIntermediateDirectories: true)
try! Data().write(to: runtimeCLI)
try! Data("#!/bin/sh\nprintf F_SHARED_NODE".utf8).write(to: fixtureNode)
try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureNode.path)
let runtimeProbe = Process(), runtimeOutput = Pipe()
runtimeProbe.executableURL = PiPaths.nodeURL(for: runtimeCLI.path)
runtimeProbe.standardOutput = runtimeOutput
try! runtimeProbe.run(); runtimeProbe.waitUntilExit()
checkHistory(runtimeProbe.terminationStatus == 0 && String(data: runtimeOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "F_SHARED_NODE", "native services launch shared Node without the removed nested runtime")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let historyProject = historyWork.appendingPathComponent("项目")
try! FileManager.default.createDirectory(at: historyProject, withIntermediateDirectories: true)
BoardStore.setRoot(historyWork.appendingPathComponent("boards"))
let session = historyWork.appendingPathComponent("branch.jsonl")
let log: [[String: Any]] = [
    ["type": "session", "id": "header", "version": 3, "cwd": historyProject.path],
    ["type": "message", "id": "a", "parentId": NSNull(), "message": ["role": "user", "content": "历史主框标记"]],
    ["type": "message", "id": "b", "parentId": "a", "message": ["role": "assistant", "content": "废弃分支不可见"]],
    ["type": "message", "id": "internal", "parentId": "a", "message": ["role": "assistant", "stopReason": "toolUse", "content": [["type": "text", "text": "工具前言不可见"], ["type": "toolCall", "name": "send_message", "id": "relay"]]]],
    ["type": "message", "id": "relay", "parentId": "internal", "message": ["role": "custom", "customType": "subagent-result", "content": "内部子代理报告不可见"]],
    ["type": "message", "id": "earlier", "parentId": "relay", "message": ["role": "assistant", "stopReason": "stop", "content": "同轮旧回复不可见"]],
    ["type": "message", "id": "c", "parentId": "earlier", "message": ["role": "assistant", "content": [["type": "text", "text": "当前分支回答"], ["type": "thinking", "thinking": "不可见思考"], ["type": "text", "text": "第二段"]]]],
    ["type": "model_change", "id": "d", "parentId": "c"]
]
let bytes = log.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n")
try! bytes.write(to: session, atomically: true, encoding: .utf8)
let messages = PiConversation.load(from: session)
checkHistory(messages.count == 2 && messages.last?.text == "当前分支回答\n第二段", "active parent chain, metadata leaf and text blocks")
checkHistory(PiConversation.activeBranch([["type": "message", "message": ["role": "user", "content": "old"]]]).count == 1, "legacy linear history")
checkHistory(PiConversation.activeBranch([["type": "message", "id": "cycle", "parentId": "cycle"]]).count == 1, "cycle is bounded")
for reason in ["toolUse", "length", "aborted", "error"] {
    checkHistory(PiConversation.finalReply(["role": "assistant", "stopReason": reason, "content": "未完成不可见"]) == nil, "non-final stop reason \(reason) is hidden")
}
checkHistory(PiConversation.finalReply(["role": "assistant", "customType": "agent-message", "content": "relay"]) == nil, "custom relay cannot masquerade as final answer")
checkHistory(PiConversation.finalReply(["role": "assistant", "stopReason": "stop", "content": "send_message 是我要求的文字"]) == "send_message 是我要求的文字", "visible text is not removed by keyword matching")
let linear = historyWork.appendingPathComponent("linear.jsonl")
let turns: [[String: Any]] = [
    ["role": "user", "content": "第一问"],
    ["role": "assistant", "stopReason": "stop", "content": "临时回复"],
    ["role": "custom", "customType": "agent-message", "content": "内部通信"],
    ["role": "assistant", "stopReason": "stop", "content": "第一最终回复"],
    ["role": "user", "content": "第二问"],
    ["role": "assistant", "stopReason": "aborted", "content": "第二未完成"],
    ["role": "user", "content": "第三问"],
    ["role": "assistant", "content": "旧格式最终回复"]
]
let linearBytes = turns.map { String(data: try! JSONSerialization.data(withJSONObject: ["type": "message", "message": $0]), encoding: .utf8)! }.joined(separator: "\n")
try! linearBytes.write(to: linear, atomically: true, encoding: .utf8)
checkHistory(PiConversation.load(from: linear).map(\.text) == ["第一问", "第一最终回复", "第二问", "第三问", "旧格式最终回复"], "each real user turn retains just its final response, including legacy logs")
checkHistory((try! String(contentsOf: linear, encoding: .utf8)) == linearBytes, "filter is presentation-only, no session rewrite")
let link = historyWork.appendingPathComponent("目录快捷方式")
try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: historyProject)
checkHistory(FileBrowserView.navigationTarget(link).path == historyProject.resolvingSymlinksInPath().path, "symlink navigates actual folder")
let alias = historyWork.appendingPathComponent("Finder别名")
let bookmark = try! historyProject.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
try! URL.writeBookmarkData(bookmark, to: alias)
checkHistory(FileBrowserView.navigationTarget(alias).path == historyProject.resolvingSymlinksInPath().path, "Finder alias navigates actual folder")
ProjectStore.remember(historyProject)
let otherProject = historyWork.appendingPathComponent("另一项目")
try! FileManager.default.createDirectory(at: otherProject, withIntermediateDirectories: true)
ProjectStore.remember(otherProject)
let list = ChatListDocumentView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
var opened: [String] = []
list.onNewConversation = { opened.append($0.path) }
list.setChats([])
list.layoutSubtreeIfNeeded()
for row in list.projectRowsForHistory { row.layoutSubtreeIfNeeded(); row.clickAddForHistory() }
checkHistory(Set(opened) == Set([historyProject.standardizedFileURL.path, otherProject.standardizedFileURL.path]), "every project plus binds its own folder")
checkHistory(list.standaloneAddsForHistory == 0, "no standalone new-conversation row")
let view = ConversationView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
view.prepareProject(historyProject, boardID: "aaaaaaaa", session: legacyHistory)
checkHistory(view.ownsSession(migratedHistory.path), "restored conversation owns its relocated history before starting an Agent")
let migratedResume = view.updateResume(id: "runtime-migration", announcement: "")
view.restoreUpdate(migratedResume)
checkHistory(view.ownsSession(migratedHistory.path) && view.sessionPath == migratedHistory.standardizedFileURL.path, "update restore retains canonical session identity")
view.prepareProject(historyProject, boardID: "aaaaaaaa", session: session.path)
view.show(PiChat(id: "history", title: "历史", date: Date(), path: session, cwd: historyProject.path))
let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = view
window.orderFront(nil)
// Exercise the actual native editing responder through Command key equivalents.
let pasteboard = NSPasteboard.general
let clipboard = (pasteboard.pasteboardItems ?? []).map { item in
    item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { saved, type in saved[type] = item.data(forType: type) }
}
let editRoot = NSMenu(), editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""), editMenu = NSMenu()
for (title, action, key) in [("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Cut", "cut:", "x"), ("Undo", "undo:", "z")] {
    editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
}
editItem.submenu = editMenu; editRoot.addItem(editItem); app.mainMenu = editRoot
let input = view.inputForHistory
// Accessory test processes need not become the desktop key application. Route
// the real menu key equivalents to the same native editor explicitly.
for item in editMenu.items {
    if item.keyEquivalent == "z" { item.target = input.undoManager; item.action = #selector(UndoManager.undo) }
    else { item.target = input }
}
checkHistory(input.allowsUndo, "production input enables undo")
window.makeFirstResponder(input)
input.insertText("选择文字", replacementRange: NSRange(location: 0, length: 0))
input.setSelectedRange(NSRange(location: 0, length: 4))
let right = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
checkHistory(input.menu(for: right) == nil, "native input has no text context menu")
input.rightMouseDown(with: right)
checkHistory(input.selectedRange() == NSRange(location: 0, length: 4), "secondary click preserves native selection")
func commandEdit(_ key: String, _ code: UInt16) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
    checkHistory(editRoot.performKeyEquivalent(with: event), "Command-\(key) still routes through native menu")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
commandEdit("c", 8)
checkHistory(pasteboard.string(forType: .string) == "选择文字" && input.string == "选择文字", "Command-C copies selected input")
commandEdit("x", 7)
checkHistory(input.string.isEmpty, "Command-X cuts selected input")
input.breakUndoCoalescing()
commandEdit("v", 9)
checkHistory(input.string == "选择文字", "Command-V pastes native clipboard text")
input.breakUndoCoalescing()
commandEdit("z", 6)
checkHistory(input.string.isEmpty, "Command-Z undoes pasted input")
let draft = GlassComposer(frame: NSRect(x: 0, y: 0, width: 500, height: 80))
let draftInput = draft.inputForHistory
for replacement in ["NEW", "", "NEW_DRAFT_12345"] {
    draft.draftText = "SECRET_A"
    draftInput.setSelectedRange(NSRange(location: 0, length: 8))
    draftInput.insertText("typed", replacementRange: draftInput.selectedRange())
    checkHistory(draftInput.undoManager?.canUndo == true, "native user replacement is undoable")
    draft.draftText = replacement
    checkHistory(draftInput.undoManager?.canUndo == false && draftInput.string == replacement, "programmatic draft replacement discards old undo ranges")
}
checkHistory(input.undoManager !== draftInput.undoManager, "composers do not share a window undo manager")
draftInput.insertText("local", replacementRange: NSRange(location: 0, length: 0))
draftInput.breakUndoCoalescing()
checkHistory(draftInput.undoManager?.canUndo == true, "editing after draft reset is still undoable")
draftInput.undoManager?.undo()
checkHistory(draftInput.string == "NEW_DRAFT_12345", "undo after reset cannot resurrect SECRET_A")
let boundHistory = PromptHistory(project: historyProject)
draft.history = boundHistory
draftInput.insertText("same-project", replacementRange: NSRange(location: 0, length: 0))
draftInput.breakUndoCoalescing()
draft.history = boundHistory
checkHistory(draftInput.undoManager?.canUndo == true, "sharing the same project history does not clear current editing undo")
let preservedDraft = draft.draftText
draft.history = PromptHistory(project: otherProject)
checkHistory(draft.draftText == preservedDraft && draftInput.undoManager?.canUndo == false, "project history rebind preserves draft but not old undo actions")
pasteboard.clearContents()
let restored = clipboard.map { saved -> NSPasteboardItem in
    let item = NSPasteboardItem(); for (type, data) in saved { item.setData(data, forType: type) }; return item
}
pasteboard.writeObjects(restored)
let deadline = Date().addingTimeInterval(30)
var querying = false
var finishedHistory = false
Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    if Date() > deadline { fputs("FAIL: history main WebKit display timeout\n", stderr); exit(1) }
    guard view.historyReady, !querying, !finishedHistory else { return }
    querying = true
    view.historyText { text in
        querying = false
        guard text.contains("历史主框标记"), text.contains("当前分支回答") else { return }
        checkHistory(!text.contains("不可见"), "inactive branch, thinking, tool preambles and child messages absent")
        checkHistory((try! String(contentsOf: session, encoding: .utf8)) == bytes, "history original unchanged")
        finishedHistory = true
        view.testFinalEvents()
        view.historyText { beforeSettle in
            checkHistory(!beforeSettle.contains("不可见") && !beforeSettle.contains("本轮最终回复"), "only settled answer can appear, no transient internal text")
            view.settleFinalEvents()
            view.historyText { settled in
                checkHistory(!settled.contains("不可见") && settled.components(separatedBy: "本轮最终回复").count == 2, "one final answer after actual settle")
                view.historyJS("""
                    const final = document.querySelector('.msg.assistant:last-child .content strong');
                    const finalOnly = final && final.textContent === '本轮最终回复' && !document.querySelector('.thinking');
                    const bubble = document.querySelector('.bubble');
                    const range = document.createRange(); range.selectNodeContents(bubble);
                    const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                    const saved = selection.toString();
                    const menu = new MouseEvent('contextmenu', { bubbles:true, cancelable:true, button:2 });
                    const down = new MouseEvent('mousedown', { bubbles:true, cancelable:true, button:2 });
                    const ctrl = new MouseEvent('mousedown', { bubbles:true, cancelable:true, button:0, ctrlKey:true });
                    const blocked = !bubble.dispatchEvent(menu) && !bubble.dispatchEvent(down) && !bubble.dispatchEvent(ctrl);
                    finalOnly && blocked && selection.toString() === saved && saved === '历史主框标记';
                    """) { result in
                    checkHistory(result as? Bool == true, "WebKit final-only Markdown has no streaming nodes; secondary click/Control-click are inert and preserve selection")
                    view.nativeSecondaryClicks {
                        view.stopHistoryTest()
                        print("PASS: actual WebKit final-only history/live events, native queued secondary clicks including links, input shortcuts and isolated undo, active branches and original session bytes")
                        exit(0)
                    }
                }
            }
        }
    }
}
app.run()
