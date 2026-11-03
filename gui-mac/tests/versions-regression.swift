import AppKit

setbuf(stdout, nil)
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError("FAIL: " + label) }
    checks += 1; print("PASS: " + label)
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
func until(_ label: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(12)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    expect(condition(), label)
}
func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
func git(_ args: [String]) throws -> Data {
    let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", "__TEST_DIR__/repo"] + args; p.standardOutput = pipe; p.standardError = pipe
    try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    expect(p.terminationStatus == 0, "fixture git " + args.joined(separator: " ")); return data
}
let root = URL(fileURLWithPath: "__TEST_DIR__/repo")
let hashes = try String(contentsOfFile: "__TEST_DIR__/hashes.txt", encoding: .utf8).components(separatedBy: "\n")
let before = try git(["status", "--porcelain=v1", "-z"])
let reader = VersionGitReader(project: root)
let commits = try reader.history(branches: [["id": "root", "head": hashes[2], "branch": "main"]])
expect(commits.count == 4 && Set(commits.compactMap { $0["id"] as? String }).count == 4, "legacy history retains immutable distinct commits")
expect((commits.first { $0["head"] as? String == hashes[2] }?["parents"] as? [String])?.count == 2, "history preserves both real merge parents")
let first = try reader.snapshot(hash: hashes[0]), child = try reader.snapshot(hash: hashes[1]), merge = try reader.snapshot(hash: hashes[2])
expect(first.parents.isEmpty && merge.parents.count == 2 && merge.parents.contains(hashes[1]), "snapshot preserves real initial and merge ancestry")
expect(child.files.contains { $0.path == "delete.txt" && $0.object == nil && $0.change == "D" }, "deleted paths remain in commit file list")
expect(first.files.contains { $0.path == "tab\tline\n中文.txt" }, "NUL records preserve tabs, newline and Unicode filenames")
let oldText = try reader.contents(of: first.files.first { $0.path == "read me.txt" }!)
let childText = try reader.contents(of: child.files.first { $0.path == "read me.txt" }!)
expect(oldText == "first fixed snapshot\n" && childText == "child immutable content\n", "fixed hash previews ignore branch and uncommitted contents")
let binary = try reader.contents(of: first.files.first { $0.path == "二进制.bin" }!)
expect(binary.contains("二进制"), "binary content is not rendered as text")
let symlink = try reader.contents(of: first.files.first { $0.path == "symlink" }!)
expect(symlink == "/etc/passwd", "symlinks preview only blob bytes, never target files")
let large = try reader.contents(of: first.files.first { $0.path == "large.txt" }!)
expect(large.contains("超过 2 MB"), "oversized files are bounded")
let empty = try reader.contents(of: first.files.first { $0.path == "empty" }!)
expect(empty == "（空文件）", "empty files supported")
expect(child.synopsis.contains("测试作者") && child.synopsis.contains("Git") && child.synopsis.count <= 200, "real source-attributed synopsis strictly at most 200 characters")
let verbose = VersionSnapshot(hash: hashes[0], parents: [], author: String(repeating: "长作者", count: 100), date: first.date, message: String(repeating: "真实说明🙂", count: 500), files: first.files)
expect(verbose.synopsis.count <= 200 && verbose.synopsis.contains("真实说明") && verbose.synopsis.contains("不代表测试结论"), "long Unicode summaries remain bounded without inventing validation")
for invalid in ["HEAD", "--help", hashes[0] + ":read me.txt", String(repeating: "a", count: 39)] {
    do { _ = try reader.snapshot(hash: invalid); fatalError("accepted invalid hash") } catch { expect(true, "reject non-fixed object identifier") }
}
do { _ = try VersionGitReader(project: root.appendingPathComponent("subdir")).snapshot(hash: hashes[0]); fatalError("read parent repository") }
catch { expect(true, "parent repository is not used for project snapshots") }
let cancelled = VersionGitReader(project: root); cancelled.cancel()
do { _ = try cancelled.snapshot(hash: hashes[0]); fatalError("cancelled reader ran") } catch { expect(true, "cancelled readers stop before launching Git") }

