import AppKit
import WebKit

final class BrowserTab {
    let id = UUID().uuidString
    let web: WKWebView
    var snapshot: String?
    var snapshotURL: String?
    var requestedURL: URL?
    var loadError: String?
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration, changed: @escaping () -> Void) {
        web = WKWebView(frame: .zero, configuration: configuration)
        observations = [web.observe(\.title) { _, _ in changed() },
                        web.observe(\.url) { _, _ in changed() },
                        web.observe(\.isLoading) { _, _ in changed() },
                        web.observe(\.canGoBack) { _, _ in changed() },
                        web.observe(\.canGoForward) { _, _ in changed() }]
    }

    func close() {
        observations.removeAll()
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.removeFromSuperview()
    }
}

final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let browser: BrowserPlugin
    var onClose: (() -> Void)?

    init(browser: BrowserPlugin) {
        self.browser = browser
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.title = "F 浏览器"
        window.minSize = NSSize(width: 360, height: 240)
        window.appearance = browser.view.appearance
        window.contentView = browser.view
        window.delegate = self
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) {
        browser.shutdown()
        onClose?()
    }
}
