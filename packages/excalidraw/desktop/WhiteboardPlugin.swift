import AppKit
import AVKit
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

// MARK: - 白板（Excalidraw）

final class WhiteboardSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let path = (url.path.removingPercentEncoding ?? url.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relative = path.isEmpty ? "index.html" : path
        let fileURL = root.appendingPathComponent(relative).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"

        guard fileURL.path == root.path || fileURL.path.hasPrefix(rootPrefix) else {
            urlSchemeTask.didFailWithError(NSError(domain: "F.Whiteboard", code: 403))
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(NSError(domain: "F.Whiteboard", code: 404))
            return
        }

        let ext = fileURL.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "html", "htm": mime = "text/html"
        case "js", "mjs": mime = "text/javascript"
        case "css": mime = "text/css"
        case "json": mime = "application/json"
        case "svg": mime = "image/svg+xml"
        case "woff2": mime = "font/woff2"
        case "woff": mime = "font/woff"
        case "ttf": mime = "font/ttf"
        case "otf": mime = "font/otf"
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "webp": mime = "image/webp"
        case "wasm": mime = "application/wasm"
        default:
            mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }

        let response = URLResponse(
            url: url,
            mimeType: mime,
            expectedContentLength: data.count,
            textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

final class WhiteboardView: NSView, WKScriptMessageHandler {
    private let webView: WKWebView
    /// 输入框由窗口提供，在所有应用界面里停在同一个位置。
    weak var composer: GlassComposer?
    var onComposerVisibility: ((Bool) -> Void)?
    private let schemeHandler: WhiteboardSchemeHandler
    private var projectURL: URL
    private var sceneURL: URL?
    private var webReady = false
    private var pendingScene: [String: Any]?
    private var lastSceneData: Data?
    private var watchTimer: Timer?
    private var theme = "light"
    private var projectSwitchGeneration = 0
    private var conversationID = ""
    private var requestedProjectURL: URL
    private var requestedConversationID: String?
    private var viewGeneration = 0
    private struct PendingWrite {
        var object: [String: Any]
        let baseline: Data?
        let project: URL
        let baselineID: String?
        var reloadAfterSave: Bool
        var completions: [() -> Void]
    }
    private var pendingWrites: [URL: PendingWrite] = [:]
    private var writeRetries = Set<URL>()
    private var sceneBaselines: [String: Data] = [:]
    private var baselineOrder: [String] = []
    var hasPendingWrites: Bool { !pendingWrites.isEmpty }

    private func storageDirectory(for project: URL, conversation id: String) -> URL {
        ConversationBoards.directory(project: project, id: id)
    }

    func setConversation(_ id: String?, project: URL) {
        setDocument(project, conversation: id)
    }

    var draftText: String {
        get { composer?.draftText ?? "" }
        set { composer?.draftText = newValue }
    }
    var onPrompt: ((String) -> Void)?
    var onOpenConversation: (() -> Void)?

    init(project: URL) {
        projectURL = project
        requestedProjectURL = project
        // 尚未绑定对话时（单独打开画板或测试）使用项目稳定的占位画板，不混用其他对话。
        conversationID = ConversationBoards.id(for: "project:" + project.standardizedFileURL.path)
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let root = resources.appendingPathComponent("whiteboard", isDirectory: true)
        schemeHandler = WhiteboardSchemeHandler(root: root)

        let configuration = WKWebViewConfiguration()
        // All project data is native; bundled asset hashes must not outlive an app update.
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "fwb")
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: .zero)

        controller.add(self, name: "fwb")
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        addSubview(webView)

        if FileManager.default.fileExists(atPath: root.path),
           let url = URL(string: "fwb://app/index.html") {
            webView.load(URLRequest(url: url))
        } else {
            let label = NSTextField(wrappingLabelWithString:
                "白板资源缺失。请运行 ui/desktop/build.sh 重新打包 whiteboard。"
            )
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            addSubview(label)
        }

        loadProject(project)

        startWatching()
    }

    private func startWatching() {
        guard watchTimer == nil else { return }
        let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in self?.pollSceneFile() }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }
    func setPluginEnabled(_ enabled: Bool) {
        if enabled { reloadFromStorage(); startWatching() }
        else { watchTimer?.invalidate(); watchTimer = nil }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        watchTimer?.invalidate()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "fwb")
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
        subviews.compactMap { $0 as? NSTextField }.forEach {
            $0.frame = bounds.insetBy(dx: 36, dy: 140)
        }
    }

    func focus() {
        window?.makeFirstResponder(webView)
    }

    /// Project notifications may follow bindConversation while its flush is pending.
    /// Keep the bound conversation for this project; never rebind one that was already flushed.
    func setProject(_ url: URL) {
        let sameProject = requestedProjectURL.standardizedFileURL.path == url.standardizedFileURL.path
        setDocument(url, conversation: sameProject ? requestedConversationID : conversationID)
    }

    /// Flush the outgoing conversation even when both conversations share a project folder.
    private func setDocument(_ url: URL, conversation id: String?) {
        let resolved = url.standardizedFileURL
        let requestedID = id ?? ConversationBoards.id(for: "project:" + resolved.path)
        requestedProjectURL = resolved
        requestedConversationID = requestedID
        // Even A → B → A must invalidate B's still-pending flush callback.
        projectSwitchGeneration += 1
        let change = projectSwitchGeneration
        guard conversationID != requestedID || projectURL.path != resolved.path ||
              sceneURL != storageDirectory(for: resolved, conversation: requestedID).appendingPathComponent("scene.json") else {
            webView.isHidden = false
            composer?.canSend = true
            return
        }
        webView.isHidden = true
        composer?.canSend = false
        flushCurrentScene { [weak self] in
            guard let self, self.projectSwitchGeneration == change else { return }
            self.conversationID = requestedID
            self.loadProject(resolved)
            self.webView.isHidden = false
            self.composer?.canSend = true
        }
    }

    func flushCurrentScene(_ completion: @escaping () -> Void) {
        guard webReady, let document = sceneURL else { completion(); return }
        let baseline = lastSceneData
        let generation = viewGeneration
        webView.evaluateJavaScript("window.FWB.getDocumentSnapshot()") { [weak self] object, _ in
            if let self, self.viewGeneration == generation, self.sceneURL == document,
               let snapshot = object as? [String: Any], self.matchesCurrentView(snapshot),
               let object = snapshot["scene"] as? [String: Any] {
                self.persistViewport(snapshot["viewport"] as? [String: Any])
                // An Agent may have written a new revision before the WebKit view reloaded it.
                // Do not replace that newer file with an older in-memory scene.
                self.persistScene(Self.jsonString(object), baseline: baseline,
                    baselineID: snapshot["baselineID"] as? String, completion: completion)
                return
            }
            completion()
        }
    }

    /// 设置里改了保存位置后，立即从新位置重新加载当前对话的画板。
    func reloadFromStorage() {
        setDocument(requestedProjectURL, conversation: requestedConversationID)
    }

    private func saveBoardImage(base64: String, suggestedName: String?, format: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        let kind = format.lowercased()
        let panel = NSSavePanel()
        panel.title = "导出"
        panel.canCreateDirectories = true
        switch kind {
        case "jpg", "jpeg":
            panel.allowedContentTypes = [.jpeg]
            panel.nameFieldStringValue = suggestedName ?? "board.jpg"
        case "svg":
            panel.allowedContentTypes = [.svg]
            panel.nameFieldStringValue = suggestedName ?? "board.svg"
        case "pdf":
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = suggestedName ?? "board.pdf"
        default:
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = suggestedName ?? "board.png"
        }

        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            var payload = data
            if kind == "pdf" {
                guard let pdf = Self.makePDF(from: data) else {
                    self.setStatus("导出失败：无法生成 PDF", busy: false)
                    return
                }
                payload = pdf
            }
            do {
                try payload.write(to: url, options: .atomic)
                self.setStatus("已导出 \(url.lastPathComponent)", busy: false)
            } catch {
                self.setStatus("导出失败：\(error.localizedDescription)", busy: false)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    /// 单页 PDF，页面随内容比例裁切，不增加额外页边距。
    private static func makePDF(from imageData: Data) -> Data? {
        guard let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pixel = CGSize(width: cgImage.width, height: cgImage.height)
        guard pixel.width > 0, pixel.height > 0 else { return nil }
        let scale = 842 / max(pixel.width, pixel.height)
        let pageSize = CGSize(width: pixel.width * scale, height: pixel.height * scale)

        let output = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        context.beginPDFPage(nil)
        context.draw(cgImage, in: box)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }

    func connectOptions(to conversation: ConversationView) {
        guard let composer else { return }
        conversation.shareOptions(with: composer)
    }

    func setTheme(_ dark: Bool) {
        theme = dark ? "dark" : "light"
        jsCall("setTheme", theme)
    }

    func setStatus(_ text: String, busy: Bool) {
        js("window.FWB.setStatus(\(Self.jsonString(text)), \(busy ? "true" : "false"))")
    }

    func clearStatus() {
        composer?.canSend = true
        jsCall("setStatus", "")
    }

    func performMenuAction(_ action: String) {
        focus()
        jsCall("menuAction", action)
    }

    private func loadProject(_ url: URL) {
        let resolved = url.standardizedFileURL
        projectURL = resolved
        viewGeneration += 1

        // 每条对话一块画板，统一存在软件数据目录：<root>/<项目名>-<hash>/conversations/<对话>/scene.json
        BoardStore.migrateLegacyScene(for: resolved)
        guard !conversationID.isEmpty else { return }
        ConversationBoards.prepare(project: resolved, id: conversationID)
        let directory = storageDirectory(for: resolved, conversation: conversationID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("scene.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            let scene = ConversationBoards.blankScene(project: resolved)
            do {
                if let lock = try ProjectSceneWriter.acquireLock(for: file) {
                    defer { ProjectSceneWriter.releaseLock(lock) }
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try JSONSerialization.data(withJSONObject: scene, options: [.prettyPrinted, .sortedKeys])
                            .write(to: file, options: .atomic)
                    }
                }
            } catch {
                setStatus("创建画板失败：\(error.localizedDescription)", busy: false)
            }
        }

        sceneURL = file
        lastSceneData = nil
        reloadScene(fit: true)
        updateContext()
    }

    private func reloadScene(fit: Bool) {
        guard let sceneURL, let data = try? Data(contentsOf: sceneURL) else { return }
        lastSceneData = data
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        pendingScene = object
        if webReady {
            applyPendingScene(fit: fit)
        }
    }

    private func pollSceneFile() {
        guard let sceneURL, pendingWrites[sceneURL] == nil else { return }
        guard let data = try? Data(contentsOf: sceneURL) else {
            if !FileManager.default.fileExists(atPath: sceneURL.path) { loadProject(projectURL) }
            return
        }
        if let previous = lastSceneData, previous == data { return }
        lastSceneData = data
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        pendingScene = object
        if webReady {
            // 保留用户当前视角（滚动了画布不应被拽回去）
            applyPendingScene(fit: false)
        }
    }

    private func applyPendingScene(fit: Bool) {
        guard let scene = pendingScene else { return }
        pendingScene = nil
        // loadScene(scene, options): hand over the scene object itself, not an envelope.
        let baselineID = UUID().uuidString
        if let lastSceneData { sceneBaselines[baselineID] = lastSceneData; baselineOrder.append(baselineID) }
        if baselineOrder.count > 32 { sceneBaselines.removeValue(forKey: baselineOrder.removeFirst()) }
        var options: [String: Any] = ["fit": fit, "documentID": sceneURL?.path ?? "", "baselineID": baselineID,
            "conversationID": conversationID, "viewGeneration": viewGeneration]
        if fit, let file = viewportURL, let data = try? Data(contentsOf: file),
           let viewport = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           Self.validViewport(viewport) { options["viewport"] = viewport }
        js("window.FWB.loadScene(\(Self.jsonString(scene)), \(Self.jsonString(options)))")
    }

    private var viewportURL: URL? {
        conversationID.isEmpty ? nil
            : ConversationBoards.directory(project: projectURL, id: conversationID).appendingPathComponent("viewport.json")
    }

    private static func validViewport(_ value: [String: Any]) -> Bool {
        guard value["version"] as? Int == 1,
              let x = value["centerX"] as? Double, x.isFinite,
              let y = value["centerY"] as? Double, y.isFinite,
              let zoom = value["zoom"] as? Double, zoom.isFinite, (0.1...30).contains(zoom) else { return false }
        return true
    }

    private func matchesCurrentView(_ body: [String: Any]) -> Bool {
        body["documentID"] as? String == sceneURL?.path &&
            body["conversationID"] as? String == conversationID &&
            body["viewGeneration"] as? Int == viewGeneration
    }

    private func persistViewport(_ viewport: [String: Any]?) {
        guard let viewport, Self.validViewport(viewport), let file = viewportURL else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep only this version's private fields; never put viewport data in scene.json.
            let value = viewport.filter { ["version", "centerX", "centerY", "zoom"].contains($0.key) }
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: file, options: .atomic)
        } catch {
            setStatus("画板视角保存失败：\(error.localizedDescription)", busy: false)
        }
    }

    private func updateContext() {
        let name = projectURL.path == FileManager.default.homeDirectoryForCurrentUser.path
            ? "主目录"
            : projectURL.lastPathComponent
        let payload: [String: Any] = [
            "projectName": name,
            "projectPath": abbreviatedPath(projectURL.path),
            "scenePath": sceneURL.map { abbreviatedPath($0.path) } ?? "",
            "conversationID": conversationID,
        ]
        jsCall("setContext", payload)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func persistScene(_ json: String, baseline: Data? = nil, baselineID: String? = nil, reloadAfterSave: Bool = false, completion: (() -> Void)? = nil) {
        if let baselineID, sceneBaselines[baselineID] == nil { completion?(); return }
        guard let sceneURL,
              let incoming = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: incoming)) as? [String: Any]
        else { completion?(); return }
        if var pending = pendingWrites[sceneURL] {
            pending.object = object
            pending.reloadAfterSave = pending.reloadAfterSave || reloadAfterSave
            if let completion { pending.completions.append(completion) }
            pendingWrites[sceneURL] = pending
        } else {
            pendingWrites[sceneURL] = PendingWrite(object: object, baseline: baselineID.flatMap { sceneBaselines[$0] } ?? baseline ?? lastSceneData,
                project: projectURL, baselineID: baselineID, reloadAfterSave: reloadAfterSave,
                completions: completion.map { [$0] } ?? [])
        }
        flushPendingWrite(sceneURL)
    }

    private func flushPendingWrite(_ file: URL) {
        guard let pending = pendingWrites[file] else { return }
        do {
            switch try ProjectSceneWriter.save(pending.object, baseline: pending.baseline, to: file, project: pending.project) {
            case .busy:
                guard writeRetries.insert(file).inserted else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.writeRetries.remove(file); self?.flushPendingWrite(file)
                }
            case .saved(let data, let merged, let conflicted):
                pendingWrites.removeValue(forKey: file)
                // Until WebKit accepts a merged reload, its baseline is the
                // submitted local scene, which may not yet contain Agent edits.
                if let baselineID = pending.baselineID {
                    sceneBaselines[baselineID] = merged
                        ? try JSONSerialization.data(withJSONObject: pending.object) : data
                }
                jsCall("acknowledgeSave", ["documentID": file.path,
                    "baselineID": pending.baselineID as Any? ?? NSNull(), "scene": pending.object])
                if sceneURL == file {
                    lastSceneData = data
                    if merged || pending.reloadAfterSave { reloadScene(fit: false) }
                    if conflicted {
                        setStatus("并发修改已合并；冲突内容保存在项目画板 conflicts 目录。", busy: false)
                    }
                }
                pending.completions.forEach { $0() }
            }
        } catch {
            setStatus("白板保存失败：\(error.localizedDescription)", busy: false)
        }
    }

    private func js(_ code: String) {
        guard webReady else { return }
        webView.evaluateJavaScript(code, completionHandler: nil)
    }

    private func jsCall(_ function: String, _ value: Any) {
        js("window.FWB.\(function)(\(Self.jsonString(value)))")
    }

    private static func jsonString(_ value: Any) -> String {
        // Themes and status messages are scalar JSON values. Without fragmentsAllowed,
        // Foundation raises an Objective-C exception that try? cannot catch.
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return text
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "fwb", let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "ready":
            webReady = true
            js(FChrome.cssInjection)
            jsCall("setTheme", theme)
            updateContext()
            applyPendingScene(fit: true)
        case "viewport":
            if matchesCurrentView(body) { persistViewport(body["viewport"] as? [String: Any]) }
        case "change":
            if let scene = body["scene"] as? String, matchesCurrentView(body) {
                persistViewport(body["viewport"] as? [String: Any])
                persistScene(scene, baselineID: body["baselineID"] as? String,
                    reloadAfterSave: body["reloadAfterSave"] as? Bool == true)
            }
        case "modal":
            onComposerVisibility?(body["open"] as? Bool == true)
        case "prompt":
            if let text = body["text"] as? String, !text.isEmpty {
                onPrompt?(text)
            }
        case "saveImage":
            if let base64 = body["data"] as? String {
                saveBoardImage(
                    base64: base64,
                    suggestedName: body["name"] as? String,
                    format: body["format"] as? String ?? "png"
                )
            }
        case "openChat":
            onOpenConversation?()
        default:
            break
        }
    }
}


