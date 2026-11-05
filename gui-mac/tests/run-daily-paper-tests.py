#!/usr/bin/env python3
"""Isolated Daily Paper host/queue tests. No model, Gmail or user storage access."""
from pathlib import Path
import os
import plistlib
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
plugin_tests = root / 'Plugins/DailyPaper/run-tests.py'
if not plugin_tests.is_file():
    raise SystemExit('Daily Paper data/OAuth/sync regression runner is missing')
subprocess.run(['/usr/bin/python3', str(plugin_tests)], check=True)
source = (root / 'main.swift').read_text().split('\nlet app = NSApplication.shared\n')[0]
source += '\n' + '\n'.join(p.read_text() for folder in ['Core', 'Plugins'] for p in sorted((root / folder).rglob('*.swift')))
# Redirect application-owned storage, not just boards. Never construct a test plugin on user data.
original = 'return base.appendingPathComponent("F", isDirectory: true)'
assert source.count(original) == 1
source = source.replace(original, 'return URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_PAPER_TEST_ROOT"]!).appendingPathComponent("support")')
tests = r'''
func check(_ value: @autoclosure () -> Bool, _ reason: String) {
    guard value() else { fputs("FAIL: \(reason)\n", stderr); exit(1) }
}
extension ConversationView {
    func holdForPaperTest(draft: String = "用户未发送的草稿") { busy = true; composer.draftText = draft }
    var paperQueueForTest: [QueuedPrompt] { queue }
    var draftForPaperTest: String { composer.draftText }
    func attachReplyForTest(_ item: QueuedPrompt, _ reply: String) {
        activePrompt = item
        recordDailyPaperOverview(reply)
    }
    func pausedForPaperTest() { busy = false; queuePaused = true }
    var pauseKeptForPaperTest: Bool { queuePaused && !starting && activeTurnID == nil }
    func stopForPaperTest() { busy = false; queue.removeAll(); activePrompt = nil }
}
extension RootView {
    func paperHostChecks(_ a: DailyPaperRecord, _ b: DailyPaperRecord, project: URL) {
        activeConversation.prepareProject(project, boardID: UUID().uuidString.lowercased())
        activeConversation.holdForPaperTest()
        bottomOpen = true
        showApplication("daily-paper")
        check(mode == .application("daily-paper"), "Daily Paper workspace opens")
        check(whiteboardView.isHidden && activeConversation.isHidden, "Daily Paper hides both floating composers")
        check(bottomOpen, "opening Daily Paper does not close the dock")
        let plugin = plugins.plugin("daily-paper") as! DailyPaperPlugin
        plugin.onOpenPaper?(a)
        check(mode == .conversation && !activeConversation.isHidden, "card click opens main conversation")
        check(activeConversation.paperQueueForTest.count == 1, "card request joins existing queue")
        check(activeConversation.draftForPaperTest == "用户未发送的草稿", "card does not replace draft")
        check(sideAgentContext().contains(a.title), "side agent sees selected paper")
        showApplication("daily-paper")
        plugin.onOpenPaper?(b)
        check(sideAgentContext().contains(b.title) && !sideAgentContext().contains(a.title), "each request refreshes selected paper")
        showApplication("whiteboard")
        check(!whiteboardView.isHidden, "leaving Daily Paper restores whiteboard composer")
        plugins.setEnabled("daily-paper", false)
        check(sideAgentContext().isEmpty, "disabled plugin does not inject paper context")
        activeConversation.stopForPaperTest()
        shutdownPlugins()
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let rootURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_PAPER_TEST_ROOT"]!)
let project = rootURL.appendingPathComponent("project")
let otherProject = rootURL.appendingPathComponent("other-project")
try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: otherProject, withIntermediateDirectories: true)
BoardStore.setRoot(rootURL.appendingPathComponent("boards"))
UserDefaults.standard.set(["ssh"], forKey: PluginPreferences.disabledKey)
ProjectStore.remember(project)
let a = DailyPaperRecord(id: "arxiv:2610.28480", title: "PAPER_A_UNIQUE", authors: ["Author A"], abstract: "Original abstract A", sourceURLs: [URL(string: "https://arxiv.org/abs/2610.28480v1")!], versions: ["v1"])
let b = DailyPaperRecord(id: "arxiv:2305.14627", title: "PAPER_B_UNIQUE", authors: ["Author B"], abstract: "Original abstract B", sourceURLs: [URL(string: "https://arxiv.org/abs/2305.14627v2")!], versions: ["v2"])
let boardA = UUID().uuidString.lowercased()
let view = ConversationView(frame: .zero)
view.prepareProject(project, boardID: boardA)
view.holdForPaperTest()
check(view.askDailyPaper(a), "paper A accepted")
let requestA = view.paperQueueForTest[0]
check(requestA.text.contains("忠实中文翻译") && requestA.text.contains("仅基于摘要"), "reading prompt asks faithful translation with evidence downgrade")
check(requestA.text.contains("alphaXiv") && requestA.text.contains("视频演示"), "reading prompt requests sourced web and media research")
check(view.askDailyPaper(b), "paper B accepted")
check(view.paperQueueForTest.count == 2, "rapid selection keeps both queued requests")
view.attachReplyForTest(requestA, "STALE_A_OVERVIEW")
check(!view.dailyPaperContext.contains("STALE_A_OVERVIEW"), "late result cannot overwrite current paper")
let requestB = view.paperQueueForTest[1]
view.attachReplyForTest(requestB, "B中文摘要及证据 https://arxiv.org/abs/2305.14627v2")
check(view.dailyPaperContext.contains("B中文摘要及证据"), "matching result becomes reading history")
check(view.dailyPaperContext.contains("不可信参考资料"), "external reference trust boundary is explicit")
let restored = ConversationView(frame: .zero)
restored.prepareProject(project, boardID: boardA)
check(restored.dailyPaperContext.contains("PAPER_B_UNIQUE") && restored.dailyPaperContext.contains("B中文摘要及证据"), "restart restores paper and reading history")
let sibling = ConversationView(frame: .zero)
sibling.prepareProject(project, boardID: UUID().uuidString.lowercased())
check(sibling.dailyPaperContext.isEmpty, "same project different conversation is isolated")
restored.prepareProject(otherProject, boardID: UUID().uuidString.lowercased())
check(restored.dailyPaperContext.isEmpty, "project switch clears paper context")
let paused = ConversationView(frame: .zero)
paused.prepareProject(project, boardID: UUID().uuidString.lowercased())
paused.pausedForPaperTest()
check(paused.askDailyPaper(a) && paused.paperQueueForTest.count == 1 && paused.pauseKeptForPaperTest, "card respects manual pause even with empty queue")
let failed = ConversationView(frame: .zero)
failed.prepareProject(project, boardID: UUID().uuidString.lowercased())
let directory = failed.conversationDirectory
try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("not a directory".utf8).write(to: directory)
failed.holdForPaperTest()
check(!failed.askDailyPaper(a) && failed.paperQueueForTest.isEmpty && failed.dailyPaperContext.isEmpty, "save failure does not queue or mutate selection")
let host = RootView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
host.paperHostChecks(a, b, project: project)
view.stopForPaperTest(); paused.stopForPaperTest(); failed.stopForPaperTest()
print("PASS: Daily Paper host, preserved queue/draft/pause, generation guard, restore, isolation, storage failure and UI routing")
print("NOT RUN: real Gmail consent/sync and paid paper overview model calls; these tests use isolated records only")
exit(0)
'''
with tempfile.TemporaryDirectory(prefix='f-daily-paper-host-') as directory:
    work = Path(directory)
    bundle = work / 'PaperTests.app/Contents'
    (bundle / 'MacOS').mkdir(parents=True)
    (bundle / 'Resources').symlink_to(root / 'Resources', target_is_directory=True)
    agent = work / 'agent'
    (agent / 'sessions').mkdir(parents=True)
    (agent / 'settings.json').write_text('{}')
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'local.f.daily-paper-tests.' + uuid.uuid4().hex,
        'CFBundleExecutable': 'PaperTests', 'CFBundlePackageType': 'APPL', 'PiAgentDir': str(agent),
    }))
    swift = work / 'main.swift'
    swift.write_text(source + '\n' + tests)
    binary = bundle / 'MacOS/PaperTests'
    subprocess.run(['swiftc', '-O', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=40, env=dict(os.environ, F_PAPER_TEST_ROOT=str(work)))
