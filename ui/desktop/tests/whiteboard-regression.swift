// Appended to main.swift by run-whiteboard-tests.py so private bridge code is tested.
extension WhiteboardView {
    static func checkJSONRegression() {
        let values: [Any] = [
            "light", "dark", "", "中文 \"引号\" \\ 换行\n😀\u{2028}\u{2029}",
            true, false, 42, NSNull(), [], [:],
            ["text": "处理中", "busy": true],
            ["scene": ["elements": []], "options": ["fit": true]],
        ]
        for value in values {
            let json = jsonString(value)
            let decoded = try! JSONSerialization.jsonObject(
                with: Data(json.utf8), options: [.fragmentsAllowed]
            )
            precondition((decoded as AnyObject).isEqual(value), "JSON value changed: \(json)")
        }
        for value: Any in [Date(), Double.nan, Double.infinity, ["bad": Date()]] {
            precondition(jsonString(value) == "null", "Invalid JSON should be rejected")
        }
        print("PASS: scalar, nested, Unicode and invalid JSON values")
    }

    func evaluateForTest(_ code: String, completion: @escaping (Any?) -> Void) {
        webView.evaluateJavaScript(code) { value, error in
            if let error { fputs("JavaScript failed: \(error)\n", stderr); exit(1) }
            completion(value)
        }
    }

    var readyForTest: Bool { webReady }
    var loadDiagnosticsForTest: String { "ready=\(webReady) loading=\(webView.isLoading) url=\(webView.url?.absoluteString ?? "nil") document=\(sceneURL?.path ?? "nil") pending=\(pendingScene != nil)" }
    var inputHiddenForTest: Bool { composer?.isHidden ?? true }
    var composerForTest: GlassComposer { composer! }

    func writeExternalSceneForTest(_ elements: [[String: Any]], reload: Bool) {
        var scene = try! JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL!)) as! [String: Any]
        scene["elements"] = elements
        scene["revision"] = (scene["revision"] as? Int ?? 0) + 1
        try! JSONSerialization.data(withJSONObject: scene).write(to: sceneURL!, options: .atomic)
        if reload { reloadScene(fit: false) }
        else { pollSceneFile() }
    }

    func checkNativeInput() {
        var sent: [String] = []
        onPrompt = { sent.append($0) }
        composer?.onSend = { [weak self] text in self?.onPrompt?(text) }
        composer?.canSend = false
        composer?.submitForTest("测试画板指令")
        precondition(sent.isEmpty, "Busy input sent a prompt")
        composer?.canSend = true
        composer?.submitForTest("测试画板指令")
        precondition(sent == ["测试画板指令"], "Native input did not forward the prompt")
        precondition(composer?.showsOptions == true, "Board input must show model and thinking choices")
        onPrompt = nil
    }
}

func concurrentSceneChecks(completion: @escaping () -> Void) {
    var original = rectangleFixture
    original["id"] = "remove-locally"
    var agentAddition = rectangleFixture
    agentAddition["id"] = "keep-agent-addition"
    agentAddition["x"] = 360
    board.writeExternalSceneForTest([original], reload: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        board.evaluateForTest("window.FWB.menuAction('clear'); true") { _ in
            assertEventually("Boolean(document.querySelector('.confirm-dialog-buttons button:last-child'))", "clear confirmation is ready for concurrent edit") {
                board.evaluateForTest("document.querySelector('.confirm-dialog-buttons button:last-child').click(); window.FWB.getScene().length") { count in
                    precondition(count as? Int == 0, "Clear must change the live canvas synchronously")
                    let disk = try! JSONSerialization.jsonObject(with: Data(contentsOf: board.documentForTest)) as! [String: Any]
                    precondition((disk["elements"] as! [[String: Any]]).contains { $0["id"] as? String == "remove-locally" }, "Regression must poll before the local debounce reaches disk")
                    // The Agent writes while the native pendingWrites queue is empty,
                    // but Excalidraw still has a local deletion waiting for its timer.
                    board.writeExternalSceneForTest([original, agentAddition], reload: false)
                    assertEventually("window.FWB.getScene().length === 1 && window.FWB.getScene()[0].id === 'keep-agent-addition'", "poll merges an unsent local deletion with an Agent addition") {
                        let merged = try! JSONSerialization.jsonObject(with: Data(contentsOf: board.documentForTest)) as! [String: Any]
                        precondition((merged["elements"] as! [[String: Any]]).map { $0["id"] as! String } == ["keep-agent-addition"])
                        precondition(!board.hasPendingWrites)
                        print("PASS: Agent polling preserves local edits pending the WebKit debounce and merges both writers")
                        board.writeExternalSceneForTest([], reload: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: completion)
                    }
                }
            }
        }
    }
}

extension GlassComposer {
    func submitForTest(_ value: String) { textView.string = value; submit() }
}

