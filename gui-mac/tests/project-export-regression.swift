// Compiled into the same temporary test application as the production source.
extension ConversationView {
    func checkErrorRecovery() {
        var statuses: [String] = []
        onAgentActivity = { text, _ in statuses.append(text) }
        busy = true
        nextTurnID += 1
        activeTurnID = nextTurnID
        handle(["type": "message_end", "message": [
            "role": "assistant", "stopReason": "error", "errorMessage": "402: Insufficient Balance",
        ]])
        precondition(busy && (statuses.last?.contains("402") == true || statuses.last?.contains("额度") == true))
        handle(["type": "agent_settled"])
        precondition(!busy)
        precondition(statuses.last?.contains("请求未完成") == true)
        busy = true
        nextTurnID += 1
        activeTurnID = nextTurnID
        handle(["type": "message_end", "message": ["role": "assistant", "stopReason": "aborted"]])
        precondition(busy)
        handle(["type": "agent_settled"])
        precondition(!busy)
        onAgentActivity = nil
        print("PASS: model errors and aborts release the composer and expose the failure")
    }
}

extension WhiteboardView {
    var documentForTest: URL { sceneURL! }
    var conversationForTest: String { conversationID }

    static func checkPDFExport() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
        let image = NSBitmapImageRep(cgImage: context.makeImage()!)
        let png = image.representation(using: .png, properties: [:])!
        let data = makePDF(from: png)!
        let pdf = PDFDocument(data: data)!
        precondition(pdf.pageCount == 1)
        let page = pdf.page(at: 0)!
        let box = page.bounds(for: .mediaBox)
        print("PDF page bounds:", box)
        try! data.write(to: URL(fileURLWithPath: "/tmp/f-export-regression.pdf"))
        precondition(abs(box.width / box.height - 2) < 0.001)
        let thumbnail = page.thumbnail(of: NSSize(width: 256, height: 128), for: .mediaBox)
        let rep = NSBitmapImageRep(data: thumbnail.tiffRepresentation!)!
        let edge = rep.colorAt(x: rep.pixelsWide / 16, y: rep.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
        print("PDF rendered edge:", edge, "pixels:", rep.pixelsWide, rep.pixelsHigh)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/f-export-regression.png"))
        precondition(edge.redComponent > 0.8 && edge.greenComponent < 0.4)
        print("PASS: exported PDF renders as one correctly cropped page with no added margins")
    }
}

private let rectangleFixture: [String: Any] = [
    "id": "project-a-rectangle", "type": "rectangle", "x": 0, "y": 0,
    "width": 300, "height": 150, "angle": 0,
    "strokeColor": "#111111", "backgroundColor": "#ff0000", "fillStyle": "solid",
    "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0, "opacity": 100,
    "version": 1, "versionNonce": 1, "isDeleted": false, "groupIds": [], "seed": 1,
]

func projectExportChecks() {
    conversation.checkErrorRecovery()
    WhiteboardView.checkPDFExport()
    let secondary = testRoot.appendingPathComponent("project-b")
    try! FileManager.default.createDirectory(at: secondary, withIntermediateDirectories: true)
    precondition(BoardStore.sceneFile(for: secondary) != BoardStore.sceneFile(for: project))
    let fixtureContext = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    fixtureContext.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    fixtureContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let imageData = NSBitmapImageRep(cgImage: fixtureContext.makeImage()!)
    let dataURL = "data:image/png;base64," + imageData.representation(using: .png, properties: [:])!.base64EncodedString()
    let image = rectangleFixture.merging(["id": "project-a-image", "type": "image", "x": 310,
        "width": 40, "height": 40, "fileId": "test-asset", "status": "saved", "scale": [1, 1]]) { _, new in new }
    let scene: [String: Any] = ["elements": [rectangleFixture, image], "appState": ["viewBackgroundColor": "transparent"],
        "files": ["test-asset": ["id": "test-asset", "dataURL": dataURL, "mimeType": "image/png", "created": 1, "lastRetrieved": 1]]]
    let data = try! JSONSerialization.data(withJSONObject: scene)
    let json = String(data: data, encoding: .utf8)!
    board.evaluateForTest("window.FWB.loadScene(\(json), {fit:false}); true") { _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let first = board.documentForTest
            board.flushCurrentScene {
                let saved = try! JSONSerialization.jsonObject(with: Data(contentsOf: first)) as! [String: Any]
                precondition((saved["elements"] as! [[String: Any]]).first?["id"] as? String == "project-a-rectangle")
                board.setProject(secondary)
                assertEventually("window.FWB.getScene().length === 0", "project B opens its own board") {
                    precondition(board.documentForTest == ConversationBoards.sceneFile(project: secondary, id: board.conversationForTest))
                    let firstLiteral = String(data: try! JSONSerialization.data(withJSONObject: first.path, options: [.fragmentsAllowed]), encoding: .utf8)!
                    board.evaluateForTest("window.webkit.messageHandlers.fwb.postMessage({type:'change',documentID:\(firstLiteral),scene:JSON.stringify({elements:[{id:'stale'}]})}); true") { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            let second = try! JSONSerialization.jsonObject(with: Data(contentsOf: board.documentForTest)) as! [String: Any]
                            precondition((second["elements"] as! [Any]).isEmpty)
                            board.setProject(project)
                            assertEventually("window.FWB.getScene()[0]?.id === 'project-a-rectangle' && window.FWB.getSceneJSON()?.files['test-asset'] !== undefined", "project A restores its saved board and images") {
                                    print("PASS: separate centralized project boards, flush before switch and rejection of stale saves")
                                    checkMigration()
                                    checkRPCConfiguration { perProjectBoardChecks { prepareExportCapture() } }
                            }
                        }
                    }
                }
            }
        }
    }
}

