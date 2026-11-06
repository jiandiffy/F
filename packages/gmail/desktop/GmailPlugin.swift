import AppKit
import UniformTypeIdentifiers
import CFNetwork

/// One independent mailbox shared by local and SSH conversations. No project files are used.
final class GmailPlugin: NSObject, FPlugin, FProcessActivity, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let id = "gmail"
    let title = "Gmail"
    let symbol = "envelope"
    let placement = PluginPlacement.workspace
    let view: NSView = GmailWorkspaceView()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "在设置中连接 Google 账号")
    private let table = NSTableView()
    private let reader = NSTextView()
    private let split = NSSplitView()
    private var buttons: [NSButton] = []
    private let messageActions = NSStackView()
    private let moreButton = NSButton(title: "加载更多", target: nil, action: nil)
    private var messages: [[String: Any]] = []
    private var selected: [String: Any]?
    private var nextPage: String?
    private var currentQuery = "in:inbox"
    private var email: String?
    private var enabled = true
    private var generation = 0
    private var process: Process?
    private var working = false
    private var deferredMenuCommand: String?
    private var composeWindow: GmailComposeWindow?
    var hasPendingWork: Bool { working }
    var menuCommands: [PluginMenuCommand] {
        [PluginMenuCommand(title: "打开", id: "open"), PluginMenuCommand(title: "刷新收件箱", id: "refresh"),
         PluginMenuCommand(title: "写邮件…", id: "compose"), .separator, PluginMenuCommand(title: "设置…", id: "settings")]
    }

    override init() {
        super.init()
        let toolbar = NSStackView(); toolbar.orientation = .horizontal; toolbar.spacing = 8
        search.placeholderString = "搜索邮件"
        search.toolTip = "支持 Gmail 搜索，例如 from:alice@example.com 或 is:unread"
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        search.target = self; search.action = #selector(searchMail)
        search.sendsSearchStringImmediately = false; search.sendsWholeSearchString = true
        toolbar.addArrangedSubview(search)
        for (name, action) in [("刷新", #selector(refresh)), ("写信", #selector(composeMail))] {
            let button = textButton(name, action)
            toolbar.addArrangedSubview(button); buttons.append(button)
        }
        for (name, action) in [("回复", #selector(replyMail)), ("归档", #selector(archiveMail))] {
            let button = textButton(name, action)
            messageActions.addArrangedSubview(button); buttons.append(button)
        }
        messageActions.orientation = .horizontal; messageActions.spacing = 16; messageActions.isHidden = true
        moreButton.target = self; moreButton.action = #selector(more); moreButton.isBordered = false
        moreButton.font = .systemFont(ofSize: 12); moreButton.isHidden = true; buttons.append(moreButton)
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 12); status.lineBreakMode = .byTruncatingTail
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mail")); column.title = "邮件"; column.width = 300
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 58; table.delegate = self; table.dataSource = self
        table.allowsEmptySelection = true
        table.backgroundColor = .clear; table.usesAlternatingRowBackgroundColors = false
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        FChrome.makeTransparent(list)
        reader.isEditable = false; reader.isSelectable = true; reader.isRichText = false
        reader.font = .systemFont(ofSize: 14); reader.textContainerInset = NSSize(width: 18, height: 18)
        reader.drawsBackground = false; reader.backgroundColor = .clear
        reader.autoresizingMask = [.width]; reader.isHorizontallyResizable = false; reader.textContainer?.widthTracksTextView = true
        let detail = NSScrollView(); detail.documentView = reader; detail.hasVerticalScroller = true
        FChrome.makeTransparent(detail)
        let listColumn = NSStackView(views: [list, moreButton]); listColumn.orientation = .vertical; listColumn.alignment = .centerX; listColumn.spacing = 8
        list.widthAnchor.constraint(equalTo: listColumn.widthAnchor).isActive = true
        let detailColumn = NSStackView(views: [messageActions, detail]); detailColumn.orientation = .vertical; detailColumn.alignment = .leading; detailColumn.spacing = 8
        detail.widthAnchor.constraint(equalTo: detailColumn.widthAnchor).isActive = true
        split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(listColumn); split.addArrangedSubview(detailColumn)
        let layout = NSStackView(views: [toolbar, status, split]); layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 10
        layout.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), layout.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            layout.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), layout.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            toolbar.widthAnchor.constraint(equalTo: layout.widthAnchor), status.widthAnchor.constraint(equalTo: layout.widthAnchor), split.widthAnchor.constraint(equalTo: layout.widthAnchor),
            listColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 140), detailColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        split.setPosition(300, ofDividerAt: 0)
        (view as? GmailWorkspaceView)?.onLayout = { [weak self] in
            guard let self else { return }
            let vertical = view.bounds.width >= 560
            guard split.isVertical != vertical else { return }
            split.isVertical = vertical
            split.adjustSubviews()
            split.setPosition(vertical ? min(300, view.bounds.width * 0.36) : min(180, view.bounds.height * 0.35), ofDividerAt: 0)
        }
    }

    private func textButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false; button.font = .systemFont(ofSize: 13)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func performMenuCommand(_ id: String) {
        guard id != "open" else { return }
        if working { deferredMenuCommand = id; return }
        switch id { case "settings": settings(); case "refresh": refresh(); case "compose": composeMail(); default: break }
    }
    private func resumeMenuCommand() {
        guard enabled, !working, let command = deferredMenuCommand else { return }
        deferredMenuCommand = nil; performMenuCommand(command)
    }
    func activate() {
        guard enabled, !working else { return }
        run(["action": "status"]) { [weak self] value in
            guard let self else { return }
            email = value["email"] as? String
            status.stringValue = email.map { "\($0) · 收件箱" } ?? "应用 → Gmail → 设置：导入客户端并连接 Google 账号"
            if value["connected"] as? Bool == true, deferredMenuCommand == nil { refresh() }
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { shutdown() }
    }
    func shutdown() {
        _ = saveDraft(); generation += 1
        deferredMenuCommand = nil
        process?.terminate(); process = nil; working = false
        composeWindow?.orderOut(nil)
        messages = []; selected = nil; email = nil; reader.string = ""; messageActions.isHidden = true; moreButton.isHidden = true; table.reloadData()
    }
    func confirmClose(_ completion: @escaping (Bool) -> Void) {
        if working { showError("Gmail 正在处理请求，请完成后再关闭插件或退出。"); completion(false) }
        else { completion(saveDraft()) }
    }
    func prepareToClose(_ completion: @escaping () -> Void) { _ = saveDraft(); completion() }
    func applyAppearance(dark: Bool) { view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
    @objc private func searchMail() { currentQuery = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); if currentQuery.isEmpty { currentQuery = "in:inbox" }; fetchPage(append: false) }
    @objc private func refresh() { fetchPage(append: false) }
    @objc private func more() { guard nextPage != nil else { return }; fetchPage(append: true) }
    private func fetchPage(append: Bool) {
        var args: [String: Any] = ["action": "search", "query": currentQuery, "limit": 25]
        if append, let nextPage { args["pageToken"] = nextPage }
        run(args) { [weak self] value in
            guard let self else { return }
            let page = value["messages"] as? [[String: Any]] ?? []
            messages = append ? messages + page : page
            nextPage = value["nextPageToken"] as? String
            moreButton.isHidden = nextPage == nil
            if !append { selected = nil; reader.string = ""; messageActions.isHidden = true; table.deselectAll(nil) }
            table.reloadData(); status.stringValue = "\(email ?? "Gmail") · \(messages.count) 封邮件" + (nextPage == nil ? "" : " · 可继续加载")
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { messages.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard messages.indices.contains(row) else { return nil }
        let message = messages[row]
        let cell = NSTableCellView(); let label = NSTextField(wrappingLabelWithString: "\(message["unread"] as? Bool == true ? "● " : "")\(message["subject"] as? String ?? "无主题")\n\(message["from"] as? String ?? "")")
        label.font = .systemFont(ofSize: 12); label.maximumNumberOfLines = 3; label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label); cell.textField = label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !working, messages.indices.contains(table.selectedRow), let id = messages[table.selectedRow]["id"] as? String else { return }
        run(["action": "read", "id": id]) { [weak self] message in
            guard let self else { return }
            selected = message
            messageActions.isHidden = false
            let attachments = (message["attachments"] as? [[String: Any]] ?? []).map { $0["filename"] as? String ?? "附件" }
            reader.string = "\(message["subject"] as? String ?? "")\n\n发件人：\(message["from"] as? String ?? "")\n收件人：\(message["to"] as? String ?? "")\n日期：\(message["date"] as? String ?? "")\n" + (attachments.isEmpty ? "" : "附件：" + attachments.joined(separator: "、") + "\n") + "\n\(message["text"] as? String ?? "")"
            run(["action": "modify", "id": id, "removeLabelIds": ["UNREAD"]]) { [weak self] _ in
                guard let self, let row = messages.firstIndex(where: { $0["id"] as? String == id }) else { return }
                messages[row]["unread"] = false; table.reloadData()
            }
        }
    }
    @objc private func archiveMail() {
        guard let id = selected?["id"] as? String else { return }
        run(["action": "modify", "id": id, "removeLabelIds": ["INBOX"]]) { [weak self] _ in self?.refresh() }
    }
    @objc private func composeMail() { openComposer(reply: nil) }
    @objc private func replyMail() { guard let selected else { return }; openComposer(reply: selected) }
    private var draftURL: URL { PluginStorage.directory(for: id).appendingPathComponent("draft.json") }
    private func openComposer(reply: [String: Any]?) {
        guard !working else { return }
        if let composeWindow { composeWindow.makeKeyAndOrderFront(nil); return }
        var draft: [String: Any] = [:]
        if let data = try? Data(contentsOf: draftURL), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { draft = value }
        if reply != nil, !draft.isEmpty {
            showError("已保留一封本地草稿，请先发送或清空草稿，再回复邮件。")
        } else if let reply {
            draft = ["replyToId": reply["id"] as? String ?? "", "to": reply["replyTo"] as? String ?? reply["from"] as? String ?? "", "subject": reply["subject"] as? String ?? ""]
            if (draft["to"] as? String ?? "").isEmpty { draft["to"] = reply["from"] }
        }
        let window = GmailComposeWindow(draft: draft); window.title = "写邮件 · \(email ?? "Gmail")"; window.delegate = self
        window.onSend = { [weak self, weak window] draft, action in
            guard let self, let window else { return }
            guard saveDraft() else { return }; window.setBusy(true)
            run(draft.merging(["action": action]) { _, new in new }, failure: { [weak window] in window?.setBusy(false) }) { [weak self, weak window] _ in
                guard let self else { return }
                do { if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) } }
                catch { showError("邮件已\(action == "draft" ? "保存到 Gmail 草稿" : "发送")，但本地草稿清理失败，请勿重复发送。") }
                window?.onSend = nil; composeWindow = nil; window?.close()
                status.stringValue = action == "draft" ? "已保存到 Gmail 草稿" : "邮件已发送"
            }
        }
        composeWindow = window; window.center(); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? GmailComposeWindow, window === composeWindow else { return }
        composeWindow = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !working && saveDraft() }
    @discardableResult private func saveDraft() -> Bool {
        guard let composeWindow else { return true }
        do {
            let value = composeWindow.draft
            if ["to", "cc", "bcc", "subject", "body"].allSatisfy({ (value[$0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) }
                return true
            }
            try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: value)
            try data.write(to: draftURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draftURL.path)
            return true
        } catch { showError("无法保存本地邮件草稿：\(error.localizedDescription)"); return false }
    }
    private func settings() {
        guard !working else { return }
        let alert = NSAlert(); alert.messageText = "Gmail 设置"
        alert.informativeText = "\(email ?? "尚未连接账号")\n导入 Google Cloud 的桌面应用 OAuth 客户端 JSON，再连接 Google 账号。凭据保存在 macOS 钥匙串。"
        for title in ["导入客户端…", "连接 Google 账号", "撤销授权并断开", "仅本机断开", "取消"] { alert.addButton(withTitle: title) }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                guard data.count < 1_000_000, let client = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NSError(domain: "Gmail", code: 1, userInfo: [NSLocalizedDescriptionKey: "客户端 JSON 无效"]) }
                run(["action": "configure", "client": client]) { [weak self] _ in self?.status.stringValue = "客户端已保存，再打开设置连接 Google 账号" }
            } catch { showError(error.localizedDescription) }
        case .alertSecondButtonReturn:
            status.stringValue = "请在浏览器完成 Google 授权（可用时长 3 分钟）"
            run(["action": "connect"]) { [weak self] value in self?.email = value["email"] as? String; self?.refresh() }
        case .alertThirdButtonReturn:
            disconnect(localOnly: false)
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3):
            disconnect(localOnly: true)
        default: break
        }
    }
    private func disconnect(localOnly: Bool) {
        run(["action": "disconnect", "localOnly": localOnly]) { [weak self] _ in
            self?.email = nil; self?.messages = []; self?.selected = nil; self?.reader.string = ""; self?.messageActions.isHidden = true; self?.moreButton.isHidden = true; self?.table.reloadData()
            self?.status.stringValue = localOnly ? "本机已断开；Google 授权仍可在账号安全页撤销" : "Google 授权已撤销，账号已断开"
        }
    }
    private func showError(_ message: String) { let alert = NSAlert(); alert.messageText = "Gmail"; alert.informativeText = message; alert.runModal() }

    // JSON travels through stdin, never shell interpolation or command-line credentials.
    private func run(_ input: [String: Any], failure: (() -> Void)? = nil, completion: @escaping ([String: Any]) -> Void) {
        guard enabled, !working else { failure?(); return }
        guard let cli = PiPaths.cliPath else { showError("找不到 F 的 Node 运行时"); failure?(); return }
        let node = PiPaths.nodeURL(for: cli)
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("runtime/harness/src/gmail/cli.mjs"), FileManager.default.fileExists(atPath: script.path) else { showError("Gmail 运行资源缺失，请重新安装 F 更新"); failure?(); return }
        let task = Process(), stdin = Pipe(), stdout = Pipe()
        task.executableURL = node; task.arguments = ["--use-env-proxy", script.path]
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        if environment["HTTPS_PROXY"] == nil, environment["https_proxy"] == nil,
           let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
           (settings["HTTPSEnable"] as? NSNumber)?.boolValue == true,
           let host = settings["HTTPSProxy"] as? String, let port = settings["HTTPSPort"] as? Int {
            var components = URLComponents(); components.scheme = "http"; components.host = host; components.port = port
            environment["HTTPS_PROXY"] = components.url?.absoluteString
        }
        environment["NO_PROXY"] = environment["NO_PROXY"] ?? "localhost,127.0.0.1,::1"
        task.environment = environment
        let token = generation
        do {
            let data = try JSONSerialization.data(withJSONObject: input)
            try task.run(); process = task; working = true; buttons.forEach { $0.isEnabled = false }; search.isEnabled = false; table.isEnabled = false
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Drain output while the child runs; large mail bodies cannot fill a pipe and deadlock.
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try stdin.fileHandleForWriting.write(contentsOf: data) } catch { }
                    try? stdin.fileHandleForWriting.close()
                }
                let output = stdout.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
                DispatchQueue.main.async { [weak self] in
                    guard let self, enabled, generation == token else { return }
                    process = nil; working = false; buttons.forEach { $0.isEnabled = true }; search.isEnabled = true; table.isEnabled = true
                    guard let response = try? JSONSerialization.jsonObject(with: output) as? [String: Any], response["ok"] as? Bool == true,
                          let value = response["value"] as? [String: Any] else {
                        let response = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any]
                        showError(response?["error"] as? String ?? "Gmail 请求未完成，请检查网络；发送中断时请先核对已发送邮件再重试。")
                        failure?(); resumeMenuCommand(); return
                    }
                    completion(value)
                    resumeMenuCommand()
                }
            }
        } catch { process = nil; working = false; showError(error.localizedDescription); failure?(); resumeMenuCommand() }
    }
}

