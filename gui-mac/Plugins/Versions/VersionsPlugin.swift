import AppKit

/// The native surface and Agent tools use the same Git implementation and metadata.
/// Nothing is uploaded merely by opening this view.
final class VersionsPlugin: NSObject, FPlugin, FProcessActivity {
    let id = "versions"
    let title = "版本"
    let symbol = "point.3.connected.trianglepath.dotted"
    let placement = PluginPlacement.workspace
    let projectAssociation = PluginProjectAssociation.project
    let view = NSView()
    private let text = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private var project: URL
    private var enabled = true
    private var generation = UUID()
    private var running = false
    private var deferredRequest: [String: Any]?
    private(set) var hasPendingWork = false

    init(project: URL) {
        self.project = project
        super.init()
        let controls = NSStackView()
        controls.orientation = .horizontal; controls.spacing = 16
        for (name, action) in [("开启", #selector(enable)), ("分支", #selector(branch)), ("提交", #selector(commit)),
                               ("合并", #selector(merge)), ("GitHub", #selector(publish)), ("刷新", #selector(refresh))] {
            let button = NSButton(title: name, target: self, action: action)
            button.isBordered = false; button.font = .systemFont(ofSize: 12); controls.addArrangedSubview(button)
        }
        text.isEditable = false; text.isRichText = false; text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 0, height: 8)
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.documentView = text
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        for child in [controls, status, scroll] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.topAnchor, constant: 20), controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            status.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 14), status.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
    }

    var menuCommands: [PluginMenuCommand] {
        [.init(title: "打开", id: "open"), .init(title: "开启树状版本管理", id: "enable"),
         .init(title: "创建任务分支…", id: "branch"), .init(title: "提交文件…", id: "commit"),
         .init(title: "测试并合并…", id: "merge"), .init(title: "上传 GitHub…", id: "publish")]
    }
    func performMenuCommand(_ id: String) {
        guard enabled else { return }
        switch id {
        case "enable": enable()
        case "branch": branch()
        case "commit": commit()
        case "merge": merge()
        case "publish": publish()
        default: refresh()
        }
    }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled; if enabled { refresh() } }
    func activate() { refresh() }
    func projectDidChange(_ project: URL) {
        self.project = project; generation = UUID(); text.string = ""; status.stringValue = project.lastPathComponent
        if enabled { refresh() }
    }
    func applyAppearance(dark: Bool) {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        text.textColor = .labelColor
    }
    func confirmClose(_ completion: @escaping (Bool) -> Void) {
        if hasPendingWork { status.stringValue = "请等待当前版本操作结束"; completion(false) }
        else { completion(true) }
    }

    @objc private func enable() { run(["action": "enable"]) }
    @objc private func refresh() { if !running { run(["action": "status"], quiet: true) } }

    private func ask(_ title: String, fields: [(String, String)], submit: String = "继续") -> [String]? {
        guard !hasPendingWork else { return nil }
        let alert = NSAlert(); alert.messageText = title
        alert.addButton(withTitle: submit); alert.addButton(withTitle: "取消")
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        var inputs: [NSTextField] = []
        for (label, initial) in fields {
            let caption = NSTextField(labelWithString: label); caption.font = .systemFont(ofSize: 11); caption.textColor = .secondaryLabelColor
            let input = NSTextField(string: initial); input.translatesAutoresizingMaskIntoConstraints = false
            input.widthAnchor.constraint(equalToConstant: 360).isActive = true
            stack.addArrangedSubview(caption); stack.addArrangedSubview(input); inputs.append(input)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: fields.count * 54)
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return inputs.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    @objc private func branch() {
        guard let input = ask("创建任务分支", fields: [("名称", ""), ("父版本 ID", "root"), ("文件范围（逗号分隔）", "")]) else { return }
        run(["action": "branch", "label": input[0], "parent": input[1], "paths": splitPaths(input[2])])
    }
    @objc private func commit() {
        guard let input = ask("提交负责的文件", fields: [("版本 ID", "root"), ("提交说明", ""), ("文件范围（逗号分隔）", "")]) else { return }
        run(["action": "commit", "node": input[0], "message": input[1], "paths": splitPaths(input[2])])
    }
    @objc private func merge() {
        guard let input = ask("测试并合并至父版本", fields: [("子版本 ID", ""), ("测试命令（JSON 参数数组）", "[\"npm\",\"test\"]")]) else { return }
        guard let data = input[1].data(using: .utf8), let args = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            status.stringValue = "测试命令需为 JSON 字符串数组"; return
        }
        run(["action": "merge", "node": input[0], "test": args])
    }
    @objc private func publish() {
        guard let input = ask("上传已提交版本到 GitHub", fields: [("版本 ID", "root"), ("首次上传：owner/repository（创建私有仓库）", "")], submit: "上传") else { return }
        run(["action": "publish", "node": input[0], "repository": input[1], "authorized": true])
    }
    private func splitPaths(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func run(_ values: [String: Any], quiet: Bool = false) {
        guard enabled else { return }
        if running {
            if !quiet && !hasPendingWork { deferredRequest = values }
            return
        }
        guard RemoteProjects.load(project) == nil else { status.stringValue = "远程项目请在 SSH 终端中管理 Git"; return }
        guard let cli = PiPaths.cliPath else { status.stringValue = "找不到 Agent 运行时"; return }
        let source = URL(fileURLWithPath: cli).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("harness/src/versions/cli.mjs")
        let script = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? source.appendingPathComponent("harness/src/versions/cli.mjs")
        let node = source.appendingPathComponent("pi/runtime/node/bin/node")
        let token = generation, folder = project
        var request = values; request["project"] = folder.path
        guard let input = try? JSONSerialization.data(withJSONObject: request) else { return }
        running = true; hasPendingWork = !quiet; status.stringValue = "处理中…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process(), pipe = Pipe(), stdin = Pipe()
            process.executableURL = node; process.arguments = [script.path]
            process.currentDirectoryURL = folder; process.standardInput = stdin
            process.standardOutput = pipe; process.standardError = pipe
            var output: [String: Any]
            do {
                try process.run(); stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                output = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? ["ok": false, "error": "无法读取版本结果"]
            } catch { output = ["ok": false, "error": error.localizedDescription] }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false; self.hasPendingWork = false
                if let deferred = self.deferredRequest {
                    self.deferredRequest = nil
                    if self.generation == token { self.run(deferred); return }
                }
                guard self.generation == token, self.enabled else { if self.enabled { self.refresh() }; return }
                if output["ok"] as? Bool == true {
                    if let state = output["value"] as? [String: Any], let nodes = state["nodes"] as? [[String: Any]] {
                        self.render(nodes); self.status.stringValue = folder.lastPathComponent
                    } else { self.status.stringValue = "已完成"; self.refresh() }
                } else {
                    let error = output["error"] as? String ?? "版本操作失败"
                    self.status.stringValue = quiet && (error.contains("not a git repository") || error.contains("parent repositories")) ? "此文件夹尚未开启版本管理" : error
                    if !quiet { self.text.string = output["error"] as? String ?? "" }
                }
            }
        }
    }

    private func render(_ nodes: [[String: Any]]) {
        var lines: [String] = []
        func append(_ parent: String?, _ depth: Int) {
            for node in nodes where (node["parent"] as? String) == parent {
                let id = node["id"] as? String ?? "", indent = String(repeating: "    ", count: depth)
                lines.append(indent + (node["label"] as? String ?? id) + "  ·  " + (node["branch"] as? String ?? ""))
                lines.append(indent + "ID  " + id)
                if let worktree = node["worktree"] as? String { lines.append(indent + worktree) }
                if let changes = node["changes"] as? String, !changes.isEmpty { lines.append(indent + changes.replacingOccurrences(of: "\n", with: "\n" + indent)) }
                lines.append(""); append(id, depth + 1)
            }
        }
        append(nil, 0); text.string = lines.joined(separator: "\n")
    }
}
