import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let mutationRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_PROJECT_MUTATION_ROOT"]!).resolvingSymlinksInPath()
let fm = FileManager.default
var assertions = 0
var fixtureSuites: [String] = []
func cleanupDefaults() {
    for suite in fixtureSuites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    if let bundle = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundle) }
    UserDefaults.standard.synchronize()
}
func expect(_ ok: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !ok() { fputs("FAIL: \(message)\n", stderr); cleanupDefaults(); exit(1) }
}
func mkdir(_ url: URL) { try! fm.createDirectory(at: url, withIntermediateDirectories: true) }
func json(_ object: Any, _ url: URL) { mkdir(url.deletingLastPathComponent()); try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url) }
func object(_ url: URL) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }
func git(_ args: [String]) -> String {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for key in Array(environment.keys) where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"; environment["GIT_CONFIG_NOSYSTEM"] = "1"
    process.environment = environment
    process.standardOutput = output; process.standardError = FileHandle.standardError
    try! process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    expect(process.terminationStatus == 0, "isolated git " + args.joined(separator: " "))
    return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
}
func rejected(_ body: () throws -> Void, _ message: String) {
    do { try body(); expect(false, message) } catch { expect(true, message) }
}
func waitFor(_ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(condition(), message)
}
func rpcEvents(_ project: URL) -> [[String: Any]] {
    guard let data = try? Data(contentsOf: project.appendingPathComponent("rpc-events.jsonl")) else { return [] }
    return data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
}
struct Fixture {
    let root: URL
    let source: URL
    let sessions: URL
    let support: URL
    let defaults: UserDefaults
    var environment: ProjectMutation.Environment {
        ProjectMutation.Environment(defaults: defaults, support: support, sessions: sessions, protectedRoots: [])
    }
    init(_ name: String) {
        root = mutationRoot.appendingPathComponent(name)
        source = root.appendingPathComponent("旧 项目-中文")
        sessions = root.appendingPathComponent("sessions")
        support = root.appendingPathComponent("support")
        let suite = "f.mutation.fixture." + UUID().uuidString
        fixtureSuites.append(suite)
        defaults = UserDefaults(suiteName: suite)!
        [source, sessions, support].forEach(mkdir)
    }
}
let boardRoot = mutationRoot.appendingPathComponent("boards")
BoardStore.setRoot(boardRoot)

// Real project-row menus: version publication is no longer reachable from the project context menu.
let menuProject = mutationRoot.appendingPathComponent("menu-project")
mkdir(menuProject)
ProjectStore.remember(menuProject)
let list = ChatListDocumentView()
list.setChats([])
let menus = list.subviews.compactMap { ($0 as? AppRowView)?.menu }
expect(menus.contains { $0.items.map(\.title) == ["Rename…", "Delete"] }, "project menu contains exactly Rename/Delete")

// Persistent hide survives history reload and implicit remember; explicit reopen is reversible.
let hidden = Fixture("hidden")
let hiddenSession = hidden.sessions.appendingPathComponent("history.jsonl")
let originalSession = Data("{\"type\":\"session\",\"id\":\"h\",\"cwd\":\"\(hidden.source.path)\"}\n".utf8)
try! originalSession.write(to: hiddenSession)
let chat = PiChat(id: "h", title: "history", date: Date(), path: hiddenSession, cwd: hidden.source.path)
ProjectStore.remember(hidden.source, defaults: hidden.defaults)
ProjectStore.hide(hidden.source, defaults: hidden.defaults)
ProjectStore.remember(hidden.source, defaults: hidden.defaults)
expect(ProjectStore.folders(chats: [chat], defaults: hidden.defaults).isEmpty, "history and background remember do not revive Delete")
expect(hidden.defaults.stringArray(forKey: "FHiddenProjectFolders") == [hidden.source.path], "hidden entry persisted")
expect((try! Data(contentsOf: hiddenSession)) == originalSession && fm.fileExists(atPath: hidden.source.path), "Delete leaves files/session bytes intact")
ProjectStore.reopen(hidden.source, defaults: hidden.defaults)
expect(ProjectStore.folders(chats: [chat], defaults: hidden.defaults).map(\.path) == [hidden.source.path], "explicit open restores one deduplicated entry")

