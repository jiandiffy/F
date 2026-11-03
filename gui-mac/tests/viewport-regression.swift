func verifyViewport(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { fputs("FAIL: \(label)\n", stderr); exit(1) }
}
func viewportWait(_ label: String, _ condition: @escaping () -> Bool, _ done: @escaping () -> Void) {
    let deadline = Date().addingTimeInterval(15)
    var timer: Timer?
    timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
        if condition() { timer?.invalidate(); done() }
        else if Date() > deadline { fputs("FAIL: viewport timeout \(label)\n", stderr); exit(1) }
    }
}
extension WhiteboardView {
    var viewportReady: Bool { webReady }
    var activeViewportID: String? { conversationID }
    func viewportSnapshot(_ done: @escaping ([String: Any]?) -> Void) {
        webView.evaluateJavaScript("window.FWB.getDocumentSnapshot()") { value, error in
            verifyViewport(error == nil, "real WebKit snapshot")
            done(value as? [String: Any])
        }
    }
    func moveViewport(_ value: [String: Any], _ done: @escaping () -> Void) {
        let value = Self.jsonString(value)
        webView.evaluateJavaScript("(() => { const s=window.FWB.getDocumentSnapshot(); window.FWB.loadScene(s.scene,{...s,fit:true,viewport:\(value)}); })()") { _, error in
            verifyViewport(error == nil, "set actual Excalidraw viewport")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
        }
    }
    func rejectStaleViewport() {
        verifyViewport(!matchesCurrentView(["documentID": sceneURL!.path, "conversationID": conversationID!, "viewGeneration": viewGeneration - 1]), "reject stale view generation")
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let work = URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_VIEWPORT_ROOT"]!)
let project = work.appendingPathComponent("shared-project").standardizedFileURL
try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
BoardStore.setRoot(work.appendingPathComponent("boards"))
let a = "aaaaaaaa", b = "bbbbbbbb"
func file(_ id: String) -> URL { ConversationBoards.directory(project: project, id: id).appendingPathComponent("viewport.json") }
func viewport(_ x: Double, _ y: Double, _ z: Double) -> [String: Any] { ["version": 1, "centerX": x, "centerY": y, "zoom": z] }
let first = viewport(1200, -450, 1.7), second = viewport(-800, 3500, 0.6), moved = viewport(2700, 900, 2.3)
for (id, value) in [(a, first), (b, second)] {
    try! FileManager.default.createDirectory(at: file(id).deletingLastPathComponent(), withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: value).write(to: file(id))
}
func close(_ actual: [String: Any]?, _ expected: [String: Any]) -> Bool {
    guard let actual else { return false }
    return ["centerX", "centerY", "zoom"].allSatisfy { key in
        guard let lhs = actual[key] as? Double, let rhs = expected[key] as? Double else { return false }
        return abs(lhs - rhs) < 0.01
    }
}
let board = WhiteboardView(project: project)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentView = board; window.orderFront(nil)
board.setConversation(a, project: project)
func snapshotMatches(_ id: String, _ expected: [String: Any], _ done: @escaping () -> Void) {
    var found = false, querying = false
    viewportWait(id, { found }) { done() }
    func query() {
        guard !found else { return }
        if !querying {
            querying = true
            board.viewportSnapshot { snapshot in
                found = snapshot?["conversationID"] as? String == id && close(snapshot?["viewport"] as? [String: Any], expected)
                querying = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: query)
    }
    query()
}
viewportWait("ready", { board.viewportReady }) {
    snapshotMatches(a, first) {
        board.rejectStaleViewport()
        board.moveViewport(moved) {
            board.flushCurrentScene {
                let saved = (try! JSONSerialization.jsonObject(with: Data(contentsOf: file(a)))) as? [String: Any]
                verifyViewport(close(saved, moved), "private viewport atomically captures real canvas")
                let scene = (try! JSONSerialization.jsonObject(with: Data(contentsOf: BoardStore.sceneFile(for: project)))) as! [String: Any]
                let state = scene["appState"] as? [String: Any] ?? [:]
                verifyViewport(state["scrollX"] == nil && state["zoom"] == nil, "shared scene excludes private offsets")
                board.setConversation(b, project: project)
                snapshotMatches(b, second) {
                    board.setConversation(a, project: project)
                    snapshotMatches(a, moved) {
                        window.setContentSize(NSSize(width: 750, height: 520))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            snapshotMatches(a, moved) {
                                for i in 0..<80 { board.setConversation(i % 2 == 0 ? b : a, project: project) }
                                board.setConversation(b, project: project)
                                snapshotMatches(b, second) {
                                    let fresh = WhiteboardView(project: project)
                                    window.contentView = fresh
                                    fresh.setConversation(a, project: project)
                                    viewportWait("recreated ready", { fresh.viewportReady && fresh.activeViewportID == a }) {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                            fresh.viewportSnapshot { result in
                                                verifyViewport(close(result?["viewport"] as? [String: Any], moved), "new WebKit instance reloads private viewport from disk")
                                                verifyViewport(FileManager.default.fileExists(atPath: file(b).path), "other conversation state retained")
                                                print("PASS: real WebKit private viewport capture, same-project A/B isolation, resize center, 80 rapid switches, recreation and shared scene separation")
                                                exit(0)
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
    }
}
app.run()