private func checkRPCConfiguration(_ done: @escaping () -> Void) {
    let executable = testRoot.appendingPathComponent("fake-rpc.py")
    let script = """
    #!/usr/bin/python3
    import sys,json,os
    for line in sys.stdin:
        request=json.loads(line)
        print(json.dumps({'type':'response','id':request['id'],'success':True,'data':{'board':os.environ['F_BOARD_DIR'],'project':os.environ['F_PROJECT']}}),flush=True)
    """
    try! script.write(to: executable, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let rpc = PiRPC()
    precondition(rpc.start(cliPath: executable.path, workingDirectory: project))
    rpc.request(["type": "get_state"]) { response in
        let info = response["data"] as! [String: Any]
        precondition(info["board"] as? String == BoardStore.directory(for: project).path)
        let second = testRoot.appendingPathComponent("project-b")
        precondition(rpc.start(cliPath: executable.path, workingDirectory: second))
        rpc.request(["type": "get_state"]) { response in
            let info = response["data"] as! [String: Any]
            precondition(info["project"] as? String == second.path)
            precondition(info["board"] as? String == BoardStore.directory(for: second).path)
            precondition(rpc.isRunning && rpc.isConfigured(for: second) && !rpc.isConfigured(for: project))
            let original = BoardStore.root
            BoardStore.setRoot(testRoot.appendingPathComponent("other-storage"))
            precondition(!rpc.isConfigured(for: second))
            BoardStore.setRoot(original)
            rpc.stop()
            print("PASS: project restart and storage changes keep Agent and GUI on the same board directory")
            done()
        }
    }
}

private func checkMigration() {
    // 项目内的旧画板仍先迁到统一存储，已有内容优先。
    let legacyProject = testRoot.appendingPathComponent("legacy-project")
    let legacy = legacyProject.appendingPathComponent(".f/whiteboard/scene.json")
    try! FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data("{\"elements\":[],\"legacy\":true}".utf8).write(to: legacy)
    precondition(BoardStore.migrateLegacyScene(for: legacyProject))
    let central = BoardStore.sceneFile(for: legacyProject)
    let current = Data("{\"elements\":[],\"central\":true}".utf8)
    try! current.write(to: central)
    precondition(!BoardStore.migrateLegacyScene(for: legacyProject))
    precondition(try! Data(contentsOf: central) == current)

    // 共享项目画板一次性分回每条对话。
    let project = testRoot.appendingPathComponent("conversation-migration")
    try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let ownerSession = testRoot.appendingPathComponent("owner.session").path
    let legacySession = testRoot.appendingPathComponent("legacy.session").path
    for session in [ownerSession, legacySession] {
        try! Data("{}\n".utf8).write(to: URL(fileURLWithPath: session))
    }
    let ownerID = ConversationBoards.id(for: ownerSession)
    let legacyID = ConversationBoards.id(for: legacySession)
    ConversationBoards.bind(session: ownerSession, id: ownerID)
    ConversationBoards.bind(session: legacySession, id: legacyID)
    // 最近使用过画板的对话接收没有归属的图元。
    let ownerViewport = ConversationBoards.directory(project: project, id: ownerID).appendingPathComponent("viewport.json")
    try! FileManager.default.createDirectory(at: ownerViewport.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: ["version": 1, "centerX": 10, "centerY": 20, "zoom": 1]).write(to: ownerViewport)
    let legacyScene = ConversationBoards.sceneFile(project: project, id: legacyID)
    try! FileManager.default.createDirectory(at: legacyScene.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existing: [String: Any] = ["elements": [["id": "keep-me", "type": "rectangle", "x": 0, "y": 0, "width": 10, "height": 10]], "files": [:], "revision": 1]
    let originalLegacy = try! JSONSerialization.data(withJSONObject: existing)
    try! originalLegacy.write(to: legacyScene)
    let projectBoard = BoardStore.sceneFile(for: project)
    try! FileManager.default.createDirectory(at: projectBoard.deletingLastPathComponent(), withIntermediateDirectories: true)
    let orphanID = "ffffffff-0000-0000-0000-000000000000"
    let shared: [String: Any] = [
        "type": "f-whiteboard", "version": 1, "revision": 7, "project": project.path,
        "elements": [
            ["id": "shared-shape", "type": "rectangle", "x": 0, "y": 0, "width": 20, "height": 20],
            ["id": "legacy-\(legacyID)-keep-me", "type": "rectangle", "x": 40, "y": 0, "width": 10, "height": 10],
            ["id": "legacy-\(orphanID)-orphan", "type": "rectangle", "x": 80, "y": 0, "width": 10, "height": 10],
        ],
        "files": ["legacy-\(legacyID)-photo": ["id": "legacy-\(legacyID)-photo", "dataURL": "data:image/png;base64,test"]],
    ]
    try! JSONSerialization.data(withJSONObject: shared).write(to: projectBoard)
    ConversationBoards.prepare(project: project, id: ownerID)
    let ownerScene = try! JSONSerialization.jsonObject(with: Data(contentsOf: ConversationBoards.sceneFile(project: project, id: ownerID))) as! [String: Any]
    precondition((ownerScene["elements"] as! [[String: Any]]).compactMap { $0["id"] as? String } == ["shared-shape"],
                 "unattributed elements go to the conversation that used the board last")
    precondition(try! Data(contentsOf: legacyScene) == originalLegacy, "conversation boards are never duplicated")
    precondition(!FileManager.default.fileExists(atPath: projectBoard.path), "shared project board is retired")
    let retired = BoardStore.directory(for: project).appendingPathComponent("retired")
    precondition((try! FileManager.default.contentsOfDirectory(atPath: retired.path)).count == 1, "retired scene kept for recovery")
    precondition(FileManager.default.fileExists(atPath: BoardStore.directory(for: project).appendingPathComponent("conversation-board-migration.json").path))
    ConversationBoards.prepare(project: project, id: ownerID)
    precondition(try! Data(contentsOf: legacyScene) == originalLegacy, "migration runs once")

    // 还没有自己画板的对话，从带前缀的共享元素恢复并修正引用。
    let restoreSession = testRoot.appendingPathComponent("restore.session").path
    try! Data("{}\n".utf8).write(to: URL(fileURLWithPath: restoreSession))
    let restoreID = ConversationBoards.id(for: restoreSession)
    ConversationBoards.bind(session: restoreSession, id: restoreID)
    let restoreProject = testRoot.appendingPathComponent("restore-project")
    try! FileManager.default.createDirectory(at: restoreProject, withIntermediateDirectories: true)
    let restoreFile = BoardStore.sceneFile(for: restoreProject)
    try! FileManager.default.createDirectory(at: restoreFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let prefix = "legacy-" + restoreID + "-"
    let restoreScene: [String: Any] = ["type": "f-whiteboard", "revision": 3, "project": restoreProject.path, "elements": [
        ["id": prefix + "frame", "type": "rectangle", "x": 0, "y": 0, "width": 200, "height": 120, "boundElements": [["id": prefix + "label", "type": "text"]]],
        ["id": prefix + "label", "type": "text", "x": 4, "y": 4, "width": 80, "height": 20, "containerId": prefix + "frame", "groupIds": [prefix + "group"]],
        ["id": prefix + "photo", "type": "image", "x": 220, "y": 0, "width": 40, "height": 40, "fileId": prefix + "asset"],
    ], "files": [prefix + "asset": ["id": prefix + "asset", "dataURL": "data:image/png;base64,test"]]]
    try! JSONSerialization.data(withJSONObject: restoreScene).write(to: restoreFile)
    ConversationBoards.prepare(project: restoreProject, id: restoreID)
    let restored = try! JSONSerialization.jsonObject(with: Data(contentsOf: ConversationBoards.sceneFile(project: restoreProject, id: restoreID))) as! [String: Any]
    let restoredElements = restored["elements"] as! [[String: Any]]
    precondition(restoredElements.compactMap { $0["id"] as? String } == ["frame", "label", "photo"], "prefixed elements return to their conversation")
    precondition(restoredElements[1]["containerId"] as? String == "frame" && (restoredElements[1]["groupIds"] as! [String]) == ["group"], "bindings are remapped")
    precondition((restoredElements[0]["boundElements"] as! [[String: Any]])[0]["id"] as? String == "label", "bound element ids are remapped")
    precondition(restoredElements[2]["fileId"] as? String == "asset" && (restored["files"] as! [String: Any])["asset"] != nil, "image files follow the element")

    // 找不到对应对话时只归档，不创建新画板。
    let orphanProject = testRoot.appendingPathComponent("orphan-project")
    try! FileManager.default.createDirectory(at: orphanProject, withIntermediateDirectories: true)
    let orphanFile = BoardStore.sceneFile(for: orphanProject)
    try! FileManager.default.createDirectory(at: orphanFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: ["type": "f-whiteboard", "elements": [["id": "lonely", "type": "rectangle", "x": 0, "y": 0, "width": 4, "height": 4]], "files": [:]]).write(to: orphanFile)
    ConversationBoards.prepare(project: orphanProject, id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    precondition(!FileManager.default.fileExists(atPath: ConversationBoards.sceneFile(project: orphanProject, id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee").path), "no conversation means no new board")
    precondition(!FileManager.default.fileExists(atPath: orphanFile.path), "unmatched project board is removed from view")
    print("PASS: shared project boards split back into conversation boards, remap bindings/images, archive leftovers and run once")
    checkConcurrentSceneWrites()
}

private func checkConcurrentSceneWrites() {
    let project = testRoot.appendingPathComponent("concurrent-scene")
    let file = BoardStore.sceneFile(for: project)
    try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let initial: [String: Any] = ["elements": [["id": "user", "x": 0]], "files": [:], "revision": 1]
    let baseline = try! JSONSerialization.data(withJSONObject: initial)
    try! baseline.write(to: file)
    let lock = file.deletingLastPathComponent().appendingPathComponent("harness/leases/transaction.lock")
    try! FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
    let edit: [String: Any] = ["elements": [["id": "user", "x": 10]], "files": [:]]
    if case .busy = try! ProjectSceneWriter.save(edit, baseline: baseline, to: file, project: project) {} else { preconditionFailure("native save must honor Agent lock") }
    precondition(try! Data(contentsOf: file) == baseline)
    try! FileManager.default.removeItem(at: lock)
    let agent: [String: Any] = ["elements": [["id": "user", "x": 0], ["id": "agent", "x": 200]], "files": [:], "revision": 2]
    try! JSONSerialization.data(withJSONObject: agent).write(to: file)
    if case .saved(let data, let merged, let conflicted) = try! ProjectSceneWriter.save(edit, baseline: baseline, to: file, project: project) {
        let scene = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let elements = scene["elements"] as! [[String: Any]]
        precondition(merged && !conflicted && elements.count == 2)
        precondition(elements.first { $0["id"] as? String == "user" }?["x"] as? Int == 10)
        precondition(elements.first { $0["id"] as? String == "agent" }?["x"] as? Int == 200)
    } else { preconditionFailure("lock should have been released") }
    if case .saved(let data, _, let conflicted) = try! ProjectSceneWriter.save(["elements": [["id": "user", "x": 99]]], baseline: baseline, to: file, project: project) {
        let scene = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(conflicted && (scene["elements"] as! [[String: Any]]).first?["x"] as? Int == 10)
        let drafts = try! FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().appendingPathComponent("conflicts").path)
        precondition(drafts.count == 1)
    }
    precondition(!FileManager.default.fileExists(atPath: lock.path))
    let parallel = file.deletingLastPathComponent().appendingPathComponent("parallel.json")
    let empty = Data("{\"elements\":[],\"files\":{}}".utf8)
    try! empty.write(to: parallel)
    DispatchQueue.concurrentPerform(iterations: 32) { index in
        let update: [String: Any] = ["elements": [["id": "parallel-\(index)", "x": index * 100]], "files": [:]]
        for _ in 0..<2000 {
            if case .saved = try! ProjectSceneWriter.save(update, baseline: empty, to: parallel, project: project) { return }
            usleep(1_000)
        }
        preconditionFailure("parallel scene transaction did not acquire the lock")
    }
    let parallelScene = try! JSONSerialization.jsonObject(with: Data(contentsOf: parallel)) as! [String: Any]
    precondition(Set((parallelScene["elements"] as! [[String: Any]]).compactMap { $0["id"] as? String }).count == 32)
    print("PASS: native/Agent lock exclusion, three-way merge, concurrent-element draft recovery and lock release")
}

extension RootView {
    var projectBoardForTest: WhiteboardView { whiteboardView }
    func enterApplicationForTest(_ id: String) { showApplication(id) }
    func selectBoardConversationForTest(_ project: URL, session: String) {
        activateConversation(conversation(for: project, session: session))
        setProject(project)
        showApplication("whiteboard")
    }
}

/// 每个项目一块画板：进入画板时以当前对话所在项目为准，两个项目的内容互不覆盖。
private func writeProjectBoard(_ project: URL, file: URL, marker: String) {
    try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let element: [String: Any] = [
        "id": marker, "type": "rectangle", "x": 0, "y": 0, "width": 10, "height": 10, "angle": 0,
        "strokeColor": "#111111", "backgroundColor": "transparent", "fillStyle": "solid",
        "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0, "opacity": 100, "version": 1,
        "versionNonce": 1, "isDeleted": false, "groupIds": [], "seed": 1, "updated": 1,
    ]
    let scene: [String: Any] = [
        "type": "f-whiteboard", "version": 1, "revision": 1, "project": project.path,
        "updatedAt": "2026-01-01T00:00:00.000Z", "updatedBy": "test", "elements": [element],
        "appState": ["viewBackgroundColor": "transparent", "currentItemFontFamily": 5], "files": [:],
    ]
    let data = try! JSONSerialization.data(withJSONObject: scene, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: file, options: .atomic)
}

private func savedElementIDs(_ file: URL) -> [String] {
    let data = try! Data(contentsOf: file)
    let scene = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    return (scene["elements"] as! [[String: Any]]).compactMap { $0["id"] as? String }
}

func perProjectBoardChecks(_ done: @escaping () -> Void) {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: PluginPreferences.disabledKey)
    defaults.set(["ssh"], forKey: PluginPreferences.disabledKey)
    let first = testRoot.appendingPathComponent("board-project-a")
    let second = testRoot.appendingPathComponent("board-project-b")
    for project in [first, second] {
        try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }
    let firstSession = testRoot.appendingPathComponent("aios.session").path
    let secondSession = testRoot.appendingPathComponent("agent.session").path
    let firstFile = ConversationBoards.sceneFile(project: first, id: ConversationBoards.id(for: firstSession))
    let secondFile = ConversationBoards.sceneFile(project: second, id: ConversationBoards.id(for: secondSession))
    precondition(firstFile != secondFile)
    writeProjectBoard(first, file: firstFile, marker: "marker-project-a")
    writeProjectBoard(second, file: secondFile, marker: "marker-project-b")
    ProjectStore.remember(first)
    let host = RootView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let view = host.projectBoardForTest

    func finish() {
        host.shutdownPlugins()
        if let previous { defaults.set(previous, forKey: PluginPreferences.disabledKey) }
        else { defaults.removeObject(forKey: PluginPreferences.disabledKey) }
        print("PASS: each conversation keeps its own board inside the project folder")
        done()
    }

    func waitForScene(_ marker: String, _ label: String, _ next: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(20)
        func poll() {
            view.evaluateForTest("window.FWB.getScene()[0]?.id ?? null") { value in
                if value as? String == marker { next(); return }
                if Date() > deadline { fputs("FAIL: board scene \(label)\n", stderr); exit(1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
            }
        }
        poll()
    }

    func run() {
        host.selectBoardConversationForTest(second, session: secondSession)
        waitForScene("marker-project-b", "agent conversation has its own board") {
            host.selectBoardConversationForTest(first, session: firstSession)
            waitForScene("marker-project-a", "AIOS project has its own board") {
                precondition(view.documentForTest == firstFile)
                precondition(savedElementIDs(secondFile) == ["marker-project-b"])
                let prompt = ConversationView.whiteboardPrompt("测试绘制", project: second, boardDirectory: secondFile.deletingLastPathComponent())
                precondition(prompt.contains(secondFile.path) && !prompt.contains(firstFile.path))
                host.selectBoardConversationForTest(second, session: secondSession)
                waitForScene("marker-project-b", "switching back restores agent's board") {
                    precondition(savedElementIDs(firstFile) == ["marker-project-a"])
                    finish()
                }
            }
        }
    }

    let deadline = Date().addingTimeInterval(25)
    func waitReady() {
        if view.readyForTest { run(); return }
        if Date() > deadline { fputs("FAIL: root board web view never became ready\n", stderr); exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { waitReady() }
    }
    waitReady()
}

/// Capture the real WKScriptMessage channel. Patching a temporary JavaScript
/// message-handler wrapper can lose the interception after WebKit collects it.
private final class ExportCaptureHandler: NSObject, WKScriptMessageHandler {
    weak var board: WhiteboardView?
    init(board: WhiteboardView) { self.board = board }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let board else { return }
        if let payload = message.body as? [String: Any], payload["type"] as? String == "saveImage" {
            board.captureExportPayloadForTest(payload)
        } else { board.userContentController(controller, didReceive: message) }
    }
}
extension WhiteboardView {
    func captureExportPayloadForTest(_ payload: [String: Any]) {
        evaluateForTest("window.__exportResult = " + Self.jsonString(payload)) { _ in }
    }
    func installExportCaptureForTest() {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "fwb")
        controller.add(ExportCaptureHandler(board: self), name: "fwb")
    }
}
private func prepareExportCapture() {
    board.installExportCaptureForTest()
    board.evaluateForTest("window.__exportResult = null; true") { _ in runExportCheck() }
}

private func runExportCheck(_ index: Int = 0) {
    let exports = [("png", "1K", 1024), ("png", "2K", 2048), ("png", "4K", 4096),
                   ("jpg", "1K", 1024), ("svg", "1K", 0), ("pdf", "2K", 2048)]
    guard index < exports.count else {
        print("PASS: project storage and all four export formats at 1K / 2K / 4K")
        exit(0)
    }
    let (format, size, pixels) = exports[index]
    board.evaluateForTest("window.__exportResult = null; window.FWB.menuAction('export'); true") { _ in
        assertEventually("Boolean(document.querySelector('.fwb-export'))", "export panel appears") {
            board.evaluateForTest("document.querySelector('.fwb-export [aria-label=\(format.uppercased())]').click(); true") { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    board.evaluateForTest("document.querySelector('.fwb-export [aria-label=\"\(size)\"]').click(); true") { _ in
                        assertEventually("""
                            (() => {
                              const panel = document.querySelector('.fwb-export');
                              const info = panel?.querySelector('.fwb-export-info')?.textContent ?? '';
                              const dimensions = (info.split('·')[0].match(/\\d+/g) ?? []).map(Number);
                              const correctPreview = '\(format)' === 'svg' ? info.includes('矢量') : Math.max(...dimensions) === \(pixels);
                              return !!panel?.querySelector('[aria-label="\(format.uppercased())"].active') &&
                                correctPreview && !panel.querySelector('.fwb-export-foot button').disabled;
                            })()
                            """, "requested export preview completes", attempts: 60) {
                            board.evaluateForTest("document.querySelector('.fwb-export-foot button').click(); true") { _ in
                                assertEventually("window.__exportResult !== null", "export encoding finishes", attempts: 60) {
                                    board.evaluateForTest("window.__exportResult") { result in
                                        let payload = result as! [String: Any]
                                        precondition(payload["format"] as? String == format)
                                        let data = Data(base64Encoded: payload["data"] as! String)!
                                        if format == "svg" {
                                            precondition(String(data: data, encoding: .utf8)!.contains("<svg"))
                                        } else {
                                            let image = NSBitmapImageRep(data: data)!
                                            precondition(max(image.pixelsWide, image.pixelsHigh) == pixels)
                                            let blue = image.colorAt(x: image.pixelsWide * 94 / 100, y: image.pixelsHigh * 13 / 100)!.usingColorSpace(.deviceRGB)!
                                            precondition(blue.blueComponent > 0.6 && blue.redComponent < 0.4, "Embedded project image missing from export")
                                            if format == "jpg" { precondition(data.starts(with: [0xff, 0xd8])) }
                                            else { precondition(data.starts(with: [0x89, 0x50, 0x4e, 0x47])) }
                                        }
                                        print("PASS: \(format.uppercased()) \(size) encoding and pixel dimensions")
                                        runExportCheck(index + 1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