let fixture = Fixture("rename")
let subproject = fixture.source.appendingPathComponent("子目录")
mkdir(subproject)
let oldBoard = BoardStore.directory(for: fixture.source)
let oldSubBoard = BoardStore.directory(for: subproject)
let session = fixture.sessions.appendingPathComponent("old-encoded-directory/session.jsonl")
let emptySession = fixture.sessions.appendingPathComponent("old-encoded-directory/empty.jsonl")
let message = "{\"type\":\"message\",\"id\":\"m\",\"parentId\":null,\"message\":{\"role\":\"user\",\"content\":\"历史路径 \(fixture.source.path)\"}}\n"
mkdir(session.deletingLastPathComponent())
let header: [String: Any] = ["type": "session", "id": "session-id", "cwd": fixture.source.path]
let beforeHeader = try! JSONSerialization.data(withJSONObject: header)
try! (beforeHeader + Data("\n".utf8) + Data(message.utf8)).write(to: session)
json(["type": "session", "id": "empty", "cwd": subproject.path], emptySession)
// Unrelated malformed history must not globally gate rename.
try! Data("not-a-session\n".utf8).write(to: fixture.sessions.appendingPathComponent("unrelated.jsonl"))
json(["project": fixture.source.path, "elements": [["id": "e", "text": fixture.source.path]], "files": [:]], oldBoard.appendingPathComponent("scene.json"))
json(["project": subproject.path, "mainDraft": "keep draft", "model": "keep-model", "boardID": "keep-board-id", "session": session.path], oldSubBoard.appendingPathComponent("conversations/keep-board-id/interruptions/test.json"))
let childSession = oldBoard.appendingPathComponent("conversations/keep-board-id/harness/subagents/child/child.jsonl")
json(["type": "session", "id": "child", "cwd": fixture.source.path, "parentSession": session.path], childSession)
json([["cwd": fixture.source.path, "sessionFile": childSession.path, "childId": "child"]], childSession.deletingLastPathComponent().appendingPathComponent("catalog.json"))
// Plugin isolation and full storage-directory migration, including an intentionally opaque binary.
func storage(_ id: String, _ project: URL) -> URL {
    fixture.support.appendingPathComponent("applications/" + id + "/" + SHA256.hash(data: Data(project.path.utf8)).map { String(format: "%02x", $0) }.joined())
}
let oldPlugin = storage("fixture", fixture.source)
mkdir(oldPlugin); try! Data([0, 1, 255]).write(to: oldPlugin.appendingPathComponent("opaque.bin"))
let templates = fixture.root.appendingPathComponent("empty-git-templates"); mkdir(templates)
_ = git(["-c", "init.templateDir=" + templates.path, "init", "--initial-branch=main", fixture.source.path])
_ = git(["-C", fixture.source.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "fixture"])
let oid = git(["-C", fixture.source.path, "rev-parse", "HEAD"])
_ = git(["-C", fixture.source.path, "update-ref", "refs/f/version-snapshots/fixture-major", oid])
let gitDirectory = fixture.source.appendingPathComponent(".git")
json(["enabled": true, "nodes": [["id": "root", "worktree": fixture.source.path, "validation": ["text": fixture.source.path]]], "versions": [["id": "fixture-major", "oid": oid]]], gitDirectory.appendingPathComponent("f-tree.json"))
json(["project": fixture.source.path, "session": session.path, "mainDraft": "draft", "boardID": "keep-board-id", "background": [["project": subproject.path]]], fixture.support.appendingPathComponent("updates/last-resume.json"))
fixture.defaults.set([fixture.source.path, subproject.path], forKey: "FProjectFolders")
fixture.defaults.set([session.path: "keep-board-id"], forKey: "FConversationBoardIDs")
fixture.defaults.set(["prompt text"], forKey: "FPromptHistory." + oldBoard.lastPathComponent + ".keep-board-id")
let embeddedSession = fixture.source.appendingPathComponent(".sessions/embedded.jsonl")
json(["type": "session", "id": "embedded", "cwd": fixture.source.path], embeddedSession)
let embeddedBoardID = ConversationBoards.id(for: embeddedSession.path, defaults: fixture.defaults)
var renameEnvironment = fixture.environment
renameEnvironment.additionalSessions = [embeddedSession]
let target = try! ProjectMutation.rename(fixture.source, name: "新 项目-中文", environment: renameEnvironment)
expect(!fm.fileExists(atPath: fixture.source.path) && fm.fileExists(atPath: target.path), "actual folder renamed")
let newBoard = BoardStore.directory(for: target)
expect(fm.fileExists(atPath: session.path), "central session physical path retained")
let afterSession = String(data: try! Data(contentsOf: session), encoding: .utf8)!
let sessionHeader = try! JSONSerialization.jsonObject(with: Data(afterSession.split(separator: "\n")[0].utf8)) as! [String: Any]
expect(sessionHeader["cwd"] as? String == target.path && sessionHeader["id"] as? String == "session-id", "session cwd moved but ID retained")
expect(afterSession.hasSuffix(message), "message bytes and historical path evidence unchanged")
expect(object(emptySession)["cwd"] as? String == target.appendingPathComponent("子目录").path, "empty/subproject session migrated")
expect(object(newBoard.appendingPathComponent("scene.json"))["project"] as? String == target.path, "scene project reference migrated")
expect((object(newBoard.appendingPathComponent("scene.json"))["elements"] as! [[String: Any]])[0]["text"] as? String == fixture.source.path, "scene user text not rewritten")
let newSubBoard = BoardStore.directory(for: target.appendingPathComponent("子目录"))
let restore = object(newSubBoard.appendingPathComponent("conversations/keep-board-id/interruptions/test.json"))
expect(restore["mainDraft"] as? String == "keep draft" && restore["model"] as? String == "keep-model" && restore["boardID"] as? String == "keep-board-id", "restore drafts/model/boardID preserved")
let newChild = newBoard.appendingPathComponent("conversations/keep-board-id/harness/subagents/child/child.jsonl")
expect(object(newChild)["cwd"] as? String == target.path, "durable child cwd migrated")
let childCatalog = try! JSONSerialization.jsonObject(with: Data(contentsOf: newChild.deletingLastPathComponent().appendingPathComponent("catalog.json"))) as! [[String: Any]]
expect(childCatalog[0]["sessionFile"] as? String == newChild.path, "child catalog points at relocated centralized session")
expect(!fm.fileExists(atPath: newBoard.appendingPathComponent("harness/leases/transaction.lock").path), "owned scene transaction lock released after move")
expect((try! Data(contentsOf: storage("fixture", target).appendingPathComponent("opaque.bin"))) == Data([0, 1, 255]), "project plugin binary preserved")
let tree = object(target.appendingPathComponent(".git/f-tree.json"))
let node = (tree["nodes"] as! [[String: Any]])[0]
expect(tree["enabled"] as? Bool == true && node["worktree"] as? String == target.path, "version enabled and root worktree synchronized")
expect((node["validation"] as! [String: Any])["text"] as? String == fixture.source.path, "version validation evidence unchanged")
expect(git(["-C", target.path, "rev-parse", "HEAD"]) == oid, "real git HEAD preserved after folder rename")
expect(git(["-C", target.path, "rev-parse", "refs/f/version-snapshots/fixture-major"]) == oid, "snapshot ref OID preserved after rename")
expect((tree["versions"] as! [[String: Any]])[0]["oid"] as? String == oid, "version metadata fixed OID retained")
expect((fixture.defaults.dictionary(forKey: "FConversationBoardIDs") as? [String: String])?[session.path] == "keep-board-id", "session board binding retained")
let movedEmbedded = target.appendingPathComponent(".sessions/embedded.jsonl")
expect(fm.fileExists(atPath: movedEmbedded.path) && ConversationBoards.id(for: movedEmbedded.path, defaults: fixture.defaults) == embeddedBoardID, "embedded session moves with folder but keeps old fallback boardID")
expect(fixture.defaults.stringArray(forKey: "FPromptHistory." + newBoard.lastPathComponent + ".keep-board-id") == ["prompt text"], "input history key migrated without changing content")
let resume = object(fixture.support.appendingPathComponent("updates/last-resume.json"))
expect(resume["project"] as? String == target.path && resume["boardID"] as? String == "keep-board-id", "restart snapshot references migrated")

