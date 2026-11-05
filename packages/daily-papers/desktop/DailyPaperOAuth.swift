import AppKit
import Foundation
import Network
import CryptoKit
import Security

struct DailyPaperOAuthClient: Codable {
    var clientID: String
    var clientSecret: String?
    static func parse(_ data: Data) throws -> DailyPaperOAuthClient {
        guard data.count <= 128_000,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = json["installed"] as? [String: Any],
              let id = installed["client_id"] as? String, id.hasSuffix(".apps.googleusercontent.com"), !id.contains(where: { $0.isWhitespace }),
              installed["auth_uri"] as? String == "https://accounts.google.com/o/oauth2/auth",
              installed["token_uri"] as? String == "https://oauth2.googleapis.com/token" else {
            throw DailyPaperError.message("请导入 Google Cloud 创建的桌面应用 OAuth 客户端 JSON（不是 Web 客户端）。")
        }
        return DailyPaperOAuthClient(clientID: id, clientSecret: installed["client_secret"] as? String)
    }
}

struct DailyPaperCredential: Codable {
    var client: DailyPaperOAuthClient
    var accessToken: String?
    var refreshToken: String?
    var expiry: Date?
}

enum DailyPaperKeychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "F.daily-paper.unbundled") + ".daily-paper.gmail", kSecAttrAccount as String: "desktop-oauth"] }
    static func load() throws -> DailyPaperCredential? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &item)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = item as? Data else { throw DailyPaperError.message("无法读取 Daily Paper Keychain 凭据（\(code)）。") }
        return try JSONDecoder().decode(DailyPaperCredential.self, from: data)
    }
    static func save(_ credential: DailyPaperCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes = [kSecValueData as String: data]
        let code = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound {
            var entry = query; entry[kSecValueData as String] = data; entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let inserted = SecItemAdd(entry as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw DailyPaperError.message("无法保存 Keychain 凭据（\(inserted)）。") }
        } else if code != errSecSuccess { throw DailyPaperError.message("无法更新 Keychain 凭据（\(code)）。") }
    }
    static func delete() throws {
        let code = SecItemDelete(query as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw DailyPaperError.message("无法删除 Keychain 凭据（\(code)）。") }
    }
}

