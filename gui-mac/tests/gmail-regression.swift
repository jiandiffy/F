let testApp = NSApplication.shared
testApp.setActivationPolicy(.prohibited)
func gmailCheck(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fputs("Gmail native failure: \(description)\n", stderr); exit(1) }
}
let suite = "local.f.gmail.test." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defaults.set(["gmail"], forKey: PluginPreferences.disabledKey)
let registry = PluginRegistry(defaults: defaults), mailbox = GmailPlugin()
registry.register(mailbox)
gmailCheck(registry.applicationPlugins.isEmpty, "disabled mailbox has no application entry")
registry.setEnabled("gmail", true)
gmailCheck(registry.applicationPlugins.map(\.id) == ["gmail"], "enabled mailbox appears")
gmailCheck(mailbox.projectAssociation == .independent, "mailbox is account-wide")
gmailCheck(mailbox.menuCommands.map(\.id).contains("settings"), "OAuth settings use application menu")
gmailCheck(mailbox.menuCommands.map(\.id).contains("compose"), "compose command available")
gmailCheck(!mailbox.hasPendingWork, "mounting does not contact Google or read credentials")
registry.projectDidChange(URL(fileURLWithPath: "/tmp/f-gmail-isolated-project"))
registry.applyAppearance(dark: true); registry.applyAppearance(dark: false)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = mailbox.view; window.contentView?.layoutSubtreeIfNeeded()
gmailCheck(mailbox.view.fittingSize.width > 300, "mailbox layout contains list and reader")
func mailDescendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(mailDescendants) }
for size in [NSSize(width: 340, height: 520), NSSize(width: 520, height: 600), NSSize(width: 850, height: 600)] {
    window.setContentSize(size); mailbox.view.needsLayout = true; mailbox.view.layoutSubtreeIfNeeded()
    let views = mailDescendants(mailbox.view)
    let split = views.compactMap { $0 as? NSSplitView }.first!
    gmailCheck(split.isVertical == (size.width >= 560), "narrow mailbox stacks list and reader")
    gmailCheck(views.compactMap { $0 as? NSScrollView }.allSatisfy { !$0.drawsBackground && !$0.contentView.drawsBackground }, "list and reader share the transparent conversation backdrop")
    gmailCheck(views.compactMap { $0 as? NSTextView }.allSatisfy { !$0.drawsBackground }, "mail body does not introduce a separate background")
    let visibleActions = views.compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.title)
    gmailCheck(!visibleActions.contains("归档") && !visibleActions.contains("回复") && !visibleActions.contains("加载更多"), "contextual actions stay hidden until needed")
    if let output = ProcessInfo.processInfo.environment["F_UI_PREVIEW_DIR"] {
        for dark in [false, true] {
            mailbox.applyAppearance(dark: dark)
            mailbox.view.wantsLayer = true; mailbox.view.layer?.backgroundColor = (dark ? NSColor.black : NSColor.white).cgColor
            mailbox.view.layoutSubtreeIfNeeded()
            if let bitmap = mailbox.view.bitmapImageRepForCachingDisplay(in: mailbox.view.bounds) {
                mailbox.view.cacheDisplay(in: mailbox.view.bounds, to: bitmap)
                let directory = URL(fileURLWithPath: output)
                try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("gmail-\(Int(size.width))-\(dark ? "dark" : "light").png"))
            }
            mailbox.view.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
let draft: [String: Any] = ["to":"alice@example.com", "cc":"cc@example.com", "bcc":"hidden@example.com", "subject":"中文主题", "body":"第一行\n第二行"]
let composer = GmailComposeWindow(draft: draft)
var dispatched: [String: Any]?, action: String?
composer.onSend = { values, verb in dispatched = values; action = verb }
composer.sendButton.performClick(nil)
gmailCheck(action == "send", "new message sends explicitly")
gmailCheck(dispatched?["body"] as? String == "第一行\n第二行", "Unicode draft body preserved")
gmailCheck(dispatched?["bcc"] as? String == "hidden@example.com", "bcc preserved")
gmailCheck(!composer.isOpaque && !composer.body.drawsBackground && !composer.to.drawsBackground, "compose uses the same conversation backdrop")
composer.setBusy(true)
gmailCheck(!composer.body.isEditable && !composer.to.isEnabled && !composer.sendButton.isEnabled, "pending send protects draft from concurrent edits")
composer.setBusy(false)
gmailCheck(composer.body.isEditable && composer.sendButton.isEnabled, "failed send can recover composer")
let reply = GmailComposeWindow(draft: draft.merging(["replyToId":"abc123"]) { _, new in new })
gmailCheck(!reply.to.isEditable && !reply.subject.isEditable, "reply recipient and subject follow original thread")
reply.onSend = { values, verb in dispatched = values; action = verb }; reply.sendButton.performClick(nil)
gmailCheck(action == "reply" && dispatched?["replyToId"] as? String == "abc123", "reply preserves source id")
registry.setEnabled("gmail", false)
gmailCheck(!registry.isEnabled("gmail") && registry.applicationPlugins.isEmpty, "disable persists and removes entry")
gmailCheck(PluginPreferences.disabledIDs(in: defaults).contains("gmail"), "disabled preference persisted")
registry.setEnabled("gmail", true)
gmailCheck(registry.applicationPlugins.count == 1 && !mailbox.hasPendingWork, "re-enable is idempotent and offline")
registry.shutdown(); composer.close(); reply.close(); window.close()
defaults.removePersistentDomain(forName: suite)
print("Gmail native UI, menus, plugin lifecycle, independent account scope and Unicode compose passed")
exit(0)