// Every post-move boundary can roll back without losing original bytes/settings.
for failure in ["prepared", "moved", "written", "defaults"] {
    let f = Fixture("rollback-" + failure)
    let file = f.sessions.appendingPathComponent("s.jsonl")
    json(["type": "session", "id": "rollback", "cwd": f.source.path], file)
    let before = try! Data(contentsOf: file)
    f.defaults.set([f.source.path], forKey: "FProjectFolders")
    var env = f.environment
    env.checkpoint = { stage in if stage == failure { throw ProjectMutation.Failure(message: "injected " + stage) } }
    rejected({ _ = try ProjectMutation.rename(f.source, name: "new", environment: env) }, "injected \(failure) fails")
    expect(fm.fileExists(atPath: f.source.path) && !fm.fileExists(atPath: f.source.deletingLastPathComponent().appendingPathComponent("new").path), "\(failure) folder rollback")
    expect((try! Data(contentsOf: file)) == before, "\(failure) exact session rollback")
    expect(f.defaults.stringArray(forKey: "FProjectFolders") == [f.source.path], "\(failure) defaults rollback")
    let journal = try! fm.contentsOfDirectory(at: f.support.appendingPathComponent("project-mutations"), includingPropertiesForKeys: nil)[0].appendingPathComponent("journal.json")
    expect(object(journal)["phase"] as? String == "rolledBack", "\(failure) rollback is durably recorded")
}