extension ConversationView {
    func checkSharedOptions(with board: WhiteboardView) {
        board.connectOptions(to: self)
        precondition(board.composerForTest.modelName == "test-default")
        precondition(board.composerForTest.thinkingLevel == "medium")
        models = [AgentModel(provider: "test", id: "model-1", name: "Test Model", reasoning: true)]
        let modelItem = NSMenuItem()
        modelItem.representedObject = ["test", "model-1"]
        pickModel(modelItem)
        let thinkingItem = NSMenuItem()
        thinkingItem.representedObject = "high"
        pickThinking(thinkingItem)
        precondition(composer.modelName == "Test Model" && board.composerForTest.modelName == "Test Model")
        precondition(composer.thinkingLevel == "high" && board.composerForTest.thinkingLevel == "high")
        precondition(board.composerForTest.onModelClick != nil && board.composerForTest.onThinkingClick != nil)
        for width: CGFloat in [900, 520, 220] {
            let bounds = NSRect(x: 0, y: 0, width: width, height: 600)
            let frame = composer.layoutFrame(in: bounds)
            precondition(frame == board.composerForTest.layoutFrame(in: bounds))
            precondition(frame.width <= 640 && frame.maxX <= width && frame.minY == 20)
        }
        print("PASS: shared model/thinking selections and identical shorter composer layout")
    }
}

func assertEventually(_ assertion: String, _ name: String, attempts: Int = 30, completion: @escaping () -> Void) {
    board.evaluateForTest(assertion) { value in
        if value as? Bool == true { completion(); return }
        if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                assertEventually(assertion, name, attempts: attempts - 1, completion: completion)
            }
            return
        }
        fputs("FAIL: \(name)\n", stderr)
        board.evaluateForTest("JSON.stringify({width:innerWidth, root:document.documentElement.className, modal:!!document.querySelector('.Modal'), menu:!!document.querySelector('[data-testid=image-export-button]'), visibility:getComputedStyle(document.querySelector('.fwb-toolbar-slot')).visibility,exportInfo:document.querySelector('.fwb-export-info')?.textContent,exportButton:document.querySelector('.fwb-export-foot button')?.textContent,exportDisabled:document.querySelector('.fwb-export-foot button')?.disabled})") { debug in
            print(debug ?? "No debug state")
            exit(1)
        }
    }
}