private final class GmailWorkspaceView: NSView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

final class GmailComposeWindow: NSWindow {
    let to = NSTextField(), cc = NSTextField(), bcc = NSTextField(), subject = NSTextField(), body = NSTextView()
    let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let saveButton = NSButton(title: "存到 Gmail 草稿", target: nil, action: nil)
    var onSend: (([String: Any], String) -> Void)?
    private let replyToId: String?
    var draft: [String: Any] {
        var result: [String: Any] = ["to": to.stringValue, "cc": cc.stringValue, "bcc": bcc.stringValue, "subject": subject.stringValue, "body": body.string]
        if let replyToId { result["replyToId"] = replyToId }
        return result
    }
    init(draft: [String: Any]) {
        replyToId = draft["replyToId"] as? String
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; minSize = NSSize(width: 480, height: 360)
        let layout = NSStackView(); layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 10
        for (field, key, name) in [(to, "to", "收件人（逗号分隔）"), (cc, "cc", "抄送"), (bcc, "bcc", "密送"), (subject, "subject", "主题")] {
            field.placeholderString = name; field.stringValue = draft[key] as? String ?? ""; layout.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
        if replyToId != nil { to.isEditable = false; subject.isEditable = false }
        body.isRichText = false; body.font = .systemFont(ofSize: 14); body.string = draft["body"] as? String ?? ""; body.textContainerInset = NSSize(width: 8, height: 8)
        body.drawsBackground = false; body.backgroundColor = .clear
        body.autoresizingMask = [.width]; body.isHorizontallyResizable = false; body.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = body; scroll.hasVerticalScroller = true
        FChrome.makeTransparent(scroll)
        isOpaque = false
        backgroundColor = (AppearanceStore.dark ? NSColor.black : NSColor.white).withAlphaComponent(AppearanceStore.opacity)
        appearance = NSAppearance(named: AppearanceStore.dark ? .darkAqua : .aqua)
        for field in [to, cc, bcc, subject] { field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none }
        layout.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        sendButton.target = self; sendButton.action = #selector(sendMail); sendButton.bezelStyle = .rounded
        saveButton.target = self; saveButton.action = #selector(saveMail); saveButton.bezelStyle = .rounded
        let row = NSStackView(views: [sendButton, saveButton]); layout.addArrangedSubview(row)
        contentView!.addSubview(layout); layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([layout.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 18), layout.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor, constant: -18), layout.topAnchor.constraint(equalTo: contentView!.topAnchor, constant: 18), layout.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor, constant: -18)])
    }
    func setBusy(_ busy: Bool) {
        sendButton.isEnabled = !busy; saveButton.isEnabled = !busy; body.isEditable = !busy
        for field in [to, cc, bcc, subject] { field.isEnabled = !busy }
    }
    @objc private func sendMail() { onSend?(draft, replyToId == nil ? "send" : "reply") }
    @objc private func saveMail() { onSend?(draft, "draft") }
}