let safety = Fixture("safety")
let occupied = safety.root.appendingPathComponent("occupied"); mkdir(occupied)
rejected({ _ = try ProjectMutation.rename(safety.source, name: "occupied", environment: safety.environment) }, "existing folder refused")
for bad in ["", ".", "..", "a/b", "a:b", " leading", "trailing "] {
    rejected({ _ = try ProjectMutation.validate(safety.source, name: bad, environment: safety.environment) }, "invalid name \(bad) refused")
}
var protected = safety.environment; protected.protectedRoots = [safety.source.appendingPathComponent("running-F")]
rejected({ _ = try ProjectMutation.validate(safety.source, name: "new", environment: protected) }, "current F ancestor refused")
let gitSafety = safety.source.appendingPathComponent(".git")
mkdir(gitSafety)
try! Data().write(to: gitSafety.appendingPathComponent("f-tree-operation.lock"))
rejected({ _ = try ProjectMutation.validate(safety.source, name: "new", environment: safety.environment) }, "operation lock refused")
expect(fm.fileExists(atPath: gitSafety.appendingPathComponent("f-tree-operation.lock").path), "operation lock untouched")
try! fm.removeItem(at: gitSafety.appendingPathComponent("f-tree-operation.lock"))
mkdir(gitSafety.appendingPathComponent("worktrees/child"))
rejected({ _ = try ProjectMutation.validate(safety.source, name: "new", environment: safety.environment) }, "registered git worktree refused")
try! fm.removeItem(at: gitSafety)
try! Data("gitdir: elsewhere\n".utf8).write(to: gitSafety)
rejected({ _ = try ProjectMutation.validate(safety.source, name: "new", environment: safety.environment) }, "linked git worktree refused")
try! fm.removeItem(at: gitSafety)
let remote = RemoteProject(connection: SSHConnection(host: "fixture.invalid"), endpoint: "u@fixture.invalid:22", path: "/remote/project")
try! JSONEncoder().encode(remote).write(to: safety.source.appendingPathComponent("remote-project.json"))
let remoteBefore = try! Data(contentsOf: safety.source.appendingPathComponent("remote-project.json"))
rejected({ _ = try ProjectMutation.rename(safety.source, name: "new", environment: safety.environment) }, "SSH proxy descriptor refused without connecting")
expect((try! Data(contentsOf: safety.source.appendingPathComponent("remote-project.json"))) == remoteBefore, "SSH proxy descriptor left intact")
try! fm.removeItem(at: safety.source.appendingPathComponent("remote-project.json"))
let alias = safety.root.appendingPathComponent("alias")
try! fm.createSymbolicLink(at: alias, withDestinationURL: safety.source)
rejected({ _ = try ProjectMutation.validate(alias, name: "new", environment: safety.environment) }, "symlink project refused")

