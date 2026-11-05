import Foundation

/// All background HTTP goes through this bounded, cookie-free, exact-host transport.
final class DailyPaperHTTP {
    static let hosts: Set<String> = ["gmail.googleapis.com", "oauth2.googleapis.com", "arxiv.org", "export.arxiv.org"]
    private let lock = NSLock()
    private var active: [UUID: DailyPaperRequest] = [:]
    private let responder: ((URLRequest) throws -> (Data, HTTPURLResponse))?
    init(responder: ((URLRequest) throws -> (Data, HTTPURLResponse))? = nil) { self.responder = responder }
    static func trusted(_ url: URL) -> Bool {
        url.scheme == "https" && hosts.contains(url.host?.lowercased() ?? "") && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
    private func register(_ id: UUID, _ operation: DailyPaperRequest) {
        lock.lock(); defer { lock.unlock() }; active[id] = operation
    }
    private func unregister(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }; active.removeValue(forKey: id)
    }
    func cancel() {
        lock.lock(); let pending = Array(active.values); lock.unlock()
        pending.forEach { $0.cancel() }
    }
    func send(_ request: URLRequest, limit: Int = 8_000_000) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, Self.trusted(url) else { throw DailyPaperError.message("拒绝非可信网络地址。") }
        try Task.checkCancellation()
        if let responder {
            let result = try responder(request)
            guard result.0.count <= limit else { throw DailyPaperError.message("网络响应超过安全大小限制。") }
            guard (200..<300).contains(result.1.statusCode) else { throw DailyPaperError.http(result.1.statusCode) }
            return result
        }
        let id = UUID(), operation = DailyPaperRequest(request: request, limit: limit)
        register(id, operation)
        defer { unregister(id) }
        let result = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await operation.start()
        }, onCancel: { operation.cancel() })
        guard (200..<300).contains(result.1.statusCode) else { throw DailyPaperError.http(result.1.statusCode) }
        return result
    }
    func json(_ url: URL, token: String? = nil, form: [String: String]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.form(form).utf8)
        }
        let (data, _) = try await send(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DailyPaperError.message("服务器未返回有效 JSON。") }
        return object
    }
    static func form(_ values: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return values.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + values[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
    }
    static func url(_ base: String, _ query: [URLQueryItem]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query
        return components.url!
    }
}

private final class DailyPaperRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let request: URLRequest
    let limit: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var redirects = 0
    init(request: URLRequest, limit: Int) { self.request = request; self.limit = limit }
    func start() async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
            config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            var request = self.request
            request.setValue("F-DailyPaper/1.0", forHTTPHeaderField: "User-Agent")
            let task = session.dataTask(with: request); self.task = task
            lock.unlock(); task.resume()
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil; self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard let url = request.url, DailyPaperHTTP.trusted(url), url.host == self.request.url?.host, redirects <= 3 else {
            completionHandler(nil); finish(.failure(DailyPaperError.message("拒绝跨主机或过多重定向。"))); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(DailyPaperError.message("网络响应过大或无效。"))); return
        }
        self.response = response; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= limit else { finish(.failure(DailyPaperError.message("网络响应超过安全大小限制。"))); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else if let response { finish(.success((bytes, response))) }
        else { finish(.failure(DailyPaperError.message("网络响应缺失。"))) }
    }
}
