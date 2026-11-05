// Isolated native file-panel regression; never reads or edits user projects.
extension FileBrowserView {
    var rowsForTest: [FileRowView] { listView.rowsForTest }
    var editorForTest: FileTextEditor? { editor }
    func openForTest(_ url: URL, directory: Bool = false) {
        open(FileItem(url: url, isDirectory: directory, name: url.lastPathComponent))
    }
    func backForTest() { goBack() }
    func renameForTest(_ url: URL, _ name: String) {
        rename(FileItem(url: url, isDirectory: true, name: url.lastPathComponent), to: name)
    }
    func createForTest(_ url: URL, folder: Bool) {
        if folder { createFolder(in: url) } else { createFile(in: url) }
    }
    var listForTest: FileListDocumentView { listView }
    var previewForTest: Bool { previewing }
    func exclusiveCreateForTest(_ url: URL) throws { try createEmptyFile(at: url) }
    func trashForTest(_ url: URL) { delete(FileItem(url: url, isDirectory: false, name: url.lastPathComponent)) }
    func copyForTest(_ url: URL) { copyPath(of: FileItem(url: url, isDirectory: false, name: url.lastPathComponent)) }
}
extension FileListDocumentView {
    var rowsForTest: [FileRowView] { rows }
    func selectForTest(_ row: FileRowView) { select(row) }
}
extension FileRowView {
    func setNameForTest(_ name: String) { label.stringValue = name }
    func commandForTest(_ selector: Selector) {
        let fieldEditor = NSTextView(); fieldEditor.string = label.stringValue
        _ = control(label, textView: fieldEditor, doCommandBy: selector)
    }
    func submitTypedNameForTest(_ name: String) {
        let fieldEditor = NSTextView(); fieldEditor.string = name
        _ = control(label, textView: fieldEditor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func contents(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>" }
func put(_ value: String, _ url: URL) { try! Data(value.utf8).write(to: url, options: .atomic) }
func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)!
}
func replace(_ editor: FileTextEditor, _ value: String) {
    editor.breakUndoCoalescing()
    while editor.documentUndo.groupingLevel > 0 { editor.documentUndo.endUndoGrouping() }
    editor.documentUndo.groupsByEvent = false
    editor.documentUndo.beginUndoGrouping()
    editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    editor.breakUndoCoalescing()
    editor.documentUndo.endUndoGrouping()
}
func dismissAlerts(_ window: NSWindow) {
    for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil) }
}
func runFileBrowserScenarios() {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["F_FILE_TEST_ROOT"]!).appendingPathComponent("project")
    let fm = FileManager.default
    let sub = root.appendingPathComponent("sub")
    try! fm.createDirectory(at: sub, withIntermediateDirectories: true)
    let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
    put("one", a); put("bee", b)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let browser = FileBrowserView(frame: window.contentView!.bounds)
    window.contentView = browser
    window.makeKeyAndOrderFront(nil)
    browser.rootURL = root
    browser.layoutSubtreeIfNeeded()
    browser.listForTest.layoutSubtreeIfNeeded()
    expect(browser.listForTest.frame.height >= 560, "blank context menu must cover viewport")
    let blank = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 150, y: 50), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    expect(browser.listForTest.menu(for: blank)?.items.map(\.title) == ["新建文件夹", "新建文件"], "blank right-click menu")
    let row = browser.rowsForTest.first { $0.item.name == "sub" }!
    expect(row.menu?.items.contains { $0.title == "新建文件" } == true, "directory right-click menu")
    expect(browser.rowsForTest.first { $0.item.name == "a.txt" }?.menu?.items.contains { $0.title == "删除" } == true, "file right-click menu")
    let readOnlyList = FileListDocumentView(frame: .zero)
    readOnlyList.setItems([FileItem(url: a, isDirectory: false, name: "a.txt")])
    let readOnlyRow = readOnlyList.rowsForTest[0]
    expect(!readOnlyRow.validateMenuItem(readOnlyRow.menu!.items[0]), "shared read-only lists must not offer fake rename actions")
    readOnlyRow.beginRename()
    expect(!readOnlyRow.isRenaming, "unconfigured shared list cannot rename")
    expect(readOnlyList.menu(for: blank) == nil, "unconfigured shared list has no fake creation menu")
    var openedReadOnly = false
    readOnlyList.onOpen = { _ in openedReadOnly = true }
    readOnlyList.selectForTest(readOnlyRow)
    readOnlyList.keyDown(with: key("\r", 36))
    expect(openedReadOnly, "Enter still opens items for read-only shared consumers")
    row.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!)
    expect(!browser.previewForTest, "single click selects instead of leaving list")
    browser.listForTest.keyDown(with: key("\r", 36))
    expect(row.isRenaming, "Enter starts rename")
    row.setNameForTest("cancelled")
    row.commandForTest(#selector(NSResponder.cancelOperation(_:)))
    expect(fm.fileExists(atPath: sub.path), "Esc cancels")
    browser.createForTest(sub, folder: false)
    expect(browser.rowsForTest.contains { samePath($0.item.url, sub.appendingPathComponent("未命名.txt")) }, "folder-row creation must reveal the new child for renaming")
    browser.copyForTest(a)
    expect(NSPasteboard.general.string(forType: .string) == a.path, "copy full file address")
    let raced = root.appendingPathComponent("raced.txt")
    put("other writer", raced)
    do { try browser.exclusiveCreateForTest(raced); expect(false, "competing file creation must fail") }
    catch { expect(contents(raced) == "other writer", "competing file is never truncated") }
    browser.createForTest(root, folder: true)
    let newRow = browser.rowsForTest.first { $0.item.name == "未命名文件夹" }!
    newRow.beginRename()
    newRow.submitTypedNameForTest("created")
    expect(fm.fileExists(atPath: root.appendingPathComponent("created").path), "Enter commits rename")
    expect(fm.fileExists(atPath: sub.appendingPathComponent("未命名.txt").path), "create inside directory row target")
    browser.renameForTest(sub, "..")
    expect(fm.fileExists(atPath: sub.path), "illegal name rejected")

    browser.openForTest(a)
    let first = browser.editorForTest!
    replace(first, "one-edited")
    expect(contents(a) == "one-edited", "editing autosaves")
    first.string = "menu-save"
    expect(first.performKeyEquivalent(with: key("s", 1, .command)), "performKeyEquivalent Cmd+S handled")
    expect(contents(a) == "menu-save", "Cmd+S writes")
    // Real responder-chain menu action, not keyDown.
    first.string = "menu-action"
    window.makeFirstResponder(first)
    let saveMenu = NSMenu(title: "文件")
    let saveItem = saveMenu.addItem(withTitle: "保存", action: #selector(FileTextEditor.saveDocument(_:)), keyEquivalent: "s")
    saveItem.target = window.firstResponder
    expect(saveMenu.performKeyEquivalent(with: key("s", 1, .command)), "native Save menu action")
    expect(contents(a) == "menu-action", "native Save writes")
    replace(first, "last-a")
    browser.backForTest()
    browser.openForTest(a)
    expect(browser.editorForTest === first, "reopen preserves editor and UndoManager")
    first.documentUndo.undo()
    expect(contents(a) == "menu-action", "native undo survives reopening: \(contents(a)), editor=\(first.string), undo=\(first.documentUndo.canUndo)")
    first.documentUndo.redo()
    expect(contents(a) == "last-a", "native redo preserved")
    browser.openForTest(b)
    replace(browser.editorForTest!, "bee-edited")
    browser.backForTest()
    browser.undo(nil)
    expect(contents(b) == "bee", "list Cmd+Z targets most recently edited document")
    expect(contents(a) == "last-a", "list undo must not overwrite other files")
    browser.redo(nil)
    expect(contents(b) == "bee-edited", "list redo")

    // External changes must block undo and saving, retaining draft and navigation.
    browser.openForTest(b)
    let second = browser.editorForTest!
    put("external", b)
    second.documentUndo.undo()
    expect(contents(b) == "external", "undo rejects external edits")
    expect(second.string == "bee-edited", "failed undo leaves editor unchanged")
    dismissAlerts(window)
    second.string = "unsaved draft"
    browser.backForTest()
    expect(browser.previewForTest && browser.editorForTest === second, "failed save must not close document")
    dismissAlerts(window)
    expect(!browser.panelVisibilityChanged(open: false), "failed save cancels panel close")
    dismissAlerts(window)
    browser.rootURL = sub
    expect(browser.rootURL == root, "failed save cancels project switch")
    dismissAlerts(window)
    expect(!browser.flushPendingEdits(), "quit flush signals cancellation")
    dismissAlerts(window)
    put(second.savedText, b) // resolve conflict explicitly in isolated fixture
    expect(browser.flushPendingEdits(), "resolved conflict saves retained draft")
    expect(contents(b) == "unsaved draft", "draft not lost")

    try! fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: b.path)
    second.string = "permission draft"
    expect(!browser.flushPendingEdits(), "read-only file rejected")
    dismissAlerts(window)
    try! fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: b.path)
    expect(browser.flushPendingEdits(), "permission-restored draft saved")
    browser.backForTest()
    let link = root.appendingPathComponent("link.txt")
    try! fm.createSymbolicLink(at: link, withDestinationURL: a)
    browser.openForTest(link)
    expect(browser.editorForTest == nil, "symlink is preview-only")
    browser.backForTest()
    let invalid = root.appendingPathComponent("invalid.txt")
    let invalidBytes = Data([0xff, 0xfe, 0x80])
    try! invalidBytes.write(to: invalid)
    browser.openForTest(invalid)
    expect(browser.editorForTest == nil, "invalid UTF-8 must stay read-only")
    expect(browser.flushPendingEdits(), "read-only failure preview has no editable draft")
    expect((try! Data(contentsOf: invalid)) == invalidBytes, "error preview never overwrites real bytes")
    browser.backForTest()

    let cleanExternal = root.appendingPathComponent("external-clean.txt")
    put("old disk", cleanExternal)
    browser.openForTest(cleanExternal)
    browser.backForTest()
    put("new disk", cleanExternal)
    browser.openForTest(cleanExternal)
    expect(browser.editorForTest?.string == "new disk", "clean cached editor must show newer external content")
    expect(browser.editorForTest?.documentUndo.canUndo == false, "stale undo cannot replay across external revisions")
    browser.backForTest()

    let readme = root.appendingPathComponent("README")
    put("extensionless text", readme)
    browser.openForTest(readme)
    expect(browser.editorForTest != nil, "extensionless UTF-8 files must be editable")
    replace(browser.editorForTest!, "extensionless edited")
    browser.backForTest()
    expect(contents(readme) == "extensionless edited", "extensionless edits persist")

    let inner = sub.appendingPathComponent("inner.txt")
    put("old", inner)
    browser.openForTest(inner)
    let innerEditor = browser.editorForTest!
    replace(innerEditor, "new")
    browser.backForTest()
    browser.renameForTest(sub, "renamed")
    let moved = root.appendingPathComponent("renamed/inner.txt")
    browser.undo(nil)
    expect(contents(moved) == "old", "directory rename updates document undo paths")
    expect(!fm.fileExists(atPath: inner.path), "undo must not recreate old path")
    let unicodeDirectory = root.appendingPathComponent("café文件")
    try! fm.createDirectory(at: unicodeDirectory, withIntermediateDirectories: false)
    let unicodeFile = unicodeDirectory.appendingPathComponent("inside.txt")
    put("unicode-old", unicodeFile)
    browser.openForTest(unicodeFile)
    replace(browser.editorForTest!, "unicode-new")
    browser.backForTest()
    // The clicked APFS directory can be NFD while the cached document URL is NFC.
    browser.renameForTest(URL(fileURLWithPath: unicodeDirectory.path.decomposedStringWithCanonicalMapping), "归一化目录")
    browser.undo(nil)
    expect(contents(root.appendingPathComponent("归一化目录/inside.txt")) == "unicode-old", "normalized directory rename must retain child undo paths")
    browser.openForTest(moved)
    let closingEditor = browser.editorForTest!
    window.makeFirstResponder(closingEditor)
    expect(browser.panelVisibilityChanged(open: false), "successful close")
    expect(window.firstResponder !== closingEditor, "closed sidebar cannot keep an off-screen typing target")
    expect(!innerEditor.documentUndo.canUndo && !innerEditor.documentUndo.canRedo, "sidebar boundary clears undo and redo")
    put("changed while panel closed", moved)
    expect(browser.panelVisibilityChanged(open: true), "reopen sidebar")
    expect(browser.editorForTest?.string == "changed while panel closed", "opening panel refreshes clean external changes")
    browser.backForTest()
    expect(browser.panelVisibilityChanged(open: false), "close directory listing")
    put("new while closed", root.appendingPathComponent("appeared.txt"))
    expect(browser.panelVisibilityChanged(open: true), "reopen directory listing")
    expect(browser.rowsForTest.contains { $0.item.name == "appeared.txt" }, "reopening sidebar refreshes directory entries")
    browser.trashForTest(raced)
    expect(!fm.fileExists(atPath: raced.path), "delete moves isolated file to trash")
    print("PASS: viewport/row menus, Enter/Esc, real Cmd+S action, autosave, retained native undo/redo, list targeting, conflicts, permissions, symlinks, rename paths, cancellable flush")
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.main.async { runFileBrowserScenarios() }
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fputs("FAIL: file browser suite timed out\n", stderr); exit(1) }
app.run()
