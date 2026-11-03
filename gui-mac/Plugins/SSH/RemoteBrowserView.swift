import AppKit

final class RemoteEditorTextView: NSTextView {
    var onSave: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "s" { onSave?(); return }
        super.keyDown(with: event)
    }
}

final class RemoteBrowserView: NSView, NSTextViewDelegate {
    private let pathField = NSTextField(string: "")
    private let back = NSButton()
    private let saveButton = NSButton()
    private let refresh = NSButton()
    private let status = NSTextField(labelWithString: "连接 SSH 后可打开远程文件夹")
    private let scroll = NSScrollView()
    private let list = FileListDocumentView()
    private let editorScroll = NSScrollView()
    private let editor = RemoteEditorTextView()
    private(set) var transport: SSHTransport?
    private(set) var directory = "/"
    private(set) var file: RemoteTextFile?
    private var loading = false
    private var revision = 0
    private weak var presentationWindow: NSWindow?
    var hasUnsavedChanges: Bool { file.map { editor.string != $0.text } ?? false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        configureIcon(back, "chevron.left", "返回远程文件夹", #selector(goBack))
        configureIcon(saveButton, "square.and.arrow.down", "保存到远程电脑", #selector(saveFile))
        configureIcon(refresh, "arrow.clockwise", "刷新远程文件夹", #selector(refreshDirectory))
        pathField.isBordered = false; pathField.drawsBackground = false
        pathField.font = .systemFont(ofSize: 11.5)
        pathField.textColor = .secondaryLabelColor
        pathField.focusRingType = .none
        pathField.placeholderString = "远程路径"
        pathField.target = self; pathField.action = #selector(openPath)
        pathField.setAccessibilityLabel("远程文件夹路径")
        addSubview(pathField)
        status.font = .systemFont(ofSize: 10.5); status.textColor = .tertiaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        addSubview(status)
        for view in [scroll, editorScroll] {
            view.drawsBackground = false; view.hasVerticalScroller = true
            view.autohidesScrollers = true; view.scrollerStyle = .overlay; view.borderType = .noBorder
            addSubview(view)
        }
        scroll.documentView = list
        list.onOpen = { [weak self] item in
            if item.isDirectory { self?.openDirectory(item.url.path) }
            else { self?.openFile(item.url.path) }
        }
        editor.isRichText = false; editor.drawsBackground = false
        editor.allowsUndo = true
        editor.onSave = { [weak self] in self?.save {} }
        editor.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        editor.textColor = .labelColor; editor.insertionPointColor = .labelColor
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.textContainerInset = NSSize(width: 5, height: 6)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editorScroll.documentView = editor
        editorScroll.isHidden = true
        saveButton.isHidden = true
        updateControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { presentationWindow = window }
    }

    private func configureIcon(_ button: NSButton, _ symbol: String, _ label: String, _ action: Selector) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label; button.setAccessibilityLabel(label)
        button.target = self; button.action = action
        addSubview(button)
    }

    override func layout() {
        super.layout()
        back.frame = NSRect(x: 0, y: bounds.height - 27, width: 24, height: 24)
        refresh.frame = NSRect(x: bounds.width - 25, y: bounds.height - 27, width: 24, height: 24)
        saveButton.frame = refresh.frame
        pathField.frame = NSRect(x: 27, y: bounds.height - 23, width: max(0, bounds.width - 56), height: 18)
        status.frame = NSRect(x: 5, y: 2, width: max(0, bounds.width - 10), height: 16)
        let content = NSRect(x: 0, y: 22, width: bounds.width, height: max(0, bounds.height - 52))
        scroll.frame = content; editorScroll.frame = content
        list.frame.size.width = scroll.contentSize.width
        list.needsLayout = true
    }

    func attach(_ transport: SSHTransport, home: String) {
        revision += 1
        self.transport = transport
        file = nil; editor.string = ""
        openDirectory(home)
    }
    func detach() {
        revision += 1
        transport = nil; loading = false
        setStatus(hasUnsavedChanges ? "已断开 · 未保存的编辑仍保留在此处" : "SSH 已断开")
        updateControls()
    }
    func textDidChange(_ notification: Notification) {
        setStatus(hasUnsavedChanges ? "未保存 · 保存后写入远程电脑" : "已保存到远程电脑")
        updateControls()
    }
    private func setStatus(_ value: String) { status.stringValue = value; status.toolTip = value }
    private func updateControls() {
        back.isEnabled = !loading && transport != nil
        refresh.isEnabled = !loading && transport != nil
        saveButton.isEnabled = !loading && transport != nil && hasUnsavedChanges
        pathField.isEnabled = !loading && transport != nil && file == nil
        editor.isEditable = !loading && transport != nil
    }
    private func presentFile(_ file: RemoteTextFile?) {
        self.file = file
        scroll.isHidden = file != nil; editorScroll.isHidden = file == nil
        saveButton.isHidden = file == nil; refresh.isHidden = file != nil
        pathField.stringValue = file?.path ?? directory
        pathField.toolTip = pathField.stringValue
        updateControls()
    }

    func allowLeaving(_ completion: @escaping () -> Void) {
        confirmLeaving { if $0 { completion() } }
    }
    func confirmLeaving(_ completion: @escaping (Bool) -> Void) {
        guard hasUnsavedChanges else { completion(true); return }
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        alert.messageText = "保留未保存的远程编辑？"
        alert.informativeText = "取消后可先保存当前文件。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "放弃编辑")
        alert.buttons.forEach { $0.isBordered = false; $0.contentTintColor = .labelColor }
        guard let window = window ?? presentationWindow ?? NSApp.mainWindow else { completion(false); return }
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertSecondButtonReturn)
        }
    }

