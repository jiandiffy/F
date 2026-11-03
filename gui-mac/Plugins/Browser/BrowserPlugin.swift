import AppKit
import WebKit

private final class BrowserWorkspaceView: NSView {
    var layoutContent: (() -> Void)?
    var shortcut: ((NSEvent) -> Bool)?
    override func layout() { super.layout(); layoutContent?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !isHiddenOrHasHiddenAncestor, shortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class BrowserPlugin: NSObject, FPlugin, FProcessActivity, WKNavigationDelegate, WKUIDelegate {
    let id = "browser", title = "浏览器", symbol = "globe"
    let placement = PluginPlacement.workspace
    let view: NSView = BrowserWorkspaceView()
    let session: FBrowserSession
    let directory: URL
    private let addressGlass = makeGlassView(cornerRadius: 15, withBorder: false, material: .hudWindow)
    private let address = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedTab: BrowserTab?
    private(set) var windows: [BrowserWindowController] = []
    var web: WKWebView? { selectedTab?.web }
    private let managesBridge: Bool
    private let tabScroll = NSScrollView()
    private let tabList = NSView()
    private let back = SidebarButton(symbol: "chevron.left", label: "后退")
    private let forward = SidebarButton(symbol: "chevron.right", label: "前进")
    private let reload = SidebarButton(symbol: "arrow.clockwise", label: "刷新或停止载入")
    private let add = SidebarButton(symbol: "plus", label: "新建标签页")
    private let newWindowButton = SidebarButton(symbol: "macwindow.badge.plus", label: "新建浏览器窗口")
    private var enabled = false
    private var bridge: BrowserBridge?
    private var snapshot: String? { get { selectedTab?.snapshot } set { selectedTab?.snapshot = newValue } }
    private var snapshotURL: String? { get { selectedTab?.snapshotURL } set { selectedTab?.snapshotURL = newValue } }
    private var requestedURL: URL? { get { selectedTab?.requestedURL } set { selectedTab?.requestedURL = newValue } }
    private var loadError: String? { get { selectedTab?.loadError } set { selectedTab?.loadError = newValue } }
    var hasPendingWork: Bool { bridge?.hasPendingWork == true }
    override convenience init() { self.init(directory: PluginStorage.directory(for: "browser"), session: .shared) }
    init(directory: URL, session: FBrowserSession, managesBridge: Bool = true) {
        self.directory = directory; self.session = session; self.managesBridge = managesBridge; super.init()
        address.placeholderString = nil; address.isBordered = false; address.isBezeled = false; address.drawsBackground = false; address.focusRingType = .none
        address.setAccessibilityLabel("搜索或网址")
        address.font = .systemFont(ofSize: 14); address.target = self; address.action = #selector(navigate)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.isHidden = true
        for item in [addressGlass,address,status] { view.addSubview(item) }
        tabScroll.documentView = tabList; FChrome.makeTransparent(tabScroll)
        tabScroll.hasHorizontalScroller = true; tabScroll.scrollerStyle = .overlay
        for item in [back, forward, reload, tabScroll, add, newWindowButton] { view.addSubview(item) }
        for (button, command) in [(back,"back"),(forward,"forward"),(reload,"reload"),(add,"newTab"),(newWindowButton,"newWindow")] {
            button.identifier = NSUserInterfaceItemIdentifier(command); button.target = self; button.action = #selector(toolbarAction(_:))
        }
        (view as! BrowserWorkspaceView).layoutContent = { [weak self] in self?.layoutContent() }
        (view as! BrowserWorkspaceView).shortcut = { [weak self] in self?.handleShortcut($0) ?? false }
        refresh()
    }
    private func layoutContent() {
        let bounds = view.bounds
        let width = max(0, min(480, bounds.width - 2 * FChrome.corner))
        addressGlass.frame = NSRect(x: (bounds.width - width) / 2, y: bounds.height - 40, width: width, height: 30)
        addressGlass.isHidden = width < 64
        address.isHidden = addressGlass.isHidden
        address.frame = NSRect(x: addressGlass.frame.minX + 12, y: addressGlass.frame.minY + 4, width: max(0, width - 24), height: 22)
        let rowY = bounds.height - FChrome.toolbarHeight - 32
        for (i, button) in [back, forward, reload].enumerated() { button.frame = NSRect(x: 8 + CGFloat(i) * 30, y: rowY, width: 28, height: 28) }
        newWindowButton.frame = NSRect(x: max(0, bounds.width - 36), y: rowY, width: 28, height: 28)
        add.frame = NSRect(x: max(0, bounds.width - 68), y: rowY, width: 28, height: 28)
        tabScroll.frame = NSRect(x: 102, y: rowY, width: max(0, bounds.width - 174), height: 28)
        tabList.frame = NSRect(origin: .zero, size: NSSize(width: CGFloat(tabs.count) * 144, height: 28))
        web?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - FChrome.toolbarHeight - 36))
        let statusWidth = max(0, bounds.width - 48)
        let statusHeight = max(20, status.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: statusWidth, height: 1000)).height ?? 20)
        status.frame = NSRect(x: 24, y: max(0, rowY - statusHeight - 4), width: statusWidth, height: statusHeight)
    }
    var menuCommands: [PluginMenuCommand] { [.init(title:"打开",id:"open"),.init(title:"输入网址或搜索",id:"address"),.init(title:"新建标签页",id:"newTab"),.init(title:"关闭标签页",id:"closeTab"),.init(title:"新建浏览器窗口",id:"newWindow"),.init(title:"后退",id:"back"),.init(title:"前进",id:"forward"),.init(title:"重新载入",id:"reload"),.separator,.init(title:"在 Chrome 登录当前网站…",id:"login"),.init(title:"连接 Chrome…",id:"chrome")] }
    func performMenuCommand(_ id: String) {
        guard enabled else { return }
        switch id {
        case "address": address.selectText(nil)
        case "newTab": _ = newTab(); address.selectText(nil)
        case "closeTab": if let selectedTab { closeTab(selectedTab) }
        case "newWindow": _ = newWindow()
        case "back": web?.goBack()
        case "forward": web?.goForward()
        case "reload": loadError = nil; status.isHidden = true; web?.reload()
        case "login": if let url = web?.url { FBrowserSession.chrome(url); showStatus("在 Chrome 完成登录后，使用 F 登录桥接扩展同步本站会话。") }
        case "chrome": setupChrome()
        default: break
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        if value, managesBridge, Bundle.main.bundleIdentifier == "local.f.app", bridge == nil {
            do { let bridge = BrowserBridge(directory: directory); try bridge.start { [weak self] input, reply in self?.command(input, reply: reply) }; self.bridge = bridge }
            catch { showStatus(error.localizedDescription) }
        } else if !value { shutdown() }
    }
    func activate() { guard enabled else { return }; ensureWeb(); view.window?.makeFirstResponder(address) }
    func deactivate() {}
    func shutdown() {
        enabled = false; bridge?.stop(); bridge = nil
        let closing = windows; windows.removeAll(); for controller in closing { controller.close() }
        for tab in tabs { tab.close() }; tabs.removeAll(); selectedTab = nil
        refresh()
    }
    func applyAppearance(dark: Bool) {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if !managesBridge { view.window?.appearance = view.appearance }
        address.textColor = .labelColor
        for tab in tabs { tab.web.appearance = view.appearance }
        for controller in windows { controller.browser.applyAppearance(dark: dark) }
    }
    private func ensureWeb() {
        if web == nil { _ = newTab() }
    }
    @discardableResult func newTab(configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: configuration ?? session.configuration()) { [weak self] in self?.refresh() }
        let page = tab.web; session.attach(page)
        page.navigationDelegate = self; page.uiDelegate = self
        page.appearance = view.appearance
        tabs.append(tab); selectTab(tab)
        return tab
    }
    func selectTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if selectedTab === tab { return }
        selectedTab?.snapshot = nil; selectedTab?.web.removeFromSuperview()
        selectedTab = tab; tab.snapshot = nil
        view.addSubview(tab.web, positioned: .below, relativeTo: status)
        view.window?.makeFirstResponder(tab.web)
        refresh()
        tabList.scrollToVisible(NSRect(x: CGFloat(index) * 144, y: 0, width: 140, height: 28))
    }
    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if tabs.count == 1, !managesBridge { view.window?.close(); return }
        let selected = selectedTab === tab
        tab.close(); tabs.remove(at: index)
        if selected {
            selectedTab = nil
            if tabs.isEmpty { if enabled { _ = newTab() } }
            else { selectTab(tabs[min(index, tabs.count - 1)]) }
        }
        refresh()
    }
    @discardableResult func newWindow(configuration: WKWebViewConfiguration? = nil) -> BrowserPlugin {
        let browser = BrowserPlugin(directory: directory, session: session, managesBridge: false)
        browser.setEnabled(true); browser.applyAppearance(dark: ThemeColors.isDark(view.effectiveAppearance))
        let controller = BrowserWindowController(browser: browser)
        controller.onClose = { [weak self, weak controller] in self?.windows.removeAll { $0 === controller } }
        windows.append(controller); browser.newTab(configuration: configuration)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        return browser
    }
    private func refresh() {
        back.isEnabled = web?.canGoBack == true; forward.isEnabled = web?.canGoForward == true
        reload.image = NSImage(systemSymbolName: web?.isLoading == true ? "xmark" : "arrow.clockwise", accessibilityDescription: "刷新或停止载入")
        if address.currentEditor() == nil { address.stringValue = (requestedURL ?? web?.url).map(FBrowserSession.displayAddress) ?? "" }
        status.stringValue = loadError ?? ""; status.isHidden = loadError == nil
        for item in tabList.subviews { item.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let row = NSView(frame: NSRect(x: CGFloat(index) * 144, y: 0, width: 140, height: 28))
            let button = NSButton(title: String((tab.web.title?.isEmpty == false ? tab.web.title! : tab.web.url?.host ?? "新标签页").prefix(24)), target: self, action: #selector(selectTabButton(_:)))
            button.frame = NSRect(x: 0, y: 0, width: 116, height: 28)
            button.tag = index; button.bezelStyle = .recessed; button.setButtonType(.pushOnPushOff); button.state = tab === selectedTab ? .on : .off
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = tab.web.url?.absoluteString ?? "新标签页"
            let close = NSButton(title: "×", target: self, action: #selector(closeTabButton(_:)))
            close.frame = NSRect(x: 116, y: 0, width: 24, height: 28)
            close.tag = index; close.isBordered = false; close.setAccessibilityLabel("关闭标签页")
            row.addSubview(button); row.addSubview(close); tabList.addSubview(row)
        }
        layoutContent()
    }
    @objc private func selectTabButton(_ sender: NSButton) { selectTab(tabs[sender.tag]) }
    @objc private func closeTabButton(_ sender: NSButton) { closeTab(tabs[sender.tag]) }
    @objc private func toolbarAction(_ sender: NSButton) {
        if sender === reload, web?.isLoading == true { web?.stopLoading(); return }
        performMenuCommand(sender.identifier!.rawValue)
    }
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard enabled, event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shifted = event.modifierFlags.contains(.shift)
        switch key {
        case "l": performMenuCommand("address")
        case "t": performMenuCommand("newTab")
        case "n": performMenuCommand("newWindow")
        case "w": if shifted { return false }; performMenuCommand("closeTab")
        case "r": performMenuCommand("reload")
        case "[": performMenuCommand("back")
        case "]": performMenuCommand("forward")
        default: return false
        }
        return true
    }
    func open(_ url: URL) { guard enabled, FBrowserSession.origin(url) != nil else { return }; ensureWeb(); snapshot = nil; requestedURL = url; loadError = nil; address.stringValue = FBrowserSession.displayAddress(url); status.isHidden = true; web?.load(URLRequest(url: url)) }
    @objc private func navigate() { do { open(try FBrowserSession.address(address.stringValue)) } catch { showStatus(error.localizedDescription) } }
    private func showStatus(_ message: String) { status.stringValue = message; status.isHidden = false; layoutContent() }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if FBrowserSession.googleAuthentication(url) {
            if let tab = tabs.first(where: { $0.web === webView }) {
                tab.requestedURL = nil; tab.loadError = "Google 限制内嵌浏览器登录。可从浏览器菜单选择在 Chrome 登录，再同步本站会话。"
            }
            refresh(); decisionHandler(.cancel); return
        }
        let allowed = FBrowserSession.origin(url) != nil || url.absoluteString == "about:blank" || (action.targetFrame?.isMainFrame == false && ["blob","data"].contains(url.scheme))
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard enabled, let url = action.request.url, !FBrowserSession.googleAuthentication(url), FBrowserSession.origin(url) != nil || url.absoluteString == "about:blank" else { return nil }
        return newWindow(configuration: configuration).web
    }
    private func dialog(_ message: String, from webView: WKWebView, buttons: [String], input: NSTextField? = nil, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = webView.window else { completion(.abort); return }
        let alert = NSAlert(); alert.messageText = webView.url?.host ?? "网页提示"; alert.informativeText = message
        for title in buttons { alert.addButton(withTitle: title) }; alert.accessoryView = input
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        dialog(message, from: webView, buttons: ["好"]) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        dialog(message, from: webView, buttons: ["确定", "取消"]) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); input.stringValue = defaultText ?? ""
        dialog(prompt, from: webView, buttons: ["确定", "取消"], input: input) { completionHandler($0 == .alertFirstButtonReturn ? input.stringValue : nil) }
    }
    func webViewDidClose(_ webView: WKWebView) {
        if tabs.count == 1, !managesBridge { view.window?.close() }
        else if let tab = tabs.first(where: { $0.web === webView }) { closeTab(tab) }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.web === webView }) { tab.snapshot = nil; tab.loadError = nil }
        refresh()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.web === webView }) { tab.requestedURL = nil; tab.loadError = nil }
        refresh()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed(webView, NSError(domain: "F Browser", code: 4, userInfo: [NSLocalizedDescriptionKey: "网页进程已结束，请刷新重试。"] )) }
    private func failed(_ webView: WKWebView, _ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled, let tab = tabs.first(where: { $0.web === webView }) else { return }
        tab.requestedURL = nil; tab.snapshot = nil; tab.loadError = error.localizedDescription; refresh()
    }
    private func setupChrome() {
        let alert = NSAlert(); alert.messageText = "连接 Chrome 登录"; alert.informativeText = "本地扩展只将你选定网站的登录会话交给 F，密码与 Google 通行密钥仍由 Chrome 保管。先加载扩展目录，再填入 chrome://extensions 显示的扩展 ID。"
        let input = NSTextField(frame:NSRect(x:0,y:0,width:380,height:24)); input.placeholderString = "扩展 ID（可先留空以准备扩展目录）"; alert.accessoryView = input
        alert.addButton(withTitle:"准备连接"); alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let folder = try BrowserBridge.install(extensionID: input.stringValue.trimmingCharacters(in:.whitespacesAndNewlines))
            NSWorkspace.shared.open(folder); FBrowserSession.chrome(URL(string:"chrome://extensions")!)
            showStatus("在 Chrome 加载此目录中的 extension；扩展菜单可同步本站登录到 F。")
        } catch { showStatus(error.localizedDescription) }
    }
    func command(_ input: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard enabled else { reply(["ok":false,"error":"F 浏览器插件已停用"]); return }
        if input["action"] as? String == "importSession" {
            let request = input
            session.importSession(request) { [weak self] result in
                switch result {
                case .success(let value): if let text = request["openURL"] as? String, let url = URL(string:text), FBrowserSession.origin(url) == value["origin"] as? String { self?.open(url) }; reply(["ok":true,"value":value])
                case .failure(let error): reply(["ok":false,"error":error.localizedDescription])
                }
            }; return
        }
        let action = input["action"] as? String ?? ""
        if action == "tabs" {
            reply(["ok":true,"value":["tabs":tabs.map { ["id":$0.id,"title":$0.web.title ?? "新标签页","selected":$0 === selectedTab] as [String:Any] }]]); return
        }
        if action == "newTab" { _ = newTab() }
        if let id = input["tabId"] as? String {
            guard let tab = tabs.first(where: { $0.id == id }) else { reply(["ok":false,"error":"标签页已关闭"]); return }
            selectTab(tab)
        }
        if action == "closeTab", let selectedTab { closeTab(selectedTab); reply(["ok":true,"value":["closed":true]]); return }
        if action == "selectTab" || action == "newTab" {
            guard let selectedTab else { reply(["ok":false,"error":"请指定有效的标签页"]); return }
            reply(["ok":true,"value":["tabId":selectedTab.id]]); return
        }
        if input["action"] as? String == "open", let text = input["url"] as? String {
            do { let url = try FBrowserSession.address(text); open(url); reply(["ok":true,"value":["url":url.absoluteString,"loading":true,"tabId":selectedTab!.id]]) } catch { reply(["ok":false,"error":error.localizedDescription]) }; return
        }
        ensureWeb(); guard let web else { reply(["ok":false,"error":"浏览器尚未就绪"]); return }
        if ["back","forward","reload"].contains(action) { loadError = nil; performMenuCommand(action) }
        if ["state","read","back","forward","reload"].contains(action) {
            if let loadError { reply(["ok":false,"error":loadError]); return }
            if web.isLoading || requestedURL != nil || web.url == nil {
                snapshot = nil
                reply(["ok":true,"value":["loading":web.isLoading || requestedURL != nil,"text":"","links":[],"tabId":selectedTab!.id,"canGoBack":web.canGoBack,"canGoForward":web.canGoForward,"profilePersistent":session.store.isPersistent]]); return
            }
            let token = UUID().uuidString; snapshot = token
            let script = "(()=>{const clean=x=>{try{const u=new URL(x,location.href);for(const k of Array.from(u.searchParams.keys()))if(/token|password|secret|^code$|^state$|^session$/i.test(k))u.searchParams.delete(k);if(/token|secret|password/i.test(u.hash))u.hash='';return u.href}catch{return ''}};return{snapshot:'\(token)',url:clean(location.href),title:document.title,loading:document.readyState,text:(document.body?.innerText??'').slice(0,50000),links:Array.from(document.querySelectorAll('a[href],button,input:not([type=password]):not([type=hidden]),textarea,select')).slice(0,300).map((e,i)=>{e.setAttribute('data-f-browser-id',String(i));return{id:i,tag:e.tagName,label:(e.innerText||e.getAttribute('aria-label')||e.getAttribute('placeholder')||e.getAttribute('name')||'').slice(0,300),href:e.tagName==='A'?clean(e.href):undefined}})}})()"
            let tab = selectedTab!, url = web.url
            web.evaluateJavaScript(script) { [weak self, weak web] value,error in
                guard self?.selectedTab === tab, tab.snapshot == token, web?.url == url else { reply(["ok":false,"error":"页面已变化，请重新读取页面再操作"]); return }
                tab.snapshotURL = web?.url?.absoluteString
                var state = value as? [String:Any] ?? [:]; state["profilePersistent"] = self?.session.store.isPersistent ?? false
                state["tabId"] = tab.id; state["canGoBack"] = web?.canGoBack ?? false; state["canGoForward"] = web?.canGoForward ?? false
                reply(error.map { ["ok":false,"error":$0.localizedDescription] } ?? ["ok":true,"value":state])
            }; return
        }
        if ["click","fill"].contains(action), let target = input["target"] as? Int, (0..<300).contains(target) {
            guard input["snapshot"] as? String == snapshot, snapshot != nil, web.url?.absoluteString == snapshotURL else { reply(["ok":false,"error":"页面已变化，请重新读取页面再操作"]); return }
            snapshot = nil
            let text = input["text"] as? String ?? ""
            guard text.utf8.count <= 16000 else { reply(["ok":false,"error":"输入过长"]); return }
            let literal = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding:.utf8)!
            let script = "(()=>{const e=document.querySelector('[data-f-browser-id=\"\(target)\"]');if(!e||e.type==='password'||e.type==='hidden')throw Error('请重新读取页面；密码请在 F 网页中手动输入');\(action == "click" ? "e.click()" : "e.value=\(literal)[0];e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}))");return {done:true}})()"
            web.evaluateJavaScript(script) { value,error in reply(error.map { ["ok":false,"error":$0.localizedDescription] } ?? ["ok":true,"value":value ?? [:]]) }; return
        }
        reply(["ok":false,"error":"不支持的浏览器操作"])
    }
}