func interfaceChecks(_ index: Int = 0) {
    let checks: [(CGFloat, String, String, String)] = [
        (900, "", "document.querySelectorAll('.fwb-toolbar > button[data-tool]').length === 12 && !document.querySelector('.fwb-empty, .fwb-context, .fwb-composer, .fwb-project')", "wide toolbar and blank page"),
        (520, "", "getComputedStyle(document.querySelector('.fwb-footer')).display !== 'none' && document.querySelectorAll('.fwb-toolbar > button[data-tool]').length < 12 && document.querySelector('.fwb-toolbar').getBoundingClientRect().left >= 96 && document.querySelector('.fwb-topbar').getBoundingClientRect().right <= innerWidth - 176", "narrow toolbar avoids native buttons"),
        (520, "document.querySelector('[aria-label=更多工具]').click()", "Array.from(document.querySelectorAll('.fwb-toolbar > button[data-tool], .fwb-overflow button[data-tool]')).map(n => n.dataset.tool).slice(0,12).join(',') === 'hand,selection,rectangle,diamond,ellipse,arrow,line,freedraw,text,image,eraser,library'", "overflow preserves every tool in order"),
        (520, "document.querySelector('.fwb-overflow [data-tool=library]').click()", "document.querySelector('.default-sidebar') !== null && getComputedStyle(document.querySelector('.default-sidebar')).display !== 'none'", "library opens from overflow"),
        (900, "", "Boolean(document.querySelector('.fwb-toolbar [data-tool=rectangle]'))", "drawing tools return after widening the window"),
        (900, "document.querySelector('[data-tool=rectangle]').click()", "document.querySelector('[data-tool=rectangle]').getAttribute('aria-pressed') === 'true'", "drawing tool selection"),
        (220, "", "document.querySelector('.fwb-topbar').getBoundingClientRect().left >= 0 && document.querySelector('.fwb-topbar').getBoundingClientRect().right <= innerWidth && Math.abs(document.querySelector('.fwb-topbar').getBoundingClientRect().left + document.querySelector('.fwb-topbar').getBoundingClientRect().width / 2 - innerWidth / 2) < 1 && document.querySelector('.fwb-footer').getBoundingClientRect().width === 160", "narrow top bar stays centered with fixed-size controls"),
        (900, "", "document.querySelector('.fwb-footer').getBoundingClientRect().width === 160 && Math.abs(document.querySelector('.fwb-topbar').getBoundingClientRect().left + document.querySelector('.fwb-topbar').getBoundingClientRect().width / 2 + 40 - innerWidth / 2) < 1", "wide centering includes the two native sidebar buttons"),
        (520, "document.querySelector('.fwb-footer [aria-label=放大]').click()", "parseInt(document.querySelector('.fwb-footer [aria-label=重置缩放]').textContent) > 100", "compact zoom changes the canvas scale"),
        (520, "document.querySelector('.fwb-footer [aria-label=重置缩放]').click()", "document.querySelector('.fwb-footer [aria-label=重置缩放]').textContent === '100%' && document.querySelector('.fwb-footer').getBoundingClientRect().left > document.querySelector('.fwb-toolbar').getBoundingClientRect().right", "reset zoom and controls to the right of drawing tools"),
        (900, "window.FWB.menuAction('image')", "Boolean(document.querySelector('.fwb-export')) && getComputedStyle(document.querySelector('.fwb-toolbar-slot')).visibility === 'hidden'", "native menu opens image export and hides overlays"),
        (900, "document.querySelector('.fwb-export-close').click()", "!document.querySelector('.fwb-export') && getComputedStyle(document.querySelector('.fwb-toolbar-slot')).visibility === 'visible'", "closing dialog restores input and toolbar"),
        (900, "window.FWB.menuAction('export')", "Boolean(document.querySelector('.fwb-export'))", "unified native export entry opens the same panel"),
        (900, "document.querySelector('.fwb-export-close').click()", "!document.querySelector('.fwb-export')", "unified export panel closes"),
        (900, "window.FWB.menuAction('clear')", "Boolean(document.querySelector('.Modal'))", "clear canvas retains confirmation"),
        (900, "document.querySelector('.Modal').dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true}));", "!document.querySelector('.Modal')", "clear can be cancelled"),
    ]
    guard index < checks.count else {
        print("PASS: responsive interface, native input and menu dialogs")
        projectExportChecks()
        return
    }
    let (width, setup, assertion, name) = checks[index]
    window.setContentSize(NSSize(width: width, height: 600))
    board.frame.size.width = width
    board.needsLayout = true
    board.layoutSubtreeIfNeeded()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        board.evaluateForTest(setup.isEmpty ? "true" : setup + ";true") { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                assertEventually(assertion, name) {
                    if name.contains("hides overlays") { precondition(board.inputHiddenForTest) }
                    if name.contains("restores input") { precondition(!board.inputHiddenForTest) }
                    print("PASS: \(name)")
                    interfaceChecks(index + 1)
                }
            }
        }
    }
}

let app = NSApplication.shared
setbuf(stdout, nil)
app.setActivationPolicy(.accessory)
WhiteboardView.checkJSONRegression()
let testRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_TEST_ROOT"]!)
BoardStore.setRoot(testRoot.appendingPathComponent("boards"))
let project = testRoot.appendingPathComponent("project-a")
try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
let board = WhiteboardView(project: project)
let boardComposer = GlassComposer(frame: .zero)
board.composer = boardComposer
board.onComposerVisibility = { [weak board] hidden in board?.composer?.isHidden = hidden }
board.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
let window = NSWindow(contentRect: board.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = board
let conversation = ConversationView(frame: board.frame)
conversation.checkSharedOptions(with: board)
let started = Date()
var checking = false
let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    if Date().timeIntervalSince(started) > 85 {
        fputs("FAIL: whiteboard ready handshake timed out: \(board.loadDiagnosticsForTest), checking=\(checking)\n", stderr)
        exit(1)
    }
    guard board.readyForTest, !checking else { return }
    checking = true
    // Let React finish applying the initial scene before checking the bridge.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        board.setTheme(true)
        board.setStatus("测试 \"生成\"\n中文", busy: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            board.evaluateForTest("""
                (() => {
                  const node = document.querySelector('.fwb-status');
                  return document.documentElement.classList.contains('theme-dark') &&
                    node.classList.contains('visible') && node.classList.contains('busy') &&
                    node.textContent.includes('测试 "生成"\\n中文') &&
                    window.FWB.getSceneJSON() !== null;
                })()
                """) { value in
                precondition(value as? Bool == true, "Dark theme / busy status / scene failed")
                board.setTheme(false)
                board.clearStatus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    board.evaluateForTest("""
                        !document.documentElement.classList.contains('theme-dark') &&
                        !document.querySelector('.fwb-status').classList.contains('visible') &&
                        !document.querySelector('.fwb-status').classList.contains('busy')
                        """) { value in
                        precondition(value as? Bool == true, "Light theme / clear status failed")
                        print("PASS: real WebKit ready handshake, scene load, theme and busy status")
                        board.checkNativeInput()
                        concurrentSceneChecks { interfaceChecks() }
                    }
                }
            }
        }
    }
}
app.run()