    @objc private func openPath() { openDirectory(pathField.stringValue) }
    @objc private func refreshDirectory() { openDirectory(directory) }
    @objc private func goBack() {
        if file != nil { openDirectory(directory) }
        else { openDirectory((directory as NSString).deletingLastPathComponent.isEmpty ? "/" : (directory as NSString).deletingLastPathComponent) }
    }

    func openDirectory(_ path: String) {
        allowLeaving { [weak self] in self?.loadDirectory(path) }
    }
    private func loadDirectory(_ path: String) {
        guard let transport, !loading else { return }
        guard path.hasPrefix("/"), !path.contains("\0") else { setStatus("请输入以 / 开头的远程绝对路径。"); return }
        revision += 1; let token = revision
        loading = true; updateControls(); setStatus("正在读取远程文件夹…")
        transport.list(path) { [weak self, weak transport] result in
            guard let self, self.revision == token, self.transport === transport else { return }
            self.loading = false
            switch result {
            case .success(let (path, entries)):
                self.directory = path
                self.presentFile(nil)
                self.list.setItems(entries.map { FileItem(url: URL(fileURLWithPath: $0.path), isDirectory: $0.isDirectory, name: $0.name) })
                self.setStatus("\(entries.count) 项 · 远程电脑")
            case .failure(let error): self.setStatus(error.localizedDescription)
            }
            self.updateControls(); self.needsLayout = true
        }
    }
    func openFile(_ path: String) {
        guard let transport, !loading else { return }
        loading = true; let token = revision
        updateControls(); setStatus("正在读取远程文件…")
        transport.readText(path) { [weak self, weak transport] result in
            guard let self, self.revision == token, self.transport === transport else { return }
            self.loading = false
            switch result {
            case .success(let file):
                self.editor.string = file.text
                self.presentFile(file)
                self.setStatus("已打开 · \(transport?.connection.label ?? "远程电脑")")
            case .failure(let error): self.setStatus(error.localizedDescription)
            }
            self.updateControls()
        }
    }
    @objc private func saveFile() { save {} }
    func save(_ completion: @escaping () -> Void) {
        guard let transport, let file, !loading, hasUnsavedChanges else { completion(); return }
        let token = revision, text = editor.string
        loading = true; updateControls(); setStatus("正在保存到远程电脑…")
        transport.save(file, text: text) { [weak self, weak transport] result in
            guard let self, self.revision == token, self.transport === transport else { completion(); return }
            self.loading = false
            switch result {
            case .success(let saved): self.file = saved; self.setStatus("已保存到远程电脑")
            case .failure(let error): self.setStatus(error.localizedDescription)
            }
            self.updateControls(); completion()
        }
    }
}
