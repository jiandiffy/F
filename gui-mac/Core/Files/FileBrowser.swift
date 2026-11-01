import AppKit
import AVKit
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

// MARK: - 文件浏览

struct FileItem {
    let url: URL
    let isDirectory: Bool
    let name: String
}

/// 每个文档独立保留 AppKit 编辑器和撤销栈；不可跨文档重放整份快照。
final class FileUndoManager: UndoManager {
    var mayReplay: (() -> Bool)?
    var didReplay: (() -> Void)?
    override func undo() {
        guard mayReplay?() != false else { return }
        super.undo()
        didReplay?()
    }
    override func redo() {
        guard mayReplay?() != false else { return }
        super.redo()
        didReplay?()
    }
}

private final class FileDocument {
    var url: URL
    let editor: FileTextEditor
    init(url: URL, editor: FileTextEditor) { self.url = url; self.editor = editor }
}

/// APFS 会把中文等文件名归一化成 NFD，直接比较 URL 会漏掉同名项。
private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.path.precomposedStringWithCanonicalMapping == rhs.path.precomposedStringWithCanonicalMapping
}

final class FileRowView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    let item: FileItem
    var onOpen: ((FileRowView) -> Void)?
    var onSelect: ((FileRowView) -> Void)?
    var onRename: ((FileRowView, String) -> Void)?
    var onDelete: ((FileRowView) -> Void)?
    var onCopyPath: ((FileRowView) -> Void)?
    var onNewFolder: ((FileRowView) -> Void)?
    var onNewFile: ((FileRowView) -> Void)?

    var isSelected = false { didSet { applyStyle() } }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hover = false
    private var renaming = false

    init(item: FileItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        icon.image = NSImage(systemSymbolName: item.isDirectory ? "folder" : "doc", accessibilityDescription: item.isDirectory ? "文件夹" : "文件")
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        label.stringValue = item.name
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .secondaryLabelColor
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.delegate = self
        addSubview(label)

        // 双指按压（右键）菜单：文件操作都在这里
        let menu = NSMenu()
        let rename = NSMenuItem(title: "重命名", action: #selector(beginRename), keyEquivalent: "")
        rename.target = self
        let copyPath = NSMenuItem(title: "复制地址", action: #selector(copyPathAction), keyEquivalent: "")
        copyPath.target = self
        let newFolder = NSMenuItem(title: "新建文件夹", action: #selector(newFolderAction), keyEquivalent: "")
        newFolder.target = self
        let newFile = NSMenuItem(title: "新建文件", action: #selector(newFileAction), keyEquivalent: "")
        newFile.target = self
        let delete = NSMenuItem(title: "删除", action: #selector(deleteSelf), keyEquivalent: "")
        delete.target = self
        menu.addItem(rename)
        menu.addItem(copyPath)
        menu.addItem(.separator())
        menu.addItem(newFolder)
        menu.addItem(newFile)
        menu.addItem(.separator())
        menu.addItem(delete)
        self.menu = menu

        toolTip = item.url.path
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: floor((bounds.height - 16) / 2), width: 16, height: 16)
        label.frame = NSRect(x: 30, y: floor((bounds.height - 18) / 2), width: max(0, bounds.width - 36), height: 18)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { hover = true; applyStyle() }
    override func mouseExited(with event: NSEvent) { hover = false; applyStyle() }
    override func mouseDown(with event: NSEvent) {
        onSelect?(self)
        if event.modifierFlags.contains(.control), let menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        // 与原生文件列表一致：单击选择后 Enter 重命名，双击打开。
        if event.clickCount >= 2 { onOpen?(self) }
    }

    override func rightMouseDown(with event: NSEvent) {
        onSelect?(self)
        super.rightMouseDown(with: event)
    }

    // MARK: 重命名（Enter 提交，Esc 取消）

    @objc func beginRename() {
        guard !renaming, onRename != nil else { return }
        renaming = true
        label.isEditable = true
        label.isSelectable = true
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.layer?.cornerRadius = 4
        label.layer?.masksToBounds = true
        window?.makeFirstResponder(label)
        label.currentEditor()?.selectAll(nil)
    }

    var isRenaming: Bool { renaming }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishRename(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let hostWindow = window
            let list = superview
            // Enter arrives before AppKit commits its field editor to the control.
            label.stringValue = textView.string
            finishRename(commit: true)
            hostWindow?.makeFirstResponder(list)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishRename(commit: false)
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func finishRename(commit: Bool) {
        guard renaming else { return }
        renaming = false
        let value = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.layer?.masksToBounds = false
        if commit, !value.isEmpty, value != item.name {
            onRename?(self, value)
        } else {
            label.stringValue = item.name
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(beginRename): return onRename != nil
        case #selector(copyPathAction): return onCopyPath != nil
        case #selector(deleteSelf): return onDelete != nil
        case #selector(newFolderAction): return onNewFolder != nil
        case #selector(newFileAction): return onNewFile != nil
        default: return false
        }
    }

    @objc private func copyPathAction() { onCopyPath?(self) }
    @objc private func deleteSelf() { onDelete?(self) }
    @objc private func newFolderAction() { onNewFolder?(self) }
    @objc private func newFileAction() { onNewFile?(self) }

    private func applyStyle() {
        if isSelected {
            layer?.backgroundColor = ThemeColors.selected.cgColor
            label.textColor = .labelColor
        } else if hover {
            layer?.backgroundColor = ThemeColors.hover.cgColor
            label.textColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = .secondaryLabelColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

final class FileListDocumentView: NSView {
    override var isFlipped: Bool { true }

    var onOpen: ((FileItem) -> Void)?
    var onRename: ((FileItem, String) -> Void)?
    var onDelete: ((FileItem) -> Void)?
    var onCopyPath: ((FileItem) -> Void)?
    var onNewFolder: ((FileItem) -> Void)?
    var onNewFile: ((FileItem) -> Void)?
    /// 空白处右键：在“当前文件夹”里新建。
    var onCreateInCurrentDirectory: ((Bool) -> Void)?

    private var rows: [FileRowView] = []
    private var selectedRow: FileRowView?
    private(set) var directory: URL?

    func setItems(_ items: [FileItem], directory: URL? = nil) {
        subviews.forEach { $0.removeFromSuperview() }
        self.directory = directory
        selectedRow = nil
        rows = items.map { item in
            let row = FileRowView(item: item)
            row.onSelect = { [weak self] row in self?.select(row) }
            row.onOpen = { [weak self] row in
                self?.select(row)
                self?.onOpen?(row.item)
            }
            if onRename != nil { row.onRename = { [weak self] row, name in self?.onRename?(row.item, name) } }
            if onDelete != nil { row.onDelete = { [weak self] row in self?.onDelete?(row.item) } }
            if onCopyPath != nil { row.onCopyPath = { [weak self] row in self?.onCopyPath?(row.item) } }
            if onNewFolder != nil { row.onNewFolder = { [weak self] row in self?.onNewFolder?(row.item) } }
            if onNewFile != nil { row.onNewFile = { [weak self] row in self?.onNewFile?(row.item) } }
            addSubview(row)
            return row
        }
        needsLayout = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if let row = selectedRow {
                if row.onRename != nil { row.beginRename() }
                else { onOpen?(row.item) }
            }
            return
        }
        super.keyDown(with: event)
    }

    private func select(_ row: FileRowView) {
        window?.makeFirstResponder(self)
        selectedRow?.isSelected = false
        selectedRow = row
        row.isSelected = true
    }

    @discardableResult
    func beginRename(url: URL) -> Bool {
        guard let row = rows.first(where: { samePath($0.item.url, url) }) else { return false }
        select(row)
        row.beginRename()
        return true
    }

    override func layout() {
        super.layout()
        let height: CGFloat = 26
        var y: CGFloat = 4
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + 1
        }
        let total = max(y, enclosingScrollView?.contentView.bounds.height ?? 1)
        if abs(frame.height - total) > 0.5 {
            frame.size.height = total
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onCreateInCurrentDirectory != nil else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard !rows.contains(where: { $0.frame.contains(point) }) else { return nil }
        let menu = NSMenu()
        let folder = NSMenuItem(title: "新建文件夹", action: #selector(newFolderInCurrent), keyEquivalent: "")
        folder.target = self
        let file = NSMenuItem(title: "新建文件", action: #selector(newFileInCurrent), keyEquivalent: "")
        file.target = self
        menu.addItem(folder)
        menu.addItem(file)
        return menu
    }

    @objc private func newFolderInCurrent() { onCreateInCurrentDirectory?(true) }
    @objc private func newFileInCurrent() { onCreateInCurrentDirectory?(false) }
}

/// 可编辑文本视图：Cmd+S 保存；其余快捷键（含 Cmd+Z）保持原生行为。
final class FileTextEditor: NSTextView {
    var savedText = ""
    var onSave: (() -> Void)?
    let documentUndo = FileUndoManager()
    override var undoManager: UndoManager? { documentUndo }

    @objc func saveDocument(_ sender: Any?) { onSave?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            saveDocument(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
            onSave?()
            return
        }
        super.keyDown(with: event)
    }
}

final class FileBrowserView: NSView, NSTextViewDelegate {
    private var storedRootURL: URL?
    var rootURL: URL? {
        get { storedRootURL }
        set {
            guard newValue != storedRootURL, flushPendingEdits() else { return }
            storedRootURL = newValue
            documents.removeAll()
            recentDocuments.removeAll()
            history.removeAll()
            currentURL = newValue
            previewing = false
            showList()
        }
    }

    private var currentURL: URL?
    private var history: [URL] = []
    private var previewing = false
    private var previewURL: URL?
    private var editor: FileTextEditor?
    private var editingURL: URL?
    private var documents: [FileDocument] = []
    private var recentDocuments: [FileDocument] = []
    private var replaying = false

    private let backButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let externalEditButton = NSButton()
    private let listScroll = NSScrollView()
    private let listView = FileListDocumentView()
    private let previewHost = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        backButton.isBordered = false
        backButton.bezelStyle = .inline
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "返回")
        backButton.contentTintColor = .secondaryLabelColor
        backButton.target = self
        backButton.action = #selector(goBack)
        addSubview(backButton)

        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        addSubview(titleLabel)

        externalEditButton.isBordered = false
        externalEditButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "在默认应用中编辑")
        externalEditButton.contentTintColor = .secondaryLabelColor
        externalEditButton.toolTip = "在默认应用中编辑"
        externalEditButton.target = self
        externalEditButton.action = #selector(editInDefaultApplication)
        externalEditButton.isHidden = true
        addSubview(externalEditButton)

        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.scrollerStyle = .overlay
        listScroll.borderType = .noBorder
        listScroll.documentView = listView
        listView.onOpen = { [weak self] item in self?.open(item) }
        listView.onRename = { [weak self] item, name in self?.rename(item, to: name) }
        listView.onDelete = { [weak self] item in self?.delete(item) }
        listView.onCopyPath = { [weak self] item in self?.copyPath(of: item) }
        listView.onNewFolder = { [weak self] item in self?.createFolder(in: self?.targetDirectory(for: item)) }
        listView.onNewFile = { [weak self] item in self?.createFile(in: self?.targetDirectory(for: item)) }
        listView.onCreateInCurrentDirectory = { [weak self] folder in
            guard let self else { return }
            if folder { self.createFolder(in: self.currentURL) } else { self.createFile(in: self.currentURL) }
        }
        addSubview(listScroll)

        previewHost.isHidden = true
        addSubview(previewHost)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { savePendingEdit() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()

        let headerHeight: CGFloat = 28
        backButton.frame = NSRect(x: 4, y: bounds.height - headerHeight + 4, width: 20, height: 20)
        titleLabel.frame = NSRect(
            x: 26,
            y: bounds.height - headerHeight + 7,
            width: max(0, bounds.width - (externalEditButton.isHidden ? 34 : 58)),
            height: 15
        )
        externalEditButton.frame = NSRect(x: bounds.width - 26, y: bounds.height - 24, width: 20, height: 20)

        let contentHeight = max(0, bounds.height - headerHeight)
        listScroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        previewHost.frame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)

        let width = listScroll.contentView.bounds.width
        listView.needsLayout = true
        if abs(listView.frame.width - width) > 0.5 {
            listView.frame.size.width = width
            listView.needsLayout = true
        }
    }

    // MARK: 列表 / 预览

    private func showList() {
        guard flushPendingEdits() else { return }
        previewing = false
        previewURL = nil
        externalEditButton.isHidden = true
        editor = nil
        editingURL = nil
        previewHost.isHidden = true
        previewHost.subviews.forEach { $0.removeFromSuperview() }
        listScroll.isHidden = false

        titleLabel.stringValue = currentURL?.lastPathComponent ?? "文件"
        titleLabel.toolTip = currentURL?.path
        backButton.isHidden = history.isEmpty

        refreshList()
        window?.makeFirstResponder(self)
    }

    private func refreshList() {
        listView.setItems(items(in: currentURL), directory: currentURL)
        needsLayout = true
    }

    private func showPreview(_ url: URL) {
        guard flushPendingEdits() else { return }
        editor = nil
        editingURL = nil
        previewing = true
        previewURL = url
        externalEditButton.isHidden = isEditableTextFile(url)
        previewHost.isHidden = false
        listScroll.isHidden = true
        titleLabel.stringValue = url.lastPathComponent
        titleLabel.toolTip = url.path
        backButton.isHidden = false

        previewHost.subviews.forEach { $0.removeFromSuperview() }
        let view = makePreview(for: url)
        view.frame = previewHost.bounds
        view.autoresizingMask = [.width, .height]
        previewHost.addSubview(view)
        // The hidden list (or a detached previous editor) must not keep keys.
        if let editor { window?.makeFirstResponder(editor) }
        else { window?.makeFirstResponder(self) }
    }

    @objc private func goBack() {
        if previewing {
            showList()
            return
        }
        if let previous = history.popLast() {
            currentURL = previous
            showList()
        }
    }

    @objc private func editInDefaultApplication() {
        guard let previewURL, flushPendingEdits() else { return }
        NSWorkspace.shared.open(previewURL)
    }

    private func open(_ item: FileItem) {
        guard flushPendingEdits() else { return }
        if item.isDirectory {
            if let currentURL { history.append(currentURL) }
            currentURL = item.url
            showList()
        } else {
            showPreview(item.url)
        }
    }

    private func items(in url: URL?) -> [FileItem] {
        guard let url else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        var items: [FileItem] = []
        for fileURL in urls.prefix(600) {
            let values = try? fileURL.resourceValues(forKeys: keys)
            items.append(FileItem(
                url: fileURL,
                isDirectory: values?.isDirectory ?? false,
                name: fileURL.lastPathComponent
            ))
        }
        return items.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    // MARK: 文件操作

    /// 文件夹行 → 在该文件夹内操作；文件行 → 所在文件夹。
    private func targetDirectory(for item: FileItem) -> URL? {
        item.isDirectory ? item.url : item.url.deletingLastPathComponent()
    }

    private func rename(_ item: FileItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name, ![".", ".."].contains(trimmed),
              !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.contains("\u{0}") else {
            refreshList()
            return
        }
        let target = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            showError("“\(trimmed)”已存在，未重命名。")
            refreshList()
            return
        }
        guard flushPendingEdits() else { return }
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            func moved(_ url: URL) -> URL {
                if samePath(url, item.url) { return target }
                let prefix = item.url.path.precomposedStringWithCanonicalMapping + "/"
                let normalized = url.path.precomposedStringWithCanonicalMapping
                if normalized.hasPrefix(prefix) {
                    return target.appendingPathComponent(String(normalized.dropFirst(prefix.count)))
                }
                return url
            }
            for document in documents { document.url = moved(document.url) }
            history = history.map(moved)
            currentURL = currentURL.map(moved)
            editingURL = editingURL.map(moved)
            previewURL = previewURL.map(moved)
        }
        catch { showError("无法重命名：\(error.localizedDescription)") }
        refreshList()
    }

    private func copyPath(of item: FileItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.url.path, forType: .string)
    }

    private func delete(_ item: FileItem) {
        guard flushPendingEdits() else { return }
        // 移到废纸篓（而不是不可恢复地删除）；同步执行，列表立即更新。
        do { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
        catch {
            showError("无法删除：\(error.localizedDescription)")
            return
        }
        let removed: (FileDocument) -> Bool = {
            samePath($0.url, item.url) || $0.url.path.precomposedStringWithCanonicalMapping.hasPrefix(item.url.path.precomposedStringWithCanonicalMapping + "/")
        }
        documents.removeAll(where: removed)
        recentDocuments.removeAll(where: removed)
        refreshList()
    }

    private func createFolder(in directory: URL?) {
        guard let directory, flushPendingEdits() else { return }
        let url = uniqueURL(in: directory, base: "未命名文件夹", extension: "")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            showError("无法新建文件夹：\(error.localizedDescription)")
            return
        }
        revealCreatedItem(url, in: directory)
    }

    private func createFile(in directory: URL?) {
        guard let directory, flushPendingEdits() else { return }
        let url = uniqueURL(in: directory, base: "未命名", extension: "txt")
        do { try createEmptyFile(at: url) }
        catch { showError("无法新建文件：\(error.localizedDescription)"); return }
        revealCreatedItem(url, in: directory)
    }

    private func revealCreatedItem(_ url: URL, in directory: URL) {
        if currentURL.map({ samePath($0, directory) }) != true {
            if let currentURL { history.append(currentURL) }
            currentURL = directory
            showList()
        } else { refreshList() }
        // A folder-row creation must reveal the new child, not silently leave
        // it inside an unopened directory with no reachable rename field.
        listView.layoutSubtreeIfNeeded()
        listView.beginRename(url: url)
    }

    private func createEmptyFile(at url: URL) throws {
        // O_EXCL equivalent: the name may have been taken after uniqueURL checked it.
        try Data().write(to: url, options: .withoutOverwriting)
    }

    private func uniqueURL(in directory: URL, base: String, extension ext: String) -> URL {
        var index = 0
        while true {
            let name: String
            if ext.isEmpty { name = index == 0 ? base : "\(base) \(index)" }
            else { name = index == 0 ? "\(base).\(ext)" : "\(base) \(index).\(ext)" }
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

    private func showError(_ text: String) {
        guard let window else { NSSound.beep(); return }
        guard window.attachedSheet == nil else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = text
        alert.beginSheetModal(for: window)
    }

    // MARK: 编辑、保存与撤销

    /// 不跟随符号链接，不覆盖其他进程写入的内容。失败保留编辑器、草稿和撤销栈。
    private func validateDisk(_ document: FileDocument) throws {
        var component = document.url
        while component.path != "/" {
            let attributes = try FileManager.default.attributesOfItem(atPath: component.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw NSError(domain: "FileBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: "符号链接不可编辑。"])
            }
            component.deleteLastPathComponent()
        }
        guard try Data(contentsOf: document.url) == Data(document.editor.savedText.utf8) else {
            throw NSError(domain: "FileBrowser", code: 2, userInfo: [NSLocalizedDescriptionKey: "文件已被外部修改，请保留草稿并重新核对。"])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: document.url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o222 != 0, FileManager.default.isWritableFile(atPath: document.url.path),
              FileManager.default.isWritableFile(atPath: document.url.deletingLastPathComponent().path) else {
            throw NSError(domain: "FileBrowser", code: 3, userInfo: [NSLocalizedDescriptionKey: "文件或目录不可写。"])
        }
    }

    private func save(_ document: FileDocument) -> Bool {
        guard document.editor.string != document.editor.savedText else { return true }
        do {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var writeError: Error?
            coordinator.coordinate(writingItemAt: document.url, options: [], error: &coordinationError) { url in
                do {
                    try self.validateDisk(document)
                    try Data(document.editor.string.utf8).write(to: url, options: .atomic)
                } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError as NSError? { throw error }
            document.editor.savedText = document.editor.string
            return true
        } catch {
            showError("无法保存（草稿已保留）：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func flushPendingEdits() -> Bool {
        for document in documents where !save(document) { return false }
        return true
    }

    private func savePendingEdit() { _ = flushPendingEdits() }

    func textDidChange(_ notification: Notification) {
        guard let text = notification.object as? FileTextEditor,
              let document = documents.first(where: { $0.editor === text }) else { return }
        if !replaying {
            recentDocuments.removeAll { $0 === document }
            recentDocuments.append(document)
            _ = save(document)
        }
    }

    /// 关闭失败时调用方必须保留面板；成功关闭才清空原生 undo/redo。
    @discardableResult
    func panelVisibilityChanged(open: Bool) -> Bool {
        if !open, let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: self) || ((responder as? NSTextView)?.delegate as? NSView)?.isDescendant(of: self) == true {
            // Off-screen panels must never retain a typing target. Commit any
            // field-editor composition before deciding whether closing is safe.
            window?.makeFirstResponder(nil)
        }
        guard flushPendingEdits() else { return false }
        for document in documents { document.editor.documentUndo.removeAllActions() }
        recentDocuments.removeAll()
        if !open { documents.removeAll() }
        if open {
            if previewing, let previewURL { showPreview(previewURL) }
            else { refreshList() }
        }
        return true
    }

    var canUndoEdit: Bool { recentDocuments.contains { $0.editor.documentUndo.canUndo } }

    @objc func saveDocument(_ sender: Any?) { _ = flushPendingEdits() }

    @objc func undo(_ sender: Any?) {
        guard let document = recentDocuments.last(where: { $0.editor.documentUndo.canUndo }) else { NSSound.beep(); return }
        document.editor.documentUndo.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard let document = recentDocuments.last(where: { $0.editor.documentUndo.canRedo }) else { NSSound.beep(); return }
        document.editor.documentUndo.redo()
    }

    // MARK: 预览生成

    private func makePreview(for url: URL) -> NSView {
        let ext = url.pathExtension.lowercased()

        if ext == "pdf" {
            let view = PDFView()
            view.autoScales = true
            view.displayMode = .singlePageContinuous
            view.displayDirection = .vertical
            view.backgroundColor = .clear
            view.pageShadowsEnabled = false
            view.document = PDFDocument(url: url)
            return view
        }

        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "svg"].contains(ext) {
            let view = NSImageView()
            view.image = NSImage(contentsOf: url)
            view.imageScaling = .scaleProportionallyUpOrDown
            return view
        }

        if ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mp3", "m4a", "wav", "aiff"].contains(ext) {
            let view = AVPlayerView()
            view.controlsStyle = .inline
            view.player = AVPlayer(url: url)
            return view
        }

        if isTextLike(url), isEditableTextFile(url) {
            return makeTextEditor(url)
        }

        if isTextLike(url) {
            return makeTextPreview(url)
        }

        let quickLook = QLPreviewView(frame: .zero, style: .compact)
        quickLook?.previewItem = url as NSURL
        quickLook?.autostarts = true
        return quickLook ?? NSView()
    }

    private func makeTextPreview(_ url: URL) -> NSView {
        let scroll = makeTextScroll()
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = readText(url)
        scroll.documentView = text
        return scroll
    }

    private func makeTextEditor(_ url: URL) -> NSView {
        let scroll = makeTextScroll()
        if let document = documents.first(where: { samePath($0.url, url) }) {
            // Cached editors retain undo across close/reopen, but a clean buffer
            // must not conceal a newer on-disk revision from another process.
            guard let data = try? Data(contentsOf: url), data.count < 2_000_000, !data.contains(0),
                  let current = String(data: data, encoding: .utf8) else { return makeTextPreview(url) }
            if document.editor.string == document.editor.savedText, current != document.editor.savedText {
                document.editor.string = current
                document.editor.savedText = current
                document.editor.documentUndo.removeAllActions()
                recentDocuments.removeAll { $0 === document }
            }
            scroll.documentView = document.editor
            editor = document.editor
            editingURL = document.url
            return scroll
        }
        // 资格检查后文件仍可能变化或失去读取权限；错误提示绝不能成为编辑器基线。
        guard let data = try? Data(contentsOf: url), data.count < 2_000_000,
              let content = String(data: data, encoding: .utf8) else { return makeTextPreview(url) }
        let text = FileTextEditor(frame: .zero)
        text.isEditable = true
        text.isSelectable = true
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = content
        text.savedText = content
        let document = FileDocument(url: url, editor: text)
        documents.append(document)
        text.delegate = self
        text.onSave = { [weak self, weak document] in
            if let document { _ = self?.save(document) }
        }
        text.documentUndo.mayReplay = { [weak self, weak document] in
            guard let self, let document, self.flushPendingEdits() else { return false }
            do { try self.validateDisk(document) }
            catch { self.showError("无法撤销/重做：\(error.localizedDescription)"); return false }
            self.replaying = true
            return true
        }
        text.documentUndo.didReplay = { [weak self, weak document] in
            guard let self, let document else { return }
            self.replaying = false
            _ = self.save(document)
        }
        scroll.documentView = text
        editor = text
        editingURL = url
        return scroll
    }

    private func makeTextScroll() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    private func readText(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size < 2_000_000 else { return "文件太大，无法预览。" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "无法以文本方式读取该文件。"
    }

    private func isEditableTextFile(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size < 2_000_000 else { return false }
        var component = url
        while component.path != "/" {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: component.path),
                  attributes[.type] as? FileAttributeType != .typeSymbolicLink else { return false }
            component.deleteLastPathComponent()
        }
        guard let data = try? Data(contentsOf: url), data.count < 2_000_000, !data.contains(0),
              String(data: data, encoding: .utf8) != nil else { return false }
        return true
    }

    private func isTextLike(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let known: Set<String> = [
            "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "js", "jsx", "ts", "tsx",
            "py", "rb", "go", "rs", "java", "kt", "kts", "php", "lua", "sh", "zsh", "bash",
            "json", "jsonl", "yaml", "yml", "toml", "ini", "conf", "cfg", "xml", "html", "htm",
            "css", "scss", "less", "md", "markdown", "txt", "log", "csv", "tsv", "sql",
            "gradle", "properties", "plist", "diff", "patch", "gitignore", "env",
        ]
        if known.contains(ext) { return true }
        if !ext.isEmpty, let type = UTType(filenameExtension: ext),
           type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .plainText) { return true }
        // README/Makefile and newly renamed extensionless files are editable too;
        // do not mistake NUL-containing or invalid UTF-8 binary data for text.
        guard let data = try? Data(contentsOf: url), data.count < 2_000_000, !data.contains(0) else { return false }
        return String(data: data, encoding: .utf8) != nil
    }
}