// Real AppKit conversation objects: relocation must not reset the private recovery identity/draft/model.
let view = ConversationView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
view.prepareProject(safety.source, boardID: "abc-def", session: session.path)
var saved = UpdateResume(id: "abc", project: safety.source.path, session: session.path, mainDraft: "中文 draft", provider: "test", model: "model", modelName: "name", thinking: "high", announcement: "", boardID: "abc-def")
view.restoreUpdate(saved)
expect(!view.blocksProjectMutation, "cold unrelated model/session restore has no live RPC")
view.relocateProject(from: safety.source, to: safety.root.appendingPathComponent("relocated"))
let after = view.updateResume(id: "abc", announcement: "")
expect(after.mainDraft == saved.mainDraft && after.model == saved.model && after.thinking == saved.thinking && after.boardID == saved.boardID && after.session == saved.session, "in-memory model/draft/session/boardID preserved")
saved.interruption = ConversationInterruption(updateID: "abc", prompt: nil, promptWasSent: false, promptCompleted: false, queue: [QueuedPrompt(id: 0, text: "paused", isWhiteboard: false)], queuePaused: true)
view.restoreUpdate(saved)
expect(view.blocksProjectMutation, "paused queue prevents relocation")
expect(!ProjectMutation.contains(safety.source.path + "-other", in: safety.source.path), "path boundary does not block similarly named unrelated project")
// Destination data and historical identity conflicts never overwrite or merge an old project.
for kind in ["board", "plugin", "history", "version-worktree", "board-lock", "resource-lease"] {
    let f = Fixture("conflict-" + kind)
    let destination = f.root.appendingPathComponent("new")
    if kind == "board" { mkdir(BoardStore.directory(for: destination)) }
    if kind == "plugin" {
        let hash = SHA256.hash(data: Data(destination.path.utf8)).map { String(format: "%02x", $0) }.joined()
        mkdir(f.support.appendingPathComponent("applications/fixture/" + hash))
    }
    if kind == "history" { json(["type": "session", "id": "other", "cwd": destination.path], f.sessions.appendingPathComponent("other.jsonl")) }
    if kind == "version-worktree" {
        let hash = SHA256.hash(data: Data(f.source.path.utf8)).map { String(format: "%02x", $0) }.joined()
        mkdir(f.support.appendingPathComponent("applications/versions/" + hash + "/worktrees/child"))
    }
    var leaseFile: URL?
    if kind == "resource-lease" {
        leaseFile = BoardStore.directory(for: f.source).appendingPathComponent("harness/leases/leases.json")
        json(["version": 1, "leases": [["owner": "other", "paths": [f.source.path]]], "pins": []], leaseFile!)
    }
    var foreignLock: URL?
    if kind == "board-lock" {
        foreignLock = try! ProjectSceneWriter.acquireLock(for: BoardStore.directory(for: f.source).appendingPathComponent("scene.json"))
    }
    rejected({ _ = try ProjectMutation.rename(f.source, name: "new", environment: f.environment) }, "\(kind) conflict refused")
    expect(fm.fileExists(atPath: f.source.path) && !fm.fileExists(atPath: destination.path), "\(kind) original project retained")
    if let foreignLock { expect(fm.fileExists(atPath: foreignLock.path), "foreign board lock untouched"); ProjectSceneWriter.releaseLock(foreignLock) }
    if let leaseFile { expect((object(leaseFile)["leases"] as! [[String: Any]])[0]["owner"] as? String == "other", "foreign resource lease retained") }
}

for kind in ["readonly", "hardlink"] {
    let f = Fixture("file-boundary-" + kind)
    let file = f.sessions.appendingPathComponent("protected.jsonl")
    json(["type": "session", "id": "protected", "cwd": f.source.path], file)
    let before = try! Data(contentsOf: file)
    if kind == "readonly" { try! fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path) }
    else { try! fm.linkItem(at: file, to: f.sessions.appendingPathComponent("same-inode.jsonl")) }
    rejected({ _ = try ProjectMutation.rename(f.source, name: "new", environment: f.environment) }, "\(kind) session refused rather than bypass protection")
    expect((try! Data(contentsOf: file)) == before && fm.fileExists(atPath: f.source.path), "\(kind) file and folder intact")
}

// A live short-lived fake RPC is allowed to exit naturally; never call stop/kill to pass the gate.
let started = ConversationView(frame: .zero)
started.prepareProject(safety.source, boardID: "aaa-bbb")
started.beginFreshProject(safety.source)
expect(started.blocksProjectMutation && started.hasPendingWork, "RPC startup is included in idle gate")
let rpcDeadline = Date().addingTimeInterval(4)
while started.blocksProjectMutation && Date() < rpcDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
expect(!started.blocksProjectMutation, "naturally exited fake RPC releases gate without kill")

