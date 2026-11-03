import AppKit

/// Native entry is the sole opt-in boundary. Constructing/mounting/switching projects
/// does not even start a subprocess; the global plugin preference is not repository consent.
final class VersionsPlugin: NSObject, FPlugin, FProcessActivity {
    typealias Executor = ([String: Any], URL, @escaping ([String: Any]) -> Void) -> Void
    let id = "versions"
    let title = "版本"
    let symbol = "point.3.connected.trianglepath.dotted"
    let placement = PluginPlacement.workspace
    let projectAssociation = PluginProjectAssociation.project
    let view = NSView()
    private let graph = VersionGraphView()
    private let inspector = VersionInspectorView(frame: .zero)
    private let status = NSTextField(labelWithString: "")
    private var project: URL
    private var enabled = true
    private var activationRequested = false
    private var generation = UUID()
    private var running = false
    private var deferredRequest: [String: Any]?
    private let executor: Executor
    private(set) var hasPendingWork = false

    init(project: URL, executor: Executor? = nil) {
        self.project = project; self.executor = executor ?? Self.execute
        super.init()
        let scroll = VersionGraphScrollView(); scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.documentView = graph
        graph.setAccessibilityLabel("横向版本图，每个圆点固定一个提交，曲线连接真实父版本")
        graph.onSelect = { [weak self] node in
            guard let self, self.enabled else { return }
            self.inspector.load(node: node, project: self.project)
        }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.stringValue = "点击「版本」后自动记录此项目的版本"
        for child in [status, scroll, inspector] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        let minimum = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160); minimum.priority = .defaultHigh
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: view.topAnchor, constant: 18), status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: status.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: inspector.topAnchor, constant: -12), minimum,
            inspector.leadingAnchor.constraint(equalTo: status.leadingAnchor), inspector.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            inspector.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
    }

    var menuCommands: [PluginMenuCommand] {
        [.init(title: "打开", id: "open"), .init(title: "发布所选大版本到 GitHub…", id: "publish")]
    }
    func performMenuCommand(_ id: String) {
        guard enabled else { return }
        if id == "publish" { publish() }
        // Host routes `open` through activate; unknown/retired commands never mutate.
    }
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            generation = UUID(); deferredRequest = nil; activationRequested = false
            graph.display([]); inspector.reset()
        }
    }
    func shutdown() { setEnabled(false) }
    func activate() {
        guard enabled else { return }
        activationRequested = true
        run(["action": "status"])
    }
    func projectDidChange(_ project: URL) {
        guard self.project.standardizedFileURL != project.standardizedFileURL else { return }
        self.project = project; generation = UUID(); deferredRequest = nil; activationRequested = false
        graph.display([]); inspector.reset(); status.stringValue = project.lastPathComponent
    }
    func applyAppearance(dark: Bool) {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        graph.needsDisplay = true; graph.subviews.forEach { $0.needsDisplay = true }
    }
    func confirmClose(_ completion: @escaping (Bool) -> Void) {
        if hasPendingWork { status.stringValue = "请等待当前版本操作结束"; completion(false) }
        else { completion(true) }
    }

    private func publish() {
        guard !hasPendingWork, let selected = graph.selectedNode,
              selected["kind"] as? String == "major" || selected["major"] as? Bool == true,
              let version = selected["id"] as? String,
              let commit = selected["commit"] as? String ?? selected["head"] as? String,
              VersionGitReader.isObjectID(commit) else {
            status.stringValue = "请先选择一个已完成的大版本，再从应用菜单发布"; return
        }
        let token = generation
        let alert = NSAlert(); alert.messageText = "发布所选大版本到 GitHub"
        alert.informativeText = "仅上传固定提交 \(commit.prefix(12))。需要已有 GitHub 授权；不会上传未提交的工作区。"
        alert.addButton(withTitle: "授权并发布"); alert.addButton(withTitle: "取消")
        let repository = NSTextField(string: "")
        repository.placeholderString = "owner/repository（已有远程可留空）"
        repository.frame = NSRect(x: 0, y: 0, width: 360, height: 24); alert.accessoryView = repository
        guard alert.runModal() == .alertFirstButtonReturn, generation == token, enabled else { return }
        run(["action": "publish", "version": version, "repository": repository.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), "authorized": true])
    }

    private func run(_ values: [String: Any]) {
        guard enabled else { return }
        if running { deferredRequest = values; return }
        guard RemoteProjects.load(project) == nil else { status.stringValue = "远程项目请在 SSH 终端中管理 Git"; return }
        let token = generation, folder = project, action = values["action"] as? String ?? ""
        var request = values; request["project"] = folder.path
        running = true; hasPendingWork = action != "status"; status.stringValue = "正在读取版本…"
        executor(request, folder) { [weak self] output in
            // Always defer to the main loop, including in-process adapters.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false; self.hasPendingWork = false
                if self.generation == token, self.enabled {
                    if output["ok"] as? Bool == true {
                        if let state = output["value"] as? [String: Any], state["nodes"] != nil || state["versions"] != nil {
                            if state["enabled"] as? Bool == false {
                                self.graph.display([]); self.inspector.reset()
                                if self.activationRequested {
                                    self.activationRequested = false
                                    self.deferredRequest = ["action": "enable", "authorized": true]
                                }
                            } else {
                                self.activationRequested = false
                                // An explicitly empty versions array must stay empty. Only old
                                // backends without this key use their legacy branch/history nodes.
                                let nodes = state["versions"] as? [[String: Any]] ?? state["nodes"] as? [[String: Any]] ?? []
                                self.graph.display(nodes); self.graph.selectCurrent()
                                self.status.stringValue = nodes.isEmpty ? "等待 Agent 完成首次更新，版本将显示在这里" : folder.lastPathComponent
                                self.status.toolTip = folder.path
                            }
                        } else if action == "publish" { self.status.stringValue = "所选大版本已发布到 GitHub" }
                        else { self.deferredRequest = ["action": "status"] }
                    } else {
                        self.activationRequested = false
                        self.status.stringValue = output["error"] as? String ?? "版本操作失败"
                        self.status.toolTip = self.status.stringValue
                    }
                }
                if let deferred = self.deferredRequest, self.enabled {
                    self.deferredRequest = nil; self.run(deferred)
                }
            }
        }
    }

    private static func execute(_ request: [String: Any], project: URL, completion: @escaping ([String: Any]) -> Void) {
        guard let cli = PiPaths.cliPath else { completion(["ok": false, "error": "找不到 Agent 运行时"]); return }
        let source = URL(fileURLWithPath: cli).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("harness/src/versions/cli.mjs")
        let script = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? source.appendingPathComponent("harness/src/versions/cli.mjs")
        let node = source.appendingPathComponent("pi/runtime/node/bin/node")
        guard let input = try? JSONSerialization.data(withJSONObject: request) else { completion(["ok": false, "error": "无效版本请求"]); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(), pipe = Pipe(), stdin = Pipe()
            process.executableURL = node; process.arguments = [script.path]
            process.currentDirectoryURL = project; process.standardInput = stdin
            process.standardOutput = pipe; process.standardError = pipe
            do {
                try process.run(); stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                let output = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? ["ok": false, "error": "无法读取版本结果"]
                completion(output)
            } catch { completion(["ok": false, "error": error.localizedDescription]) }
        }
    }
}