_ = NSApplication.shared
let nodes: [[String: Any]] = [
    ["id": "major-root", "kind": "major", "label": "项目主版本", "commit": hashes[0]],
    ["id": "agent-a", "kind": "agent", "label": "任务一", "head": hashes[1], "parent": "major-root"],
    ["id": "agent-b", "kind": "agent", "label": "任务二", "commit": hashes[0], "parent": "major-root"],
    ["id": "major-merge", "kind": "major", "label": "合并版本", "commit": hashes[2], "parents": ["major-root", "agent-a", "agent-b"]]
]
var requests: [[String: Any]] = []
var backendEnabled = false
var backendNodes = nodes
let plugin = VersionsPlugin(project: root, executor: { request, _, done in
    requests.append(request)
    if request["action"] as? String == "enable" { backendEnabled = true }
    done(["ok": true, "value": ["enabled": backendEnabled, "nodes": [["id": "legacy-should-not-appear"]], "versions": backendNodes]])
})
let scope = FPluginScope(); plugin.mount(in: scope); plugin.setEnabled(true)
plugin.projectDidChange(root.appendingPathComponent("subdir")); plugin.projectDidChange(root)
pump()
expect(requests.isEmpty, "construction, mount, global preference and project switching issue zero requests/writes")
expect(plugin.menuCommands.map(\.id) == ["open", "publish"], "only open and separate major publication menu; no developer menus")
for action in ["enable", "branch", "commit", "merge", "unknown"] { plugin.performMenuCommand(action) }
expect(requests.isEmpty, "retired developer menu IDs cannot enable or mutate repositories")
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 850), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentView = plugin.view
plugin.view.layoutSubtreeIfNeeded()
let graph = descendants(plugin.view).compactMap { $0 as? VersionGraphView }.first!
let inspector = descendants(plugin.view).compactMap { $0 as? VersionInspectorView }.first!
plugin.activate()
until("first user activation performs status then authorized native enable") { requests.count == 2 && graph.subviews.count == 4 }
expect(requests.map { $0["action"] as? String ?? "" } == ["status", "enable"] && requests[1]["authorized"] as? Bool == true, "repository opt-in is distinct from global plugin enable")
expect(graph.subviews.allSatisfy { $0.identifier?.rawValue != "legacy-should-not-appear" }, "fixed versions are preferred over moving legacy nodes")
plugin.activate(); until("later activation refreshes without re-enabling") { requests.count == 3 }
expect(requests.last?["action"] as? String == "status", "persistent repository consent is not rewritten on revisit")
let buttons = graph.subviews.compactMap { $0 as? VersionNodeButton }
func button(_ id: String) -> VersionNodeButton { graph.subviews.first { $0.identifier?.rawValue == id } as! VersionNodeButton }
expect(buttons.count == 4 && buttons.allSatisfy { $0.title.isEmpty && $0.frame.size == NSSize(width: 48, height: 48) }, "SVG rings have 24-point hit radius and no text cards")
expect(buttons.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty && $0.acceptsFirstResponder }, "every dot retains native keyboard and accessibility semantics")
expect(!graph.isOpaque && graph.enclosingScrollView?.drawsBackground == false, "graph and host scroll view remain transparent")
let rootButton = button("major-root"), aButton = button("agent-a"), bButton = button("agent-b"), mergeButton = button("major-merge")
expect(rootButton.hitTest(NSPoint(x: rootButton.frame.midX, y: rootButton.frame.midY)) === rootButton && rootButton.hitTest(NSPoint(x: rootButton.frame.minX + 1, y: rootButton.frame.minY + 1)) == nil, "hit testing uses a real circular radius of 24 rather than square corners")
expect(rootButton.frame.midY == mergeButton.frame.midY, "first-parent mainline stays on center row")
expect(aButton.frame.midY + bButton.frame.midY == rootButton.frame.midY * 2 && aButton.frame.midY != bButton.frame.midY, "parallel forks are symmetric above and below mainline")
expect([rootButton, aButton, bButton].allSatisfy { $0.frame.maxX < mergeButton.frame.minX }, "all real merge parents precede child horizontally")
expect(graph.enclosingScrollView?.hasHorizontalScroller == true && graph.enclosingScrollView?.hasVerticalScroller == true, "native scroll view supports two-finger horizontal and vertical scrolling")
let positions = Dictionary(uniqueKeysWithValues: graph.subviews.map { ($0.identifier!.rawValue, $0.frame) })
graph.display(Array(nodes.reversed()))
expect(graph.subviews.allSatisfy { positions[$0.identifier!.rawValue] == $0.frame }, "topology layout is stable when backend order changes")
expect(abs(button("major-merge").ringRadius - 8 * 1.19) < 0.001 && button("agent-a").ringRadius == 8, "selection scales ring exactly 1.19 without moving layout")
let mouse = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
button("agent-a").mouseEntered(with: mouse)
expect(abs(button("agent-a").ringRadius - 8 * 1.19) < 0.001, "hover scales ring exactly 1.19")
button("agent-a").mouseExited(with: mouse)
expect(button("agent-a").ringRadius == 8, "hover exit restores unselected ring")
button("agent-a").performClick(nil)
expect(graph.selectedID == "agent-a", "native dot click selects fixed agent version")
let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
let nextID = graph.orderedIDs[graph.orderedIDs.firstIndex(of: "agent-a")! + 1]
button("agent-a").keyDown(with: right)
expect(graph.selectedID == nextID, "real AppKit arrow-key event selects next topological node")
button("agent-a").performClick(nil)
plugin.performMenuCommand("publish")
expect(requests.count == 3, "agent/development versions cannot publish or open authorization dialog")
until("selected agent node loads its pinned commit") {
    descendants(inspector).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Git commit " + hashes[1]) }
}
expect(!inspector.detailsExpanded, "file preview is initially collected in secondary disclosure")
expect(descendants(inspector).compactMap { $0 as? NSTextView }.allSatisfy { !$0.isEditable && !$0.drawsBackground }, "secondary file preview remains transparent and read-only")
let disclosure = descendants(inspector).compactMap { $0 as? NSButton }.first!
disclosure.performClick(nil); plugin.view.layoutSubtreeIfNeeded()
expect(inspector.detailsExpanded, "native disclosure reveals commit files and provenance")
let table = descendants(inspector).compactMap { $0 as? NSTableView }.first!
let row = child.files.firstIndex { $0.path == "read me.txt" }!
table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
until("file selection previews only immutable blob") {
    descendants(inspector).compactMap { $0 as? NSTextView }.contains { $0.string == "child immutable content\n" }
}
inspector.load(node: nodes[0], project: root); inspector.load(node: nodes[1], project: root)
until("late prior node result cannot overwrite current commit") {
    descendants(inspector).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Git commit " + hashes[1]) }
}
expect(table.numberOfRows == child.files.count && table.visibleRect.height > 40, "expanded real AppKit file table has usable visible space")
// Match host menu routing: same-project notification + activate immediately before command.
button("major-merge").performClick(nil); plugin.projectDidChange(root)
expect(graph.selectedID == "major-merge", "same-project host notification preserves selected publication target")
plugin.activate()
var authorizedModal = false
DispatchQueue.main.async {
    guard let modal = NSApp.modalWindow else { return }
    authorizedModal = true
    descendants(modal.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }?.stringValue = "test-owner/test-repo"
    NSApp.stopModal(withCode: .alertFirstButtonReturn)
}
plugin.performMenuCommand("publish")
expect(authorizedModal, "real AppKit major-publication authorization opens during host status refresh")
until("authorized publication carries selected immutable major ID (injected transport, no network)") { requests.last?["action"] as? String == "publish" }
expect(requests.last?["version"] as? String == "major-merge" && requests.last?["authorized"] as? Bool == true && requests.last?["repository"] as? String == "test-owner/test-repo", "publication request never substitutes root or moving branch")
button("agent-a").performClick(nil)
until("restore selected agent synopsis after menu test") { descendants(inspector).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Git commit " + hashes[1]) } }
func capture(_ view: NSView, _ name: String) throws {
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "__TEST_DIR__/transparent-" + name))
    // Evidence screenshots use a host-like backdrop; the production graph stays alpha-only.
    let image = NSImage(size: view.bounds.size); image.lockFocus()
    let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor.white).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: view.bounds.size)).fill()
    NSImage(cgImage: rep.cgImage!, size: view.bounds.size).draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero, operation: .sourceOver, fraction: 1)
    image.unlockFocus()
    let composed = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try composed.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "__TEST_DIR__/" + name))
}
plugin.applyAppearance(dark: true); try capture(plugin.view, "native-workspace-dark.png")
plugin.applyAppearance(dark: false); try capture(plugin.view, "native-workspace-light.png")
let alpha = graph.bitmapImageRepForCachingDisplay(in: graph.bounds)!
graph.cacheDisplay(in: graph.bounds, to: alpha)
expect(alpha.colorAt(x: 0, y: 0)!.alphaComponent == 0, "actual rendered graph corner remains transparent, not a painted panel")
disclosure.performClick(nil); plugin.view.layoutSubtreeIfNeeded(); try capture(plugin.view, "native-workspace-collapsed.png")
expect(!inspector.detailsExpanded && graph.enclosingScrollView!.frame.height > 500, "collapsed details return workspace height to transparent graph")
let recoverable = nodes + [["id": "orphan", "parent": "missing"], ["id": "cycle-a", "parent": "cycle-b"], ["id": "cycle-b", "parent": "cycle-a"]]
graph.display(recoverable)
expect(graph.subviews.count == 7, "orphans and malformed cycles remain individually recoverable")
var long: [[String: Any]] = []
for i in 0..<80 { long.append(["id": "v-\(i)", "commit": hashes[0], "parents": i == 0 ? [] : ["v-\(i - 1)"]]) }
graph.display(long); try capture(graph, "native-long-graph.png")
let scroll = graph.enclosingScrollView!
scroll.contentView.scroll(to: NSPoint(x: 1600, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
expect(graph.frame.width > 10000 && scroll.contentView.bounds.origin.x > 1000, "long native document actually scrolls horizontally without zooming")
let afterRequests = requests.count
inspector.load(node: nodes[0], project: root); plugin.projectDidChange(root.appendingPathComponent("subdir")); pump()
expect(graph.subviews.isEmpty && table.numberOfRows == 0 && requests.count == afterRequests, "project switch clears old callbacks and does not start work")
plugin.setEnabled(false); plugin.setEnabled(true); pump()
expect(requests.count == afterRequests, "global plugin re-enable alone cannot opt in a project")
// Explicit empty versions must never fall back to mutable branch heads.
backendNodes = []; plugin.projectDidChange(root); plugin.activate()
until("empty fixed history stays empty with friendly first-update prompt") {
    graph.subviews.isEmpty && descendants(plugin.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("等待 Agent") }
}
let legacy = VersionsPlugin(project: root, executor: { _, _, done in done(["ok": true, "value": ["nodes": nodes]]) })
legacy.activate()
until("old backend lacking versions key still supports legacy nodes") { descendants(legacy.view).compactMap { $0 as? VersionGraphView }.first!.subviews.count == 4 }
var late: (([String: Any]) -> Void)?
var staleRequests = 0
let stale = VersionsPlugin(project: root, executor: { _, _, done in staleRequests += 1; late = done })
stale.activate(); stale.projectDidChange(root.appendingPathComponent("subdir"))
late?(["ok": true, "value": ["enabled": false, "nodes": [], "versions": []]]); pump()
expect(staleRequests == 1 && !stale.hasPendingWork, "late disabled status from old project cannot auto-enable new project")
let staleGraph = descendants(stale.view).compactMap { $0 as? VersionGraphView }.first!
expect(staleGraph.subviews.isEmpty, "late status cannot repopulate switched project graph")
inspector.load(node: nodes[0], project: root); plugin.setEnabled(false); pump()
expect(table.numberOfRows == 0 && descendants(inspector).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "点击版本节点查看提交概述与文件。" }, "plugin disable cancels and invalidates pending snapshot reads")
let after = try git(["status", "--porcelain=v1", "-z"])
expect(before == after, "all snapshot and UI reads leave original index/worktree unchanged")

// The real production transport/CLI, not the injected executor, opts in only on click.
let opt = URL(fileURLWithPath: "__TEST_DIR__/opt-in"), other = URL(fileURLWithPath: "__TEST_DIR__/other")
let native = VersionsPlugin(project: opt), nativeScope = FPluginScope()
native.mount(in: nativeScope); native.setEnabled(true); native.projectDidChange(other); native.projectDidChange(opt)
pump()
expect(!FileManager.default.fileExists(atPath: opt.appendingPathComponent(".git").path) && !FileManager.default.fileExists(atPath: other.appendingPathComponent(".git").path), "real native lifecycle leaves uninitialized projects completely untouched")
native.activate()
until("real native activation persists authorized repository opt-in through CLI") {
    let file = opt.appendingPathComponent(".git/f-tree.json")
    guard let data = try? Data(contentsOf: file), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return state["enabled"] as? Bool == true && !native.hasPendingWork && descendants(native.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("等待 Agent") }
}
let nativeState = try Data(contentsOf: opt.appendingPathComponent(".git/f-tree.json"))
let nativeJSON = try JSONSerialization.jsonObject(with: nativeState) as! [String: Any]
expect((nativeJSON["versions"] as? [[String: Any]])?.isEmpty == true, "initial enable never fabricates a tested major version")
let userContent = try String(contentsOf: opt.appendingPathComponent("user.txt"), encoding: .utf8)
expect(userContent == "preserve this untracked file\n", "real opt-in preserves user's untracked contents")
native.setEnabled(false); native.projectDidChange(other); native.setEnabled(true); pump()
expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent(".git").path), "switch/global preference still cannot enable another real repository")
scope.dispose(); nativeScope.dispose()
print("SUCCESS: \(checks) assertions")
