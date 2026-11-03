// Test the production native UI and scheduler against the isolated fake RPC process.
extension GlassComposer {
    func enterForTest(_ text: String) { textView.string = text; textView.onPlainReturn?() }
    var queueCountForTest: Int { queueView.items.count }
    var rowCountForTest: Int { queueView.testRows.count }
    var queueIsScrollableForTest: Bool { queueView.scrollableForTest }
    func clickQueueForTest(_ index: Int) { queueView.testRows[index].clickSymbolForTest() }
    func editRowForTest(_ index: Int) -> QueuedPromptRow { queueView.testRows[index] }
    func deleteForTest(_ index: Int) { queueView.testRows[index].deleteForTest() }
    var glassTopForTest: CGFloat { glass.frame.maxY }
    var queueBottomForTest: CGFloat { queueView.frame.minY }
}
extension WhiteboardView { var queueComposerForTest: GlassComposer { composer } }
extension ConversationView {
    var queuedForTest: [QueuedPrompt] { queue }
    var pausedForTest: Bool { queuePaused }
    var sentForTest: Bool { turnPromptSent }
    var backendRunningForTest: Bool { agent.isRunning }
    var abortFailedForTest: Bool { stopRequest?.failed == true }
    func failAbortLateForTest() { agent.request(["type": "fail_abort_late"]) }
    var sessionForTest: String? { currentSessionPath }
    var idleForTest: Bool { !busy && !starting && activeTurnID == nil && stopRequest == nil }
    func inputForTest(_ text: String) { composer.enterForTest(text) }
    func clickForTest(_ index: Int) { composer.clickQueueForTest(index) }
    func rowForTest(_ index: Int) -> QueuedPromptRow { composer.editRowForTest(index) }
    func deleteForTest(_ index: Int) { composer.deleteForTest(index) }
    func finishForTest() { agent.request(["type": "finish"]) }
    func disconnectForTest() { agent.stop(); currentSessionPath = nil }
    func cleanupForTest() { agent.stop(); clearQueue(); activeTurnID = nil; activePrompt = nil; busy = false; starting = false; updateSuspended = false; interruption = nil; checkpointCompletion = nil; stopRequest = nil; deferredContinuation = false; completedResponseTurn = nil; restoringUpdateSelection = false }
    func bindBoardForTest(_ board: WhiteboardView) {
        board.connectOptions(to: self)
        board.onPrompt = { [weak self] text in self?.askWhiteboard(text) }
    }
    func setProjectForTest(_ url: URL) { projectDirectory = url }
    func responseCompletedForTest() {
        handle(["type": "message_end", "message": ["role": "assistant", "stopReason": "stop", "content": [["type": "text", "text": "DONE"]]]])
    }
    func timeoutUpdateForTest() {
        let completion = checkpointCompletion
        checkpointCompletion = nil
        completion?(.failure(NSError(domain: "F.Test", code: 1)))
    }
    func lateAbortForTest(acknowledged: Bool = true) {
        if acknowledged { stopRequest?.acknowledged = true }
        handle(["type": "message_end", "message": ["role": "assistant", "stopReason": "aborted"]])
        handle(["type": "agent_settled"])
    }
}
// These extensions access members declared private in the same concatenated source file.
extension PromptQueueView {
    fileprivate var testRows: [QueuedPromptRow] { rows }
    fileprivate var scrollableForTest: Bool { scrollView.documentView!.frame.height > scrollView.frame.height }
}
extension QueuedPromptRow {
    fileprivate func clickSymbolForTest() { symbolLabel.performClick(nil) }
    fileprivate func deleteForTest() { deleteButton.performClick(nil) }
    fileprivate func beginForTest() {
        controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: textLabel))
    }
    fileprivate func commitForTest(_ value: String, cancel: Bool = false) {
        let editor = NSTextView(); editor.string = value
        expect(control(textLabel, textView: editor, doCommandBy: cancel ? #selector(NSResponder.cancelOperation(_:)) : #selector(NSResponder.insertNewline(_:))), "editor must handle Enter/Escape")
    }
    fileprivate var textForTest: String { textLabel.stringValue }
    fileprivate func nativeFocusForTest() { textLabel.selectText(nil) }
    fileprivate var nativeEditorForTest: NSTextView? { textLabel.currentEditor() as? NSTextView }
    fileprivate func layoutCheckForTest() {
        frame.size = NSSize(width: 500, height: 24); layoutSubtreeIfNeeded()
        expect(textLabel.frame.maxX < deleteButton.frame.minX, "delete button must not cover editable text")
        expect(symbolLabel.frame.maxX < textLabel.frame.minX, "priority symbol must not cover text")
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func eventually(_ name: String, timeout: TimeInterval = 5, _ predicate: @escaping () -> Bool, _ done: @escaping () -> Void) {
    let end = Date().addingTimeInterval(timeout)
    var timer: Timer?
    timer = Timer.scheduledTimer(withTimeInterval: 0.015, repeats: true) { _ in
        if predicate() { timer?.invalidate(); done(); return }
        if Date() > end { fputs("FAIL: timeout waiting for \(name)\n", stderr); exit(1) }
    }
}
func commands() -> [[String: Any]] {
    guard let data = try? Data(contentsOf: logFile), let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}
func prompts() -> [String] { commands().filter { $0["type"] as? String == "prompt" }.map { $0["message"] as! String } }
func expectSuffix(_ values: [String]) { expect(Array(prompts().suffix(values.count)) == values, "wrong execution order: \(prompts())") }
func held(_ name: String, _ done: @escaping () -> Void) {
    view.inputForTest(name)
    eventually(name, { prompts().last == name && view.sentForTest }, done)
}
func finishScenario(_ name: String, _ next: @escaping () -> Void) {
    eventually(name, { view.idleForTest }, { print("PASS: \(name)"); next() })
}
func uiChecks() {
    let composer = GlassComposer(frame: NSRect(x: 0, y: 0, width: 640, height: 200))
    let base = composer.height(forWidth: 640)
    composer.setQueue([QueuedPrompt(id: 1, text: "第一条"), QueuedPrompt(id: 2, text: "第二条")])
    expect(composer.height(forWidth: 640) > base, "queue should increase composer height")
    composer.needsLayout = true; composer.layoutSubtreeIfNeeded()
    expect(composer.glassTopForTest <= composer.queueBottomForTest, "queue must sit above the input glass")
    var tapped = -1
    composer.onQueueTap = { tapped = $0 }
    composer.clickQueueForTest(1)
    expect(tapped == 2, "leading symbol must execute its own row")
    composer.setQueue((0..<7).map { QueuedPrompt(id: $0, text: "第\($0)条") }, paused: true)
    composer.frame.size.height = composer.height(forWidth: 640)
    composer.needsLayout = true; composer.layoutSubtreeIfNeeded()
    expect(composer.rowCountForTest == 7 && composer.queueIsScrollableForTest, "all queued rows must remain reachable")
    let frame = composer.layoutFrame(in: NSRect(x: 0, y: 0, width: 520, height: 340))
    expect(frame.maxY <= 256, "queue should not overlap top window controls")
    let retained = composer.editRowForTest(2)
    retained.beginForTest()
    composer.setQueue((0..<8).map { QueuedPrompt(id: $0, text: "第\($0)条") }, paused: true)
    expect(composer.editRowForTest(2) === retained && retained.isEditing, "new prompt must preserve editor identity")
    retained.commitForTest("取消草稿", cancel: true)
    expect(retained.textForTest == "第2条", "Escape should restore the original text")
    retained.layoutCheckForTest()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = composer
    var nativeEdit: (Int, String)?
    composer.onQueueEdit = { nativeEdit = ($0, $1) }
    window.makeKeyAndOrderFront(nil)
    retained.nativeFocusForTest()
    expect(retained.nativeEditorForTest != nil && retained.isEditing, "click/focus must open a real native field editor and hold the queue (editor=\(retained.nativeEditorForTest != nil), editing=\(retained.isEditing))")
    window.makeFirstResponder(nil)
    expect(!retained.isEditing, "focusing then leaving unchanged must release the queue")
    retained.nativeFocusForTest()
    retained.nativeEditorForTest!.string = "原生编辑测试"
    window.makeFirstResponder(nil)
    expect(nativeEdit?.0 == 2 && nativeEdit?.1 == "原生编辑测试" && !retained.isEditing, "focus loss must save the actual native field editor")
    retained.nativeFocusForTest()
    retained.nativeEditorForTest!.string = "    "
    _ = retained.control(NSControl(), textView: retained.nativeEditorForTest!, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    expect(retained.textForTest == "原生编辑测试", "blank Enter must also restore the actual field editor")
    window.orderOut(nil)
    window.contentView = nil
    composer.setQueue([])
    expect(composer.height(forWidth: 640) == base, "clearing queue must restore input size")
    for flags: NSEvent.ModifierFlags in [.control, [.control, .capsLock], .command, [], [.control, .shift]] {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{3}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        expect(AgentInterruptShortcut.matches(event) == (flags == .control || flags == [.control, .capsLock]), "Ctrl+C shortcut matching")
    }
    print("PASS: native queue stacking, gray-symbol action, scroll access, height and Ctrl+C matching")
}
func fifo() {
    held("HOLD_FIFO") {
        view.inputForTest("FIFO_B"); view.inputForTest("FIFO_C")
        expect(view.queuedForTest.map(\.text) == ["FIFO_B", "FIFO_C"], "busy Enter must enqueue")
        expect(board.queueComposerForTest.queueCountForTest == 2, "board and project must show the same queue")
        expect(prompts().last == "HOLD_FIFO", "queue must not execute before the active task settles")
        view.finishForTest()
        finishScenario("FIFO sends exactly one prompt per completed turn") {
            expectSuffix(["HOLD_FIFO", "FIFO_B", "FIFO_C"])
            editingAndDeletion(next: { priority("ACK_FIRST_HOLD", next: { priority("SETTLE_FIRST_HOLD", next: multiplePriority) }) })
        }
    }
}
func editingAndDeletion(next: @escaping () -> Void) {
    held("HOLD_EDIT") {
        view.inputForTest("DUPLICATE"); view.inputForTest("DUPLICATE")
        board.queueComposerForTest.enterForTest("BOARD_ORIGINAL")
        view.inputForTest("EDIT_LAST")
        let original = view.queuedForTest
        let editor = board.queueComposerForTest.editRowForTest(2)
        editor.beginForTest()
        view.inputForTest("EDIT_ARRIVAL")
        expect(board.queueComposerForTest.editRowForTest(2) === editor, "shared queue update must retain the active editor")
        view.deleteForTest(0)
        expect(view.queuedForTest.map(\.id) == Array(original.dropFirst()).map(\.id) + [view.queuedForTest.last!.id], "delete must preserve all other IDs and their order")
        view.finishForTest()
        eventually("agent finishes during inline editing", { view.idleForTest }) {
            expect(prompts().last == "HOLD_EDIT", "do not send a half-edited queued prompt")
            editor.commitForTest("修改过的画板指令 中文\n第二行")
            expect(view.queuedForTest[1].id == original[2].id && view.queuedForTest[1].isWhiteboard, "edit must preserve ID, order and board context")
            expect(view.rowForTest(1).textForTest == "修改过的画板指令 中文\n第二行", "board edit must synchronize to project composer")
            let cancelled = view.rowForTest(0)
            cancelled.beginForTest(); cancelled.commitForTest("不要保存", cancel: true)
            expect(view.queuedForTest[0].text == "DUPLICATE", "Escape must not change the scheduled prompt")
            cancelled.beginForTest(); cancelled.commitForTest("   ")
            expect(view.queuedForTest[0].text == "DUPLICATE", "blank edit must retain a valid prompt")
            view.deleteForTest(2)
            finishScenario("inline edit, cancel, duplicate-specific delete and shared queue order") {
                let sent = Array(prompts().suffix(4))
                expect(sent[0] == "HOLD_EDIT" && sent[1] == "DUPLICATE" && sent[2].contains("修改过的画板指令 中文\n第二行") && sent[3] == "EDIT_ARRIVAL", "edited/deleted queue ran in the wrong order: \(sent)")
                next()
            }
        }
    }
}
func priority(_ heldName: String, next: @escaping () -> Void) {
    held(heldName) {
        view.inputForTest("NORMAL_" + heldName.prefix(3)); view.inputForTest("PRIORITY_" + heldName.prefix(3))
        let expected = view.queuedForTest.map(\.text)
        view.clickForTest(1)
        finishScenario("priority insertion with \(heldName) abort ordering") {
            expectSuffix([heldName, expected[1], expected[0]])
            next()
        }
    }
}
func multiplePriority() {
    held("ACK_FIRST_HOLD_MULTIPLE") {
        view.inputForTest("MULTI_B"); view.inputForTest("MULTI_C"); view.inputForTest("MULTI_D")
        view.clickForTest(1); view.clickForTest(1)
        finishScenario("rapid priority clicks preserve all other prompts and never double-send") {
            expectSuffix(["ACK_FIRST_HOLD_MULTIPLE", "MULTI_D", "MULTI_C", "MULTI_B"])
            controlC()
        }
    }
}
func controlC() {
    held("SETTLE_FIRST_HOLD_CTRL_C") {
        view.inputForTest("PAUSED_B"); view.inputForTest("PAUSED_C")
        let count = commands().filter { $0["type"] as? String == "abort" }.count
        expect(view.interruptCurrent(), "Ctrl+C must interrupt current work")
        finishScenario("Ctrl+C stops the turn and pauses the preserved queue") {
            expect(view.pausedForTest && view.queuedForTest.count == 2, "Ctrl+C must keep unsent prompts")
            expect(commands().filter { $0["type"] as? String == "abort" }.count == count + 1, "first Ctrl+C must send one abort")
            let editor = view.rowForTest(0)
            editor.beginForTest(); editor.commitForTest("PAUSED_EDITED")
            board.queueComposerForTest.deleteForTest(1)
            expect(view.pausedForTest && view.queuedForTest.map(\.text) == ["PAUSED_EDITED"], "edit/delete must preserve pause state")
            view.inputForTest("")
            finishScenario("empty Enter resumes the paused queue") {
                expectSuffix(["SETTLE_FIRST_HOLD_CTRL_C", "PAUSED_EDITED"])
                terminatePaused(inFlight: false)
            }
        }
    }
}
func terminatePaused(inFlight: Bool) {
    let name = inFlight ? "ACK_FIRST_HOLD_TERMINATE_INFLIGHT" : "HOLD_TERMINATE_PAUSED"
    held(name) {
        let session = view.sessionForTest
        view.inputForTest("MUST_NOT_RUN_B"); view.inputForTest("MUST_NOT_RUN_C")
        expect(view.interruptCurrent(), "first Ctrl+C should pause")
        let terminate = {
            expect(view.interruptCurrent(), "second Ctrl+C must terminate even after agent settles")
            expect(view.idleForTest && !view.pausedForTest && view.queuedForTest.isEmpty, "termination must stop and clear pending work")
            expect(board.queueComposerForTest.queueCountForTest == 0, "termination must clear the board queue too")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                expect(prompts().last == name, "terminated queued work must not run from a stale callback")
                expect(!view.interruptCurrent(), "after termination idle Ctrl+C belongs to terminal")
                view.inputForTest("AFTER_TERMINATE")
                finishScenario("second Ctrl+C terminates \(inFlight ? "during abort" : "after pause") and allows a fresh prompt") {
                    expect(view.sessionForTest == session, "termination must preserve the conversation for future prompts")
                    if inFlight { boardQueue() } else { terminatePaused(inFlight: true) }
                }
            }
        }
        if inFlight { terminate() }
        else { eventually("settled paused task", { view.idleForTest && view.pausedForTest }, terminate) }
    }
}
func boardQueue() {
    held("HOLD_BOARD") {
        board.queueComposerForTest.enterForTest("BOARD_B")
        expect(view.queuedForTest.first?.isWhiteboard == true, "board prompt must retain its tool context")
        view.finishForTest()
        finishScenario("board Enter queues and retains its project-bound whiteboard instructions") {
            expect(prompts().last!.contains("[[F_WHITEBOARD]]") && prompts().last!.contains("BOARD_B"), "board wrapper was lost")
            startupCancellation()
        }
    }
}
func startupCancellation() {
    view.disconnectForTest()
    let before = prompts().count
    view.inputForTest("HOLD_STARTUP_CANCEL"); view.inputForTest("STARTUP_B")
    expect(view.interruptCurrent(), "Ctrl+C must also cancel startup")
    finishScenario("startup cancellation invalidates pending sends") {
        expect(prompts().count == before, "cancelled startup prompt must never be sent")
        expect(view.queuedForTest.map(\.text) == ["STARTUP_B"], "startup cancellation lost the queue")
        view.inputForTest("")
        finishScenario("startup queue remains usable") { expectSuffix(["STARTUP_B"]); startupPriority() }
    }
}
func startupPriority() {
    view.disconnectForTest()
    let before = prompts().count
    view.inputForTest("HOLD_STARTUP_PREEMPT")
    view.inputForTest("PRIORITY_STARTUP")
    view.clickForTest(0)
    finishScenario("priority click also cancels unsent startup work") {
        expect(Array(prompts().dropFirst(before)) == ["PRIORITY_STARTUP"], "startup priority sent the old prompt or duplicated the new one")
        wedge()
    }
}
func wedge() {
    held("WEDGE_HOLD") {
        let pid = commands().last!["pid"] as! Int
        let session = view.sessionForTest
        view.inputForTest("AFTER_WEDGE")
        expect(view.interruptCurrent(), "wedged backend interrupt")
        finishScenario("unresponsive abort falls back to stopping the backend") {
            expect(view.pausedForTest && view.queuedForTest.first?.text == "AFTER_WEDGE", "fallback lost pending input")
            view.inputForTest("")
            finishScenario("queue reconnects after forced stop") {
                expect(commands().last!["pid"] as! Int != pid, "backend was not restarted")
                expect(view.sessionForTest == session, "forced stop must restore the same conversation")
                failures()
            }
        }
    }
}
func failures() {
    failureCase(["ERROR_FAIL", "ERROR_OFFLINE", "ERROR_QUOTA", "ERROR_CONTEXT", "ERROR_EXPIRED_TOKEN", "ERROR_RATE_LIMIT", "ERROR_OUTPUT_LIMIT"], index: 0)
}
func failureCase(_ cases: [String], index: Int) {
    if index == cases.count { checkpointRestart(); return }
    let failure = cases[index], next = "AFTER_\(failure)"
    view.inputForTest(failure); view.inputForTest(next)
    finishScenario("model errors pause the queue without dropping later prompts") {
        expect(view.pausedForTest && view.queuedForTest.first?.text == next, "error should pause, not consume, later prompts")
        expect(prompts().filter { $0 == failure }.count == 1, "failed request must not be retried automatically")
        view.inputForTest("")
        finishScenario("queue can resume after \(failure)") {
            expectSuffix([failure, next])
            expect(!view.interruptCurrent(), "idle Ctrl+C should remain available to the terminal")
            failureCase(cases, index: index + 1)
        }
    }
}

func checkpointRestart() {
    held("ACK_FIRST_HOLD_UPDATE") {
        view.inputForTest("UPDATE_QUEUE_B")
        view.askWhiteboard("UPDATE_BOARD_C")
        view.interruptForUpdate(id: "abc-123") { result in
            if case .failure(let error) = result { fatalError("checkpoint: \(error)") }
            expect(view.canRestartForUpdate && view.hasPendingWork, "saved queues must not block restart")
            let state = view.updateResume(id: "abc-123", announcement: "更新完成")
            expect(state.interruption?.prompt?.text == "ACK_FIRST_HOLD_UPDATE", "in-flight prompt missing")
            expect(state.interruption?.queue.map(\.text) == ["UPDATE_QUEUE_B", "UPDATE_BOARD_C"], "saved queue order")
            let archive = view.conversationDirectory.appendingPathComponent("interruptions/abc-123.json")
            let disk = try! JSONDecoder().decode(UpdateResume.self, from: Data(contentsOf: archive))
            expect(disk.session == state.session && disk.interruption?.promptWasSent == true, "durable checkpoint must include session")
            let restored = ConversationView(frame: .zero)
            restored.prepareProject(project)
            var customSelection = state
            customSelection.provider = "saved-provider"; customSelection.model = "saved-model"; customSelection.thinking = "off"
            restored.restoreUpdate(customSelection)
            expect(restored.hasPendingWork && restored.canRestartForUpdate, "restored queue waits for boot readiness")
            view.cleanupForTest()
            restored.continueAfterUpdate()
            restored.continueAfterUpdate() // Idempotent within the same boot.
            eventually("restored continuation sent", { prompts().last?.contains("从未完成的步骤继续") == true && restored.sentForTest }) {
                restored.finishForTest()
            }
            eventually("checkpoint reconnect and continuation", { restored.idleForTest }) {
                let sent = Array(prompts().suffix(3))
                expect(sent[0].contains("从未完成的步骤继续") && sent[0].contains("ACK_FIRST_HOLD_UPDATE"), "resume prompt must use saved context")
                expect(sent[1] == "UPDATE_QUEUE_B" && sent[2].contains("UPDATE_BOARD_C"), "queue and whiteboard context must survive restart")
                expect(restored.sessionForTest == state.session, "continuation must restore original session")
                let applied = commands().last { $0["type"] as? String == "set_model" }
                expect(applied?["modelId"] as? String == "saved-model", "backend startup defaults must not overwrite the saved model")
                expect(commands().last { $0["type"] as? String == "set_thinking_level" }?["level"] as? String == "off", "saved thinking level must survive startup and switch_session")
                restored.cleanupForTest()
                checkpointPaused()
            }
        }
    }
}
func checkpointPaused() {
    held("SETTLE_FIRST_HOLD_UPDATE_PAUSED") {
        view.inputForTest("UPDATE_PAUSED_QUEUE")
        expect(view.interruptCurrent(), "manual pause")
        eventually("paused before update", { view.idleForTest }) {
            view.interruptForUpdate(id: "abc-124") { result in
                if case .failure(let error) = result { fatalError("checkpoint: \(error)") }
                let state = view.updateResume(id: "abc-124", announcement: "")
                expect(state.interruption?.prompt == nil && state.interruption?.queuePaused == true, "user-stopped task must not auto resume")
                view.continueAfterUpdate()
                expect(view.pausedForTest && view.queuedForTest.map(\.text) == ["UPDATE_PAUSED_QUEUE"], "manual pause must survive update")
                view.inputForTest("")
                eventually("paused continuation completed", { view.idleForTest }) {
                    view.cleanupForTest()
                    checkpointCompletedRace()

                }
            }
        }
    }
}

func checkpointStartup() {
    let before = prompts().count
    view.inputForTest("HOLD_UPDATE_STARTUP")
    view.inputForTest("UPDATE_STARTUP_NEXT")
    view.interruptForUpdate(id: "abc-125") { result in
        if case .failure(let error) = result { fatalError("checkpoint: \(error)") }
        let state = view.updateResume(id: "abc-125", announcement: "")
        expect(state.interruption?.promptWasSent == false && prompts().count == before, "startup checkpoint must not send an invalidated prompt")
        view.continueAfterUpdate()
        eventually("unsent startup restored", { prompts().last == "HOLD_UPDATE_STARTUP" && view.sentForTest }) {
            view.finishForTest()
            eventually("startup restored queue finished", { view.idleForTest }) {
                expectSuffix(["HOLD_UPDATE_STARTUP", "UPDATE_STARTUP_NEXT"])
                view.cleanupForTest()
                checkpointDiskFailure()
            }
        }
    }
}
func checkpointDiskFailure() {
    let blocked = ConversationView(frame: .zero)
    blocked.prepareProject(project, boardID: "abc-126")
    try! FileManager.default.createDirectory(at: blocked.conversationDirectory, withIntermediateDirectories: true)
    try! Data("not a directory".utf8).write(to: blocked.conversationDirectory.appendingPathComponent("interruptions"))
    blocked.inputForTest("HOLD_UPDATE_STORAGE_FAIL")
    eventually("storage failure task active", { blocked.sentForTest && prompts().last == "HOLD_UPDATE_STORAGE_FAIL" }) {
        let before = commands().filter { $0["type"] as? String == "abort" }.count
        blocked.interruptForUpdate(id: "abc-126") { result in
            if case .success = result { fatalError("unwritable interruption history was accepted") }
            expect(!blocked.canRestartForUpdate && blocked.isProcessing, "write failure must not stop the running conversation")
            expect(commands().filter { $0["type"] as? String == "abort" }.count == before, "do not abort before the history is durable")
            blocked.cleanupForTest()
            checkpointNoForceKill()

        }
    }
}

func checkpointNoForceKill() {
    held("WEDGE_HOLD_UPDATE") {
        view.interruptForUpdate(id: "abc-127") { _ in
            fatalError("unacknowledged backend must not be accepted as safely stopped")
        }
        expect(view.interruptCurrent() && view.interruptCurrent(), "update checkpoint must own cancellation while tools are stopping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
            expect(view.backendRunningForTest && !view.canRestartForUpdate, "update must not use Ctrl+C's force-kill fallback")
            view.cleanupForTest() // Dispose only this isolated test backend.
            print("PASS: durable checkpoint, original session continuation, queue, board context, manual pause, startup, disk failure and no forced update kill")
            print("PASS: all native queue and interruption scenarios")
            exit(0)
        }
    }
}

func checkpointCompletedRace() {
    held("ACK_FIRST_HOLD_UPDATE_COMPLETED") {
        let before = prompts().count
        view.inputForTest("UPDATE_COMPLETED_NEXT")
        view.responseCompletedForTest() // Final stop arrived, but agent_settled is still pending.
        view.interruptForUpdate(id: "abc-128") { result in
            if case .failure(let error) = result { fatalError("checkpoint: \(error)") }
            expect(view.updateResume(id: "abc-128", announcement: "").interruption?.promptCompleted == true, "completed response marker must precede checkpoint")
            view.continueAfterUpdate()
            eventually("completed response is not repeated", { view.idleForTest }) {
                expect(Array(prompts().dropFirst(before)) == ["UPDATE_COMPLETED_NEXT"], "completed task must not be replayed")
                print("PASS: final response before checkpoint is not replayed after settle")
                view.cleanupForTest()
                checkpointLateAbort()
            }
        }
    }
}
func checkpointLateAbort(failure: Bool = false) {
    held(failure ? "WEDGE_HOLD_UPDATE_LATE_FAILURE" : "WEDGE_HOLD_UPDATE_LATE") {
        let before = prompts().count
        view.inputForTest("UPDATE_LATE_NEXT")
        view.interruptForUpdate(id: "abc-129") { result in
            if case .success = result { fatalError("mock abort must time out") }
            view.continueAfterUpdate()
        }
        view.timeoutUpdateForTest() // Exercise timeout transition without waiting thirty seconds.
        expect(view.isProcessing && view.hasPendingWork && prompts().count == before, "timeout must retain, not immediately duplicate, the in-flight task")
        let settle = {
            view.lateAbortForTest(acknowledged: !failure)
            eventually("late abort continuation sent", { prompts().count > before && prompts().last?.contains("从未完成的步骤继续") == true && view.sentForTest }) {
                view.finishForTest()
                eventually("late abort queue completed", { view.idleForTest }) {
                    let sent = Array(prompts().dropFirst(before))
                    expect(sent.count == 2 && sent[0].contains("WEDGE_HOLD_UPDATE_LATE") && sent[1] == "UPDATE_LATE_NEXT", "late settle must preserve exactly one continuation and its queue")
                    print("PASS: timed-out update preserves continuation through late abort \(failure ? "failure" : "success") until settle")
                    view.cleanupForTest()
                    if !failure { checkpointLateAbort(failure: true) }
                    else { checkpointSelectionFailure(thinking: false) }
                }
            }
        }
        if failure {
            view.failAbortLateForTest()
            eventually("late abort rejection received", { view.abortFailedForTest }) {
                expect(view.backendRunningForTest && view.isProcessing && !view.canRestartForUpdate, "late abort failure must not force-kill an unsettled backend")
                settle()
            }
        } else { settle() }
    }
}
func checkpointSelectionFailure(thinking: Bool) {
    let blocked = ConversationView(frame: .zero)
    blocked.prepareProject(project)
    let prompt = QueuedPrompt(id: 501, text: "UPDATE_SELECTION_MUST_WAIT")
    var state = UpdateResume(id: "abc-130", project: project.path, provider: "test",
        model: thinking ? "test-model" : "reject-model", thinking: thinking ? "reject-thinking" : "off", announcement: "")
    state.interruption = ConversationInterruption(updateID: state.id, prompt: prompt, promptWasSent: false, queue: [], queuePaused: false)
    blocked.restoreUpdate(state)
    let before = prompts().count
    blocked.continueAfterUpdate()
    eventually("selection rejection pauses restored prompt", { blocked.idleForTest && blocked.pausedForTest }) {
        expect(prompts().count == before && blocked.queuedForTest.first?.text == prompt.text, "failed model/thinking selection must retain the task and never dispatch to a wrong configuration")
        print("PASS: rejected \(thinking ? "thinking level" : "model") retains the restored prompt without dispatch")
        blocked.cleanupForTest()
        if !thinking { checkpointSelectionFailure(thinking: true) }
        else { checkpointStartup() }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
setbuf(stdout, nil)
signal(SIGPIPE, SIG_IGN)
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_QUEUE_TEST_ROOT"]!)
let logFile = URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_QUEUE_TEST_LOG"]!)
let project = root.appendingPathComponent("project")
BoardStore.setRoot(root.appendingPathComponent("boards"))
uiChecks()
let view = ConversationView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
view.setProjectForTest(project)
let board = WhiteboardView(project: project)
view.bindBoardForTest(board)
fifo()
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { fputs("FAIL: queue suite timed out\n", stderr); exit(1) }
app.run()