// Window-wide gates are project-specific: another project's live publisher must not block Rename.
UserDefaults.standard.set(["ssh", "whiteboard", "versions"], forKey: PluginPreferences.disabledKey)
let host = RootView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
let secondHost = RootView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
host.conversationView.prepareProject(safety.source, boardID: "aaa-ccc")
secondHost.conversationView.prepareProject(fixture.root, boardID: "aaa-ddd")
host.conversationView.beginFreshProject(safety.source)
expect(secondHost.projectMutationBlockReason(safety.source) != nil, "other window sees target startup/RPC blocker")
expect(secondHost.projectMutationBlockReason(fixture.root) == nil, "unrelated live publisher does not block historical project")
let hostDeadline = Date().addingTimeInterval(4)
while host.conversationView.blocksProjectMutation && Date() < hostDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
expect(secondHost.projectMutationBlockReason(safety.source) == nil, "target gate clears after natural backend exit")

// Real PTY lifetime: it ends itself; the host never kills it for a folder mutation.
let registry = PluginRegistry()
registry.register(TerminalPlugin(project: safety.source))
let dock = BottomPluginHost(registry: registry, project: safety.source)
let process = dock.createProcess("terminal")!
let terminal = (process.plugin as! TerminalPlugin).terminal
terminal.startCommand("/bin/sh", arguments: ["-c", "sleep 0.2"], in: safety.source)
expect(terminal.isRunning && dock.blocksProjectMutation(safety.source), "live target PTY blocks migration")
expect(!dock.blocksProjectMutation(fixture.root), "unrelated project is not blocked by target PTY")
let ptyDeadline = Date().addingTimeInterval(4)
while terminal.isRunning && Date() < ptyDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
expect(!terminal.isRunning, "test PTY exited naturally")
// Registry lifetime queries cover standalone RPCs and child cwd, without stopping anything.
let independent = Fixture("registry-independent")
let independentSession = independent.sessions.appendingPathComponent("s.jsonl")
json(["type": "session", "id": "independent", "cwd": independent.source.path], independentSession)
json(["session": independentSession.path], independent.source.appendingPathComponent(".mutation-rpc.json"))
let independentRPC = PiRPC()
expect(independentRPC.start(cliPath: PiPaths.cliPath!, workingDirectory: independent.source), "independent fake RPC starts")
expect(!PiRPC.hasRunningAgent(inProject: safety.source) && secondHost.projectMutationBlockReason(safety.source) == nil, "unrelated standalone RPC does not block target Rename")
var independentClosed = 0
independentRPC.closeInputAndWaitForRelocation { result in
    if case .success = result { independentClosed += 1 } else { expect(false, "independent RPC natural exit") }
}
waitFor("unrelated fake exits without signal") { independentClosed == 1 }

let registryFixture = Fixture("registry-child")
let childCwd = registryFixture.source.appendingPathComponent("nested"); mkdir(childCwd)
let registrySession = registryFixture.sessions.appendingPathComponent("s.jsonl")
json(["type": "session", "id": "registry", "cwd": childCwd.path], registrySession)
json(["session": registrySession.path, "exitDelay": 0.1], childCwd.appendingPathComponent(".mutation-rpc.json"))
let standalone = PiRPC()
expect(standalone.start(cliPath: PiPaths.cliPath!, workingDirectory: childCwd), "nested standalone RPC starts")
expect(PiRPC.hasRunningAgent(inProject: registryFixture.source), "target descendant cwd is included by registry query")
expect(secondHost.projectMutationBlockReason(registryFixture.source) != nil, "Root consults standalone registry blocker")
expect(!PiRPC.hasRunningAgent(inProject: URL(fileURLWithPath: registryFixture.source.path + "-other")), "registry query observes directory boundary")
var standaloneClosed = 0, duplicateClosed = 0
standalone.closeInputAndWaitForRelocation(timeout: 1) { result in
    if case .success = result { standaloneClosed += 1 } else { expect(false, "standalone graceful close") }
}
standalone.closeInputAndWaitForRelocation(timeout: 1) { result in
    if case .failure = result { duplicateClosed += 1 } else { expect(false, "duplicate close must refuse") }
}
waitFor("one natural-exit callback") { standaloneClosed == 1 }
RunLoop.main.run(until: Date().addingTimeInterval(1.05))
expect(standaloneClosed == 1 && duplicateClosed == 1, "timeout and exit cannot repeat completion")
expect(!rpcEvents(childCwd).contains { $0["event"] as? String == "signal" }, "graceful close never sends terminate/HUP")
expect(!PiRPC.hasRunningAgent(inProject: registryFixture.source), "registry lifetime clears on actual exit")

