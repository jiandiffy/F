import AppKit

final class SSHConfigEditor: NSObject, NSWindowDelegate {
    private var editorWindow: NSWindow?
    private let editor = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private var original = Data()
    var hasUnsavedChanges: Bool { Data(editor.string.utf8) != original }

    func show(relativeTo parent: NSWindow?) {
        if let window = editorWindow { window.makeKeyAndOrderFront(nil); return }
        let url = SSHConfig.url
        original = (try? Data(contentsOf: url)) ?? Data()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "SSH config"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: window.contentLayoutRect)
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 44, width: 616, height: 404))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        editor.isRichText = false; editor.drawsBackground = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textColor = .labelColor; editor.insertionPointColor = .labelColor
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.string = String(data: original, encoding: .utf8) ?? ""
        scroll.documentView = editor; content.addSubview(scroll)
        let save = NSButton(title: "保存", target: self, action: #selector(saveConfig))
        save.isBordered = false; save.contentTintColor = .labelColor
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        save.frame = NSRect(x: 568, y: 10, width: 60, height: 25)
        save.autoresizingMask = [.minXMargin]
        content.addSubview(save)
        status.frame = NSRect(x: 16, y: 15, width: 540, height: 18)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle; status.autoresizingMask = [.width]
        status.stringValue = url.path; content.addSubview(status)
        window.contentView = content
        window.center(); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        editorWindow = window
    }
    @objc private func saveConfig() {
        do {
            let url = SSHConfig.url
            guard ((try? Data(contentsOf: url)) ?? Data()) == original else { throw SSHFailure.message("config 已被其他程序修改，请关闭后重新打开。") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600
            let data = Data(editor.string.utf8)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            original = data
            status.stringValue = "已保存 · " + url.path
        } catch { status.stringValue = error.localizedDescription; status.toolTip = error.localizedDescription }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedChanges else { return true }
        confirmClose { allowed in if allowed { sender.close() } }
        return false
    }
    func confirmClose(_ completion: @escaping (Bool) -> Void) {
        guard hasUnsavedChanges, let editorWindow else { completion(true); return }
        let alert = NSAlert()
        alert.messageText = "config 尚未保存"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "放弃编辑")
        alert.icon = NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: nil)
        alert.buttons.forEach { $0.isBordered = false; $0.contentTintColor = .labelColor }
        editorWindow.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: editorWindow) { response in completion(response == .alertSecondButtonReturn) }
    }
    func windowWillClose(_ notification: Notification) { editorWindow = nil }
}
