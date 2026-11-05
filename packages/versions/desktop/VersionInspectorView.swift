import AppKit

/// Lives inside the Versions workspace, so no host routing or writable file editor is involved.
final class VersionInspectorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let summary = NSTextField(wrappingLabelWithString: "点击版本节点查看提交概述与文件。")
    private let provenance = NSTextField(wrappingLabelWithString: "")
    private let fileTitle = NSTextField(labelWithString: "提交文件")
    private let previewTitle = NSTextField(labelWithString: "只读版本预览")
    private let disclosure = NSButton(title: "▸ 文件与提交详情", target: nil, action: nil)
    private let details = NSView()
    private var preferredHeight: NSLayoutConstraint!
    private(set) var detailsExpanded = false
    private let table = NSTableView()
    private let text = NSTextView()
    private var files: [VersionSnapshotFile] = []
    private var snapshot: VersionSnapshot?
    private var project: URL?
    private var request = UUID()
    private var previewRequest = UUID()
    private var reader: VersionGitReader?

    override init(frame: NSRect) {
        super.init(frame: frame)
        summary.font = .systemFont(ofSize: 12); summary.isSelectable = true
        summary.identifier = NSUserInterfaceItemIdentifier("version-synopsis")
        summary.drawsBackground = false; summary.isBordered = false
        disclosure.setButtonType(.pushOnPushOff); disclosure.bezelStyle = .inline; disclosure.isBordered = false
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.font = .systemFont(ofSize: 11); disclosure.target = self; disclosure.action = #selector(toggleDetails)
        disclosure.setAccessibilityLabel("展开或收起固定提交文件与来源详情")
        details.isHidden = true
        table.backgroundColor = .clear
        summary.setContentCompressionResistancePriority(.required, for: .vertical)
        provenance.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        provenance.textColor = .secondaryLabelColor; provenance.isSelectable = true
        provenance.maximumNumberOfLines = 5; provenance.lineBreakMode = .byTruncatingMiddle
        fileTitle.font = .systemFont(ofSize: 11); fileTitle.textColor = .secondaryLabelColor
        previewTitle.font = .systemFont(ofSize: 11); previewTitle.textColor = .secondaryLabelColor
        previewTitle.lineBreakMode = .byTruncatingMiddle; previewTitle.isSelectable = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path")); column.width = 250
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 25
        table.delegate = self; table.dataSource = self; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("固定提交文件列表，选择后在右侧只读预览")
        let fileScroll = NSScrollView(); fileScroll.hasVerticalScroller = true
        fileScroll.drawsBackground = false; fileScroll.borderType = .noBorder; fileScroll.documentView = table
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.drawsBackground = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("固定提交文件内容，只读")
        let contentScroll = NSScrollView(); contentScroll.hasVerticalScroller = true
        contentScroll.drawsBackground = false; contentScroll.borderType = .noBorder; contentScroll.documentView = text
        let list = NSView(), preview = NSView(), split = NSSplitView()
        split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(list); split.addArrangedSubview(preview)
        for (container, caption, scroll) in [(list, fileTitle, fileScroll), (preview, previewTitle, contentScroll)] {
            for child in [caption, scroll] { child.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(child) }
            NSLayoutConstraint.activate([
                caption.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                caption.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
                caption.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 6),
                scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        list.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        let preferredWidth = list.widthAnchor.constraint(equalToConstant: 260); preferredWidth.priority = .defaultLow; preferredWidth.isActive = true
        preview.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        for child in [summary, disclosure, details] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        for child in [provenance, split] { child.translatesAutoresizingMaskIntoConstraints = false; details.addSubview(child) }
        preferredHeight = heightAnchor.constraint(equalToConstant: 112)
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredHeight,
            summary.topAnchor.constraint(equalTo: topAnchor), summary.leadingAnchor.constraint(equalTo: leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor),
            disclosure.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 10), disclosure.leadingAnchor.constraint(equalTo: leadingAnchor),
            details.topAnchor.constraint(equalTo: disclosure.bottomAnchor, constant: 8), details.leadingAnchor.constraint(equalTo: leadingAnchor),
            details.trailingAnchor.constraint(equalTo: trailingAnchor), details.heightAnchor.constraint(equalToConstant: 300),
            provenance.topAnchor.constraint(equalTo: details.topAnchor), provenance.leadingAnchor.constraint(equalTo: details.leadingAnchor),
            provenance.trailingAnchor.constraint(equalTo: details.trailingAnchor),
            split.topAnchor.constraint(equalTo: provenance.bottomAnchor, constant: 8), split.leadingAnchor.constraint(equalTo: details.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: details.trailingAnchor), split.bottomAnchor.constraint(equalTo: details.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleDetails() {
        detailsExpanded.toggle(); details.isHidden = !detailsExpanded
        disclosure.state = detailsExpanded ? .on : .off
        disclosure.title = (detailsExpanded ? "▾" : "▸") + " 文件与提交详情"
        preferredHeight.constant = detailsExpanded ? 420 : 112
        needsLayout = true
    }

    func reset() {
        request = UUID(); previewRequest = UUID(); reader?.cancel(); reader = nil
        snapshot = nil; project = nil; files = []; table.reloadData()
        summary.stringValue = "点击版本节点查看提交概述与文件。"; provenance.stringValue = ""
        text.string = ""; previewTitle.stringValue = "只读版本预览"; fileTitle.stringValue = "提交文件"
    }

    func load(node: [String: Any], project: URL) {
        reset(); self.project = project
        guard let hash = node["commit"] as? String ?? node["head"] as? String, VersionGitReader.isObjectID(hash) else {
            summary.stringValue = "此版本的工作树已移除或没有可读取的固定提交。请修复后刷新。"; return
        }
        let token = request, reader = VersionGitReader(project: project)
        self.reader = reader; summary.stringValue = "正在读取固定提交 \(hash.prefix(12))…"
        let id = node["id"] as? String ?? "", branch = node["branch"] as? String ?? ""
        let worktree = node["worktree"] as? String ?? ""
        let changes = node["changes"] as? String ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try reader.snapshot(hash: hash) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == token else { return }
                self.reader = nil
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot; self.files = snapshot.files; self.table.reloadData()
                    self.summary.stringValue = snapshot.synopsis
                    self.provenance.stringValue = "来源：Git commit \(snapshot.hash)\n父提交：\(snapshot.parents.isEmpty ? "无（初始提交）" : snapshot.parents.joined(separator: " · "))\n版本 ID：\(id)" + (branch.isEmpty ? "" : " · 分支：\(branch)") + (worktree.isEmpty ? "" : "\n工作树：\(worktree)") + (changes.isEmpty ? "" : " · 存在未提交改动（不含在此快照）")
                    self.provenance.toolTip = self.provenance.stringValue + "\n\n提交原文：\n" + snapshot.message + (changes.isEmpty ? "" : "\n\n工作树改动：\n" + changes)
                    let count = snapshot.files.filter { $0.change != nil }.count
                    self.fileTitle.stringValue = "提交文件 \(snapshot.files.count) · 变更路径 \(count)（优先）"
                    self.text.string = "选择左侧文件，查看固定提交内容。\n\n提交说明原文：\n" + snapshot.message
                case .failure(let error): self.summary.stringValue = error.localizedDescription
                }
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard files.indices.contains(row) else { return nil }
        let file = files[row], identifier = NSUserInterfaceItemIdentifier("version-file")
        let label = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        label.identifier = identifier; label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.stringValue = (file.change.map { "[\($0)] " } ?? "") + file.path
        label.toolTip = file.path; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard files.indices.contains(row), let project, let snapshot else { return }
        let file = files[row], token = UUID(), loadToken = request
        previewRequest = token; reader?.cancel()
        let reader = VersionGitReader(project: project); self.reader = reader
        previewTitle.stringValue = "只读 · \(snapshot.hash.prefix(12)) · \(file.path)"
        previewTitle.toolTip = "commit: \(snapshot.hash)\nblob: \(file.object ?? "已删除")\n\(file.path)"
        text.string = "正在读取提交文件…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try reader.contents(of: file) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == loadToken, self.previewRequest == token else { return }
                self.reader = nil
                switch result {
                case .success(let content): self.text.string = content
                case .failure(let error): self.text.string = error.localizedDescription
                }
                self.text.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }
    }
    deinit { reader?.cancel() }
}