// No RPC is needed to block migration: a paused queue in another window still owns the project.
var pausedState = UpdateResume(id: "abc", project: fixture.root.path, session: nil, mainDraft: "paused draft", announcement: "", boardID: "aaa-ddd")
pausedState.interruption = ConversationInterruption(updateID: "abc", prompt: nil, promptWasSent: false, promptCompleted: false,
    queue: [QueuedPrompt(id: 1, text: "keep queued", isWhiteboard: false)], queuePaused: true)
secondHost.conversationView.restoreUpdate(pausedState)
expect(!PiRPC.hasRunningAgent(inProject: fixture.root) && host.projectMutationBlockReason(fixture.root) != nil, "cross-window queue blocks without live RPC")
var pausedRefused = 0
host.closeIdleProjectConversations(fixture.root) { result in if case .failure = result { pausedRefused += 1 } }
expect(pausedRefused == 1 && secondHost.conversationView.hasPendingWork, "busy/paused project cannot close any input")
pausedState.interruption = nil
secondHost.conversationView.restoreUpdate(pausedState)

// Real live ConversationView snapshot, busy refusal, cross-window close and same-session rebind.
let idleFixture = Fixture("idle-close")
let idleSession = idleFixture.sessions.appendingPathComponent("s.jsonl")
json(["type": "session", "id": "idle", "cwd": idleFixture.source.path], idleSession)
json(["session": idleSession.path, "exitDelay": 0.1], idleFixture.source.appendingPathComponent(".mutation-rpc.json"))
let idleView = host.conversationView
var idleState = UpdateResume(id: "abc", project: idleFixture.source.path, session: idleSession.path,
    mainDraft: "中文原草稿", provider: "test", model: "model", modelName: "name", thinking: "high", announcement: "", boardID: "abc-123")
idleView.prepareProject(idleFixture.source, boardID: "abc-123", session: idleSession.path)
idleView.restoreUpdate(idleState)
idleView.show(PiChat(id: "idle", title: "idle", date: Date(), path: idleSession, cwd: idleFixture.source.path))
waitFor("live view becomes strictly idle") { idleView.hasRunningAgentForProjectMutation && idleView.canCloseIdleAgentForProjectMutation }
idleState.interruption = ConversationInterruption(updateID: "abc", prompt: nil, promptWasSent: false, promptCompleted: false,
    queue: [QueuedPrompt(id: 2, text: "busy queue", isWhiteboard: false)], queuePaused: true)
idleView.restoreUpdate(idleState)
var busyRefused = 0
secondHost.closeIdleProjectConversations(idleFixture.source) { result in if case .failure = result { busyRefused += 1 } }
expect(busyRefused == 1 && PiRPC.hasRunningAgent(inProject: idleFixture.source), "busy live RPC remains running")
expect(!rpcEvents(idleFixture.source).contains { $0["event"] as? String == "stdin-end" }, "busy refusal does not close stdin")
idleState.interruption = nil
idleView.restoreUpdate(idleState)
var idleClosed = 0, idleDuplicate = 0
secondHost.closeIdleProjectConversations(idleFixture.source) { result in
    if case .success = result { idleClosed += 1 } else { expect(false, "idle owned session must close safely") }
}
secondHost.closeIdleProjectConversations(idleFixture.source) { result in if case .failure = result { idleDuplicate += 1 } }
waitFor("cross-window idle session naturally exits") { idleClosed == 1 }
let rebound = idleView.updateResume(id: "abc", announcement: "")
expect(idleDuplicate == 1 && rebound.session == idleSession.path && rebound.mainDraft == idleState.mainDraft && rebound.model == idleState.model && rebound.boardID == idleState.boardID,
       "natural close rebinds original session and preserves model/draft/boardID")
let diskSnapshot = object(idleView.conversationDirectory.appendingPathComponent("interruptions/relocation-idle.json"))
expect(diskSnapshot["session"] as? String == idleSession.path && diskSnapshot["mainDraft"] as? String == "中文原草稿", "snapshot is durable before EOF")
expect(secondHost.projectMutationBlockReason(idleFixture.source) == nil, "graceful close provides an actionable path to Rename")

