import AppKit

final class RemoteFolderPicker: NSObject {
    private let session: SSHSession
    private let alert = NSAlert()
    private let path = NSTextField(string: "")
    private let back = NSButton()
    private let scroll = NSScrollView()
    private let list = FileListDocumentView()
    private let status = NSTextField(labelWithString: "")
    private var directory = "/"
    private var revision = 0
    private var chosen: ((String) -> Void)?

    init(session: SSHSession) { self.session = session; super.init() }
    func show(in window: NSWindow, initialPath: String? = nil, completion: @escaping (String) -> Void) {
        chosen = completion
        alert.messageText = "选择远程项目文件夹"
        alert.informativeText = session.connection.address
        alert.icon = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        alert.addButton(withTitle: "选择此文件夹"); alert.addButton(withTitle: "取消")
        alert.buttons.forEach { $0.isBordered = false; $0.contentTintColor = .labelColor }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 310))
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor.white.cgColor
        path.frame = NSRect(x: 30, y: 282, width: 365, height: 24)
        path.isBordered = false; path.drawsBackground = false; path.focusRingType = .none
        path.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        path.target = self; path.action = #selector(openPath)
        path.setAccessibilityLabel("远程项目文件夹路径")
        view.addSubview(path)
        back.frame = NSRect(x: 0, y: 282, width: 24, height: 24)
        back.isBordered = false; back.contentTintColor = .secondaryLabelColor
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "上一级")
        back.target = self; back.action = #selector(goBack)
        view.addSubview(back)
        scroll.frame = NSRect(x: 0, y: 22, width: 400, height: 250)
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.documentView = list
        list.onOpen = { [weak self] item in self?.load(item.url.path) }
        view.addSubview(scroll)
        status.frame = NSRect(x: 3, y: 0, width: 394, height: 18)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        view.addSubview(status)
        alert.accessoryView = view
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.chosen?(self.directory)
        }
        load(initialPath ?? session.home)
    }
    @objc private func openPath() { load(path.stringValue) }
    @objc private func goBack() { load((directory as NSString).deletingLastPathComponent.isEmpty ? "/" : (directory as NSString).deletingLastPathComponent) }
    private func load(_ value: String) {
        guard value.hasPrefix("/"), !value.contains("\0") else { status.stringValue = "请输入远程绝对路径。"; return }
        revision += 1; let token = revision
        alert.buttons.first?.isEnabled = false
        status.stringValue = "正在读取…"
        session.transport.run("cd \(SSHTransport.quote(value)) && pwd -P") { [weak self] result in
            guard let self, self.revision == token else { return }
            switch result {
            case .failure(let error): self.status.stringValue = error.localizedDescription
            case .success(let data):
                var canonical = String(decoding: data, as: UTF8.self)
                if canonical.hasSuffix("\n") { canonical.removeLast() }
                self.session.transport.list(canonical) { [weak self] result in
                    guard let self, self.revision == token else { return }
                    switch result {
                    case .failure(let error): self.status.stringValue = error.localizedDescription
                    case .success(let (directory, entries)):
                        self.directory = directory; self.path.stringValue = directory
                        let folders = entries.filter(\.isDirectory)
                        self.list.setItems(folders.map { FileItem(url: URL(fileURLWithPath: $0.path), isDirectory: true, name: $0.name) })
                        self.list.frame.size.width = self.scroll.contentSize.width
                        self.list.needsLayout = true
                        self.status.stringValue = "\(folders.count) 个文件夹"
                        self.alert.buttons.first?.isEnabled = true
                    }
                }
            }
        }
    }
}