final class WhiteboardPlugin: FPlugin, FProcessActivity {
    var hasPendingWork: Bool { board.hasPendingWrites }
    let id = "whiteboard"
    let title = "画板"
    let symbol = "pencil.and.outline"
    let placement = PluginPlacement.workspace
    let projectAssociation = PluginProjectAssociation.project
    var menuCommands: [PluginMenuCommand] {
        [PluginMenuCommand(title: "导出…", id: "export"), PluginMenuCommand(title: "查找…", id: "search"),
         PluginMenuCommand(title: "快捷键…", id: "help"), .separator, PluginMenuCommand(title: "清空画板…", id: "clear")]
    }
    func performMenuCommand(_ id: String) { if id != "open" { board.performMenuAction(id) } }
    func setEnabled(_ enabled: Bool) { board.setPluginEnabled(enabled) }
    let board: WhiteboardView
    var view: NSView { board }
    init(project: URL) { board = WhiteboardView(project: project) }
    func projectDidChange(_ project: URL) { board.setProject(project) }
    func bindConversation(_ id: String?, project: URL) { board.setConversation(id, project: project) }
    func activate() { board.focus() }
    func applyAppearance(dark: Bool) { board.setTheme(dark) }
    func prepareToClose(_ completion: @escaping () -> Void) { board.flushCurrentScene(completion) }
}
