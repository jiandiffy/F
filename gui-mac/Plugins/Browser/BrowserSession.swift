import AppKit
import WebKit
import CryptoKit

/// F's browser and Daily Paper use one cookie/local-storage profile. No password
/// vault or Google private key is read, exported, or passed to the Agent.
final class FBrowserSession {
    static let shared = FBrowserSession(store: Bundle.main.bundleIdentifier == "local.f.app" ? .default() : .nonPersistent())
    let store: WKWebsiteDataStore
    private let views = NSHashTable<WKWebView>.weakObjects()
    private struct StorageImport { let id: String; let values: [String: String]; let removed: [String] }
    private var storage: [String: StorageImport] = [:]
    private var fingerprints: [String: String] = [:]
    private var originOrder: [String] = []
    private var importing = false
    private var waiting: [([String:Any], (Result<[String:Any],Error>) -> Void)] = []
    init(store: WKWebsiteDataStore) { self.store = store }
    static func origin(_ url: URL) -> String? {
        guard ["https", "http"].contains(url.scheme), let host = url.host, url.user == nil, url.password == nil else { return nil }
        return "\(url.scheme!)://\(host.lowercased())" + (url.port.map { ":\($0)" } ?? "")
    }
    static func address(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 8192 else { throw NSError(domain: "F Browser", code: 1, userInfo: [NSLocalizedDescriptionKey: "请输入网址或搜索内容。"] ) }
        let hasScheme = text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil
        let isAddress = hasScheme || (!text.contains(where: \.isWhitespace) && (text.contains(".") || text.hasPrefix("localhost")))
        if isAddress, let url = URL(string: hasScheme ? text : "https://" + text), origin(url) != nil { return url }
        if hasScheme || text.range(of: #"^(?:javascript|data|file|chrome|about):"#, options: [.regularExpression,.caseInsensitive]) != nil {
            throw NSError(domain: "F Browser", code: 2, userInfo: [NSLocalizedDescriptionKey: "仅支持 HTTP 或 HTTPS 网页，网址中不能含用户名或密码。"] )
        }
        var query = URLComponents(string: "https://www.google.com/search")!; query.queryItems = [URLQueryItem(name: "q", value: text)]
        return query.url!
    }
    static func googleAuthentication(_ url: URL) -> Bool { ["accounts.google.com", "accounts.google.cn"].contains(url.host?.lowercased() ?? "") }
    static func displayAddress(_ url: URL) -> String {
        if url.path == "/search", url.host?.range(of: #"(^|\.)google\.(com|[a-z]{2}|com\.[a-z]{2}|co\.[a-z]{2})$"#, options: .regularExpression) != nil,
           let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems?.first(where: { $0.name == "q" })?.value,
           let query = encoded.replacingOccurrences(of: "+", with: " ").removingPercentEncoding, !query.isEmpty {
            return query
        }
        return url.absoluteString
    }
    static func chrome(_ url: URL) {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else { NSWorkspace.shared.open(url) }
    }
    func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration(); config.websiteDataStore = store
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        installScripts(config.userContentController)
        return config
    }
    private func installScripts(_ controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: FBrowserTheme.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        for (origin, value) in storage { controller.addUserScript(storageScript(origin, value)) }
    }
    func attach(_ web: WKWebView) {
        views.add(web); web.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) { web.underPageBackgroundColor = .clear }
        web.allowsBackForwardNavigationGestures = true
    }
    private func storageScript(_ origin: String, _ value: StorageImport) -> WKUserScript {
        let literal = String(data: try! JSONSerialization.data(withJSONObject: ["origin": origin, "id":value.id,"values": value.values,"removed":value.removed]), encoding: .utf8)!
        return WKUserScript(source: "(()=>{const v=\(literal);if(location.origin===v.origin&&localStorage.getItem('__f_chrome_import_id')!==v.id){for(const k of v.removed)localStorage.removeItem(k);for(const [k,x] of Object.entries(v.values))localStorage.setItem(k,x);localStorage.setItem('__f_chrome_import_id',v.id)}})()", injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
    /// Only site session material sent by the locally installed Chrome bridge.
    /// Responses contain counts, never cookie values or authentication tokens.
    func importSession(_ value: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        if importing {
            guard waiting.count < 4 else { completion(.failure(error("登录同步繁忙，请稍后重试。"))); return }
            waiting.append((value,completion)); return
        }
        importing = true
        performImport(value) { [self] result in
            completion(result); importing = false
            if !waiting.isEmpty { let next = waiting.removeFirst(); importSession(next.0,completion:next.1) }
        }
    }
    private func performImport(_ value: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        do {
            guard let name = value["origin"] as? String, let url = URL(string: name), Self.origin(url) == name,
                  url.scheme == "https", let host = url.host, !Self.googleAuthentication(url),
                  host.range(of:#"(^|\.)google\.[a-z.]+$"#,options:.regularExpression) == nil,
                  let cookies = value["cookies"] as? [[String: Any]], cookies.count <= 200 else { throw error("登录会话来源无效；Google 密码与通行密钥由 Chrome 管理。") }
            let local = value["storage"] as? [String: String] ?? storage[name]?.values ?? [:]
            guard local.count <= 50, local.allSatisfy({ $0.key.count <= 512 && $0.value.utf8.count <= 65536 }), (try JSONSerialization.data(withJSONObject: local)).count <= 262144 else { throw error("网站登录会话过大。") }
            func allowed(_ domain: String) -> Bool {
                let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
                if ["alphaxiv.org", "www.alphaxiv.org"].contains(host) { return d == "alphaxiv.org" || ["www.alphaxiv.org", "api.alphaxiv.org"].contains(d) }
                return d == host || (d.contains(".") && host.hasSuffix("." + d))
            }
            let parsed = try cookies.map { item -> HTTPCookie in
                guard let domain = item["domain"] as? String, allowed(domain), let name = item["name"] as? String, !name.isEmpty,
                      let text = item["value"] as? String, name.utf8.count + text.utf8.count <= 16384,
                      let path = item["path"] as? String, path.hasPrefix("/") else { throw error("网站 Cookie 范围无效。") }
                var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: name, .value: text, .secure: (item["secure"] as? Bool == true ? "TRUE" : "FALSE")]
                if item["httpOnly"] as? Bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                if let expiry = item["expirationDate"] as? Double { properties[.expires] = Date(timeIntervalSince1970: expiry) }
                if let same = item["sameSite"] as? String { properties[HTTPCookiePropertyKey("SameSite")] = ["no_restriction": "None", "strict": "Strict", "lax": "Lax"][same] }
                guard let cookie = HTTPCookie(properties: properties) else { throw error("网站 Cookie 无效。") }; return cookie
            }
            func cookieKey(_ item: [String:Any]) -> String { (item["domain"] as? String ?? "") + ":" + (item["path"] as? String ?? "") + ":" + (item["name"] as? String ?? "") }
            let normalized = cookies.sorted { cookieKey($0) < cookieKey($1) }
            let digest = SHA256.hash(data:try JSONSerialization.data(withJSONObject:["cookies":normalized,"storage":local],options:.sortedKeys)).map { String(format:"%02x",$0) }.joined()
            if fingerprints[name] == digest, value["openURL"] == nil { completion(.success(["origin":name,"cookies":parsed.count,"storageEntries":local.count,"unchanged":true])); return }
            if !originOrder.contains(name) {
                if originOrder.count >= 16 { let old = originOrder.removeFirst(); storage.removeValue(forKey:old); fingerprints.removeValue(forKey:old) }
                originOrder.append(name)
            }
            let previousKeys = Array(storage[name]?.values.keys ?? Dictionary<String,String>().keys)
            let storageChanged = storage[name]?.values != local || value["openURL"] != nil
            let imported = StorageImport(id:UUID().uuidString,values:local,removed:previousKeys.filter { local[$0] == nil })
            store.httpCookieStore.getAllCookies { [self] existing in
                let group = DispatchGroup()
                for cookie in existing where allowed(cookie.domain) { group.enter(); store.httpCookieStore.delete(cookie) { group.leave() } }
                group.notify(queue: .main) { [self] in
                    let writes = DispatchGroup()
                    for cookie in parsed { writes.enter(); store.httpCookieStore.setCookie(cookie) { writes.leave() } }
                    writes.notify(queue: .main) { [self] in
                        fingerprints[name] = digest
                        if storageChanged { storage[name] = imported }
                        for web in views.allObjects {
                            installScripts(web.configuration.userContentController)
                            if let current = web.url, Self.origin(current) == name, let saved = storage[name] {
                                web.evaluateJavaScript(storageScript(name, saved).source) { [weak web] _, _ in if value["openURL"] != nil { web?.reload() } }
                            }
                        }
                        completion(.success(["origin": name, "cookies": parsed.count, "storageEntries": local.count]))
                    }
                }
            }
        } catch { completion(.failure(error)) }
    }
    private func error(_ text: String) -> NSError { NSError(domain: "F Browser", code: 3, userInfo: [NSLocalizedDescriptionKey: text]) }
}