// Timeout is NOT success: keep snapshot and process; a late real exit is handled once.
let timeoutFixture = Fixture("idle-timeout")
let timeoutSession = timeoutFixture.sessions.appendingPathComponent("s.jsonl")
json(["type": "session", "id": "timeout", "cwd": timeoutFixture.source.path], timeoutSession)
json(["session": timeoutSession.path, "exitDelay": 0.6], timeoutFixture.source.appendingPathComponent(".mutation-rpc.json"))
let timeoutView = ConversationView(frame: .zero)
let timeoutState = UpdateResume(id: "abc", project: timeoutFixture.source.path, session: timeoutSession.path,
    mainDraft: "超时前草稿", provider: "test", model: "model", modelName: "name", thinking: "high", announcement: "", boardID: "abc-456")
timeoutView.prepareProject(timeoutFixture.source, boardID: "abc-456", session: timeoutSession.path)
timeoutView.restoreUpdate(timeoutState)
timeoutView.show(PiChat(id: "timeout", title: "timeout", date: Date(), path: timeoutSession, cwd: timeoutFixture.source.path))
waitFor("timeout fixture becomes idle") { timeoutView.hasRunningAgentForProjectMutation && timeoutView.canCloseIdleAgentForProjectMutation }
var timeoutCallbacks = 0
timeoutView.closeIdleAgentForProjectMutation(timeout: 0.02) { result in
    timeoutCallbacks += 1
    if case .success = result { expect(false, "timeout must not report closed") }
}
waitFor("close timeout reports failure") { timeoutCallbacks == 1 }
expect(timeoutView.hasRunningAgentForProjectMutation && timeoutView.hasPendingWork, "timeout leaves real process and checkpoint intact")
timeoutView.askWhiteboard("超时中新输入")
expect(timeoutView.updateResume(id: "abc", announcement: "").mainDraft.contains("超时前草稿"), "timeout cannot discard original draft")
waitFor("late actual exit releases checkpoint") { !timeoutView.blocksProjectMutation }
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
let timeoutAfter = timeoutView.updateResume(id: "abc", announcement: "")
expect(timeoutCallbacks == 1 && timeoutAfter.session == timeoutState.session && timeoutAfter.model == timeoutState.model && timeoutAfter.boardID == timeoutState.boardID,
       "late exit does not duplicate callback or replace private identity")
expect(timeoutAfter.mainDraft.contains("超时中新输入") && !rpcEvents(timeoutFixture.source).contains { $0["event"] as? String == "signal" }, "late exit preserves new input and receives no termination signal")

// Preference/startup/restore/project-switch are not repository opt-in; only the explicit entry activates.
let versionsFixture = Fixture("versions-preference")
ProjectStore.remember(versionsFixture.source)
let versionsHost = RootView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
let versions = versionsHost.plugins.plugin("versions")!
versionsHost.requestPluginEnabled("versions", true)
expect(versionsHost.plugins.isEnabled("versions") && versions.view.isHidden, "global enable does not show/activate Versions")
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
expect(!fm.fileExists(atPath: versionsFixture.source.appendingPathComponent(".git").path), "global plugin preference grants no repository consent")
let startupHost = RootView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
expect(startupHost.plugins.plugin("versions")!.view.isHidden, "startup defaults do not activate enabled Versions")
let restoredProject = versionsFixture.root.appendingPathComponent("restored"); mkdir(restoredProject)
startupHost.restoreAfterUpdate(UpdateResume(id: "abc", project: restoredProject.path, session: nil, mainDraft: "restore", announcement: "", boardID: "aaa-123"))
let startupVersions = startupHost.plugins.plugin("versions")!
expect(startupVersions.view.isHidden && !fm.fileExists(atPath: restoredProject.appendingPathComponent(".git").path), "startup restore/project change does not activate Versions")
startupHost.performApplicationCommand("versions", command: "enable")
expect(startupVersions.view.isHidden, "retired command cannot implicitly authorize repository")
startupHost.performApplicationCommand("versions", command: "open")
expect(!startupVersions.view.isHidden, "explicit Versions entry still activates and opens view")
let switchedProject = versionsFixture.root.appendingPathComponent("switched"); mkdir(switchedProject)
startupHost.restoreAfterUpdate(UpdateResume(id: "abc", project: switchedProject.path, session: nil, announcement: "", boardID: "aaa-456"))
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
expect(startupVersions.view.isHidden && !fm.fileExists(atPath: switchedProject.appendingPathComponent(".git").path), "switching from Versions does not activate new project")

cleanupDefaults()
print("PASS project-mutation: \(assertions) assertions; real AppKit, isolated sessions/storage, no model or F build")
exit(0)