final class DailyPaperOAuth {
    static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    let http: DailyPaperHTTP
    private(set) var credential: DailyPaperCredential?
    private var callback: DailyPaperLoopback?
    init(http: DailyPaperHTTP, credential: DailyPaperCredential? = nil) { self.http = http; self.credential = credential }
    func restore(using load: () throws -> DailyPaperCredential? = DailyPaperKeychain.load) throws { credential = try load() }
    var connected: Bool { credential?.refreshToken != nil || credential?.accessToken != nil }
    func importClient(_ data: Data) throws {
        guard !connected else { throw DailyPaperError.message("请先断开当前授权，再导入其他客户端。") }
        let next = DailyPaperCredential(client: try DailyPaperOAuthClient.parse(data))
        try DailyPaperKeychain.save(next); credential = next
    }
    func cancel() { callback?.cancel(); callback = nil }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DailyPaperError.message("无法创建安全随机数。") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func authorize() async throws {
        guard var next = credential else { throw DailyPaperError.message("请先导入自己的 Google 桌面 OAuth 客户端 JSON。") }
        let verifier = try Self.random(), state = try Self.random()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let callback = DailyPaperLoopback(state: state)
        self.callback = callback
        defer { callback.cancel(); if self.callback === callback { self.callback = nil } }
        let (code, redirect) = try await withTaskCancellationHandler(operation: {
            try await callback.wait { redirect in
                DailyPaperHTTP.url("https://accounts.google.com/o/oauth2/v2/auth", [
                    .init(name: "client_id", value: next.client.clientID), .init(name: "redirect_uri", value: redirect),
                    .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.scope),
                    .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
                    .init(name: "state", value: state), .init(name: "access_type", value: "offline"),
                    .init(name: "prompt", value: "consent"), .init(name: "include_granted_scopes", value: "false")
                ])
            }
        }, onCancel: { callback.cancel() })
        try Task.checkCancellation()
        var form = ["client_id": next.client.clientID, "code": code, "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier]
        if let secret = next.client.clientSecret { form["client_secret"] = secret }
        let result = try await http.json(URL(string: "https://oauth2.googleapis.com/token")!, form: form)
        try Task.checkCancellation()
        try apply(result, to: &next)
        guard next.refreshToken != nil else { throw DailyPaperError.message("Google 未返回离线 refresh token，请撤销旧授权后重新连接。") }
        try DailyPaperKeychain.save(next); credential = next
    }
    func accessToken() async throws -> String {
        guard var next = credential else { throw DailyPaperError.message("尚未连接 Gmail。") }
        if let token = next.accessToken, let expiry = next.expiry, expiry.timeIntervalSinceNow > 60 { return token }
        guard let refresh = next.refreshToken else { throw DailyPaperError.message("授权已过期，请重新连接 Gmail。") }
        var form = ["client_id": next.client.clientID, "refresh_token": refresh, "grant_type": "refresh_token"]
        if let secret = next.client.clientSecret { form["client_secret"] = secret }
        let result = try await http.json(URL(string: "https://oauth2.googleapis.com/token")!, form: form)
        try Task.checkCancellation(); try apply(result, to: &next)
        try DailyPaperKeychain.save(next); credential = next
        return next.accessToken!
    }
    private func apply(_ result: [String: Any], to credential: inout DailyPaperCredential) throws {
        guard let token = result["access_token"] as? String, !token.isEmpty else { throw DailyPaperError.message("Google 未返回 access token。") }
        if let scopes = result["scope"] as? String {
            let granted = Set(scopes.split(separator: " ").map(String.init))
            guard granted == [Self.scope] else { throw DailyPaperError.message("授权范围并非仅 Gmail readonly，拒绝保存。") }
        }
        credential.accessToken = token
        if let refresh = result["refresh_token"] as? String { credential.refreshToken = refresh }
        credential.expiry = Date().addingTimeInterval((result["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
    }
    func disconnect(revoke: Bool) async throws {
        if revoke, let token = credential?.refreshToken ?? credential?.accessToken {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(DailyPaperHTTP.form(["token": token]).utf8)
            _ = try await http.send(request, limit: 100_000)
        }
        try Task.checkCancellation(); try DailyPaperKeychain.delete(); credential = nil
    }
}

/// IPv4 loopback only. The browser callback is short-lived, state/Host/path checked,
/// never displays credentials, and cannot be reused after a successful callback.
private final class DailyPaperLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "F.daily-paper.oauth-loopback")
    private let lock = NSLock()
    private let state: String
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<(String, String), Error>?
    private var stopped = false
    private var redirect = ""
    init(state: String) { self.state = state }
    func wait(makeURL: @escaping (String) -> URL) async throws -> (String, String) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if stopped { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation; lock.unlock()
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                lock.lock(); self.listener = listener; let stopped = self.stopped; lock.unlock()
                if stopped { listener.cancel(); return }
                listener.stateUpdateHandler = { [weak self, weak listener] status in
                    guard let self else { return }
                    if case .ready = status, let port = listener?.port {
                        self.redirect = "http://127.0.0.1:\(port.rawValue)/oauth2callback"
                        let url = makeURL(self.redirect)
                        DispatchQueue.main.async {
                            if !NSWorkspace.shared.open(url) { self.finish(.failure(DailyPaperError.message("无法打开授权浏览器。"))) }
                        }
                    } else if case .failed = status { self.finish(.failure(DailyPaperError.message("无法启动 OAuth loopback 监听。"))) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
                    guard !stopped else { connection.cancel(); return }
                    // Bound concurrent local requests as well as request size.
                    if self.connections.count >= 8 { connection.cancel(); return }
                    self.connections.append(connection); connection.start(queue: self.queue)
                    self.receive(connection, bytes: Data())
                    self.queue.asyncAfter(deadline: .now() + 10) { connection.cancel(); self.connections.removeAll { $0 === connection } }
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 180) { [weak self] in self?.finish(.failure(DailyPaperError.message("Gmail 授权已超时，请重试。"))) }
            } catch { finish(.failure(error)) }
        }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<(String, String), Error>) {
        lock.lock(); stopped = true
        let continuation = self.continuation; self.continuation = nil
        let listener = self.listener; self.listener = nil
        lock.unlock()
        listener?.cancel()
        queue.async { self.connections.forEach { $0.cancel() }; self.connections.removeAll() }
        continuation?.resume(with: result)
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = bytes; bytes.append(data ?? Data())
            guard bytes.count <= 8192 else { connection.cancel(); return }
            if let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") { self.handle(text, connection: connection) }
            else if complete || error != nil { connection.cancel() }
            else { self.receive(connection, bytes: bytes) }
        }
    }
    private func handle(_ text: String, connection: NWConnection) {
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let expected = URLComponents(string: redirect)
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/oauth2callback?"),
              host == "127.0.0.1:\(expected?.port ?? 0)",
              let components = URLComponents(string: "http://127.0.0.1" + String(parts[1])), components.path == "/oauth2callback" else {
            reply(connection, ok: false, completion: {}); return
        }
        let items = components.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state else {
            reply(connection, ok: false, completion: {}); return
        }
        if items.contains(where: { $0.name == "error" }) {
            reply(connection, ok: false) { self.finish(.failure(DailyPaperError.message("用户取消或 Google 拒绝了授权。"))) }; return
        }
        guard items.filter({ $0.name == "code" }).count == 1, let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            reply(connection, ok: false, completion: {}); return
        }
        reply(connection, ok: true) { self.finish(.success((code, self.redirect))) }
    }
    private func reply(_ connection: NWConnection, ok: Bool, completion: @escaping () -> Void) {
        let body = ok ? "Authorization received. Return to F; token exchange is still being verified." : "Invalid or cancelled authorization. Return to F."
        let response = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel(); completion() })
    }
}
