import Foundation
import CryptoKit
import ImageIO
#if canImport(FoundationXML)
import FoundationXML
#endif

final class DailyPaperSync {
    let http: DailyPaperHTTP
    let oauth: DailyPaperOAuth
    let store: DailyPaperStore
    var onStatus: ((String) -> Void)?
    init(http: DailyPaperHTTP, oauth: DailyPaperOAuth, store: DailyPaperStore) { self.http = http; self.oauth = oauth; self.store = store }
    private func gmail(_ path: String, _ query: [URLQueryItem] = []) async throws -> [String: Any] {
        try Task.checkCancellation()
        return try await http.json(DailyPaperHTTP.url("https://gmail.googleapis.com/gmail/v1/users/me/" + path, query), token: oauth.accessToken())
    }
    /// Returns a transaction candidate. The caller saves it atomically before adopting it.
    func run(_ previous: DailyPaperState) async throws -> (DailyPaperState, [String]) {
        try previous.settings.validate()
        let profile = try await gmail("profile")
        guard let account = profile["emailAddress"] as? String, let snapshot = profile["historyId"] as? String else { throw DailyPaperError.message("Gmail profile 响应缺少账户或 historyId。") }
        var next = previous
        var library = DailyPaperLibrary(previous.records)
        var cursor = previous.account == account ? previous.historyID : nil
        next.account = account
        var ids: Set<String>
        var ordered: [String] = []
        var finalHistory = snapshot
        if let start = cursor {
            do { (ids, finalHistory) = try await history(start: start, settings: previous.settings) }
            catch DailyPaperError.http(404) { cursor = nil; ids = [] }
        } else { ids = [] }
        if previous.account == account { ids.formUnion(previous.pendingMessageIDs ?? []) }
        // Gmail history has no sender query. Intersect with a scoped list before any
        // body fetch, never inspect every mailbox message just to filter a sender.
        if cursor == nil || !previous.settings.sender.isEmpty {
            let scoped = try await list(settings: previous.settings)
            ids = cursor == nil ? Set(scoped) : ids.intersection(scoped)
            ordered = scoped.filter { ids.contains($0) }
        }
        if ordered.isEmpty { ordered = ids.sorted() }
        let batch = Array(ordered.prefix(20))
        next.pendingMessageIDs = Array(ordered.dropFirst(batch.count))
        var warnings: [String] = []
        var attemptedMetadata = Set<String>()
        var metadataRequests = 0
        for (index, id) in batch.enumerated() {
            try Task.checkCancellation()
            onStatus?("正在读取推送 \(index + 1)/\(batch.count)…")
            guard id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw DailyPaperError.message("Gmail 返回无效邮件 ID。") }
            let metadata = try await gmail("messages/" + id, [.init(name: "format", value: "metadata"), .init(name: "metadataHeaders", value: "From")])
            guard previous.settings.matches(metadata) else { continue }
            let message = try await gmail("messages/" + id, [.init(name: "format", value: "full")])
            guard previous.settings.matches(message) else { continue }
            for var record in DailyPaperParser.records(from: message, account: account) {
                // Existing complete metadata can be reused; a new version is still fetched.
                if let old = library.record(id: record.id), old.sourceURLs.contains(record.sourceURLs[0]), old.title != old.id {
                    library.merge(record); continue
                }
                // Keep parsed references while limiting public metadata requests
                // per explicit sync; later syncs resume the incomplete records.
                if metadataRequests >= 10 {
                    library.merge(record); continue
                }
                attemptedMetadata.insert(record.id)
                metadataRequests += 1
                do { record = try await enrich(record, warnings: &warnings) }
                catch is CancellationError { throw CancellationError() }
                catch { warnings.append("\(record.id) 元数据：\(error.localizedDescription)") } // Keep real identifiers; report why enrichment failed.
                library.merge(record)
            }
        }
        // Metadata failures must not strand a paper after the Gmail cursor advances.
        // Retry a bounded batch on every explicit sync, including empty history.
        let incomplete = library.records.filter { $0.id.hasPrefix("arxiv:") && ($0.title == $0.id || $0.abstract.isEmpty) && !attemptedMetadata.contains($0.id) }
            .sorted { ($0.latestMailDate ?? .distantPast) > ($1.latestMailDate ?? .distantPast) }
        for record in incomplete.prefix(max(0, 10 - metadataRequests)) {
            try Task.checkCancellation()
            onStatus?("正在重试论文元数据：\(record.id)…")
            do { library.merge(try await enrich(record, warnings: &warnings)) }
            catch is CancellationError { throw CancellationError() }
            catch { warnings.append("\(record.id) 元数据：\(error.localizedDescription)") }
        }
        try Task.checkCancellation()
        next.records = library.records
        next.historyID = finalHistory; next.lastSync = Date()
        return (next, warnings)
    }
    private func list(settings: DailyPaperSettings) async throws -> [String] {
        var result: [String] = [], added = Set<String>(), page: String?, seen = Set<String>()
        repeat {
            var query: [URLQueryItem] = [.init(name: "maxResults", value: "100"), .init(name: "includeSpamTrash", value: "false")]
            if !settings.labelID.isEmpty { query.append(.init(name: "labelIds", value: settings.labelID)) }
            if !settings.sender.isEmpty { query.append(.init(name: "q", value: "from:" + settings.sender)) }
            if let page { query.append(.init(name: "pageToken", value: page)) }
            let object = try await gmail("messages", query)
            for message in object["messages"] as? [[String: Any]] ?? [] {
                if let id = message["id"] as? String, added.insert(id).inserted { result.append(id) }
            }
            page = object["nextPageToken"] as? String
            if let page, !seen.insert(page).inserted { throw DailyPaperError.message("Gmail 分页令牌重复，断点未推进。") }
        } while page != nil
        return result
    }
    private func history(start: String, settings: DailyPaperSettings) async throws -> (Set<String>, String) {
        var ids = Set<String>(), page: String?, latest = start, seen = Set<String>()
        repeat {
            var query: [URLQueryItem] = [.init(name: "startHistoryId", value: start), .init(name: "maxResults", value: "100"), .init(name: "historyTypes", value: "messageAdded"), .init(name: "historyTypes", value: "labelAdded")]
            if !settings.labelID.isEmpty { query.append(.init(name: "labelId", value: settings.labelID)) }
            if let page { query.append(.init(name: "pageToken", value: page)) }
            let object = try await gmail("history", query)
            guard let history = object["historyId"] as? String else { throw DailyPaperError.message("Gmail history 响应缺少断点。") }
            latest = history
            for event in object["history"] as? [[String: Any]] ?? [] {
                for kind in ["messagesAdded", "labelsAdded"] {
                    for change in event[kind] as? [[String: Any]] ?? [] {
                        if let message = change["message"] as? [String: Any], let id = message["id"] as? String { ids.insert(id) }
                    }
                }
            }
            page = object["nextPageToken"] as? String
            if let page, !seen.insert(page).inserted { throw DailyPaperError.message("Gmail history 分页令牌重复。") }
        } while page != nil
        return (ids, latest)
    }
    private func enrich(_ input: DailyPaperRecord, warnings: inout [String]) async throws -> DailyPaperRecord {
        guard input.id.hasPrefix("arxiv:"), let absURL = input.sourceURLs.first(where: { $0.host == "arxiv.org" }) else { return input }
        let identifier = absURL.path.replacingOccurrences(of: "/abs/", with: "")
        let url = DailyPaperHTTP.url("https://export.arxiv.org/api/query", [.init(name: "id_list", value: identifier)])
        let (data, _) = try await http.send(URLRequest(url: url), limit: 2_000_000)
        var record = input
        let metadata = try DailyPaperAtom.parse(data)
        guard let identifierURL = metadata["id"], DailyPaperParser.references(identifierURL).first?.id == input.id else { throw DailyPaperError.message("arXiv 返回了不同论文，拒绝混入元数据。") }
        if let title = metadata["title"], !title.isEmpty { record.title = title }
        record.authors = metadata["authors"]?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        record.abstract = metadata["summary"] ?? ""
        if let id = metadata["id"], let reference = DailyPaperParser.references(id).first {
            if !record.sourceURLs.contains(reference.url) { record.sourceURLs.append(reference.url) }
            if let version = reference.version, !record.versions.contains(version) { record.versions.append(version) }
        }
        if let doi = metadata["doi"], let reference = DailyPaperParser.references("doi:" + doi).first, !record.sourceURLs.contains(reference.url) { record.sourceURLs.append(reference.url) }
        // Figures only come from the official paper HTML, never an email <img> URL.
        do { record = try await figure(record, identifier: identifier) }
        catch is CancellationError { throw CancellationError() }
        catch { warnings.append("\(record.id) 原图：\(error.localizedDescription)") }
        return record
    }
    static func figureURL(html: String, base: URL) -> URL? {
        for figure in DailyPaperParser.matches(#"<figure\b[^>]*>(.*?)</figure>"#, in: html, group: 1) {
            for raw in DailyPaperParser.matches(#"<img\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)[\"']"#, in: figure, group: 1) {
                let bases = [base, URL(string: base.absoluteString + "/")!]
                for relativeBase in bases {
                    guard let url = URL(string: raw, relativeTo: relativeBase)?.absoluteURL,
                          DailyPaperHTTP.trusted(url), url.host == "arxiv.org", url.query == nil, url.fragment == nil,
                          ["png", "jpg", "jpeg", "webp"].contains(url.pathExtension.lowercased()),
                          url.standardized.path.hasPrefix(base.path + "/") else { continue }
                    return url
                }
            }
        }
        return nil
    }
    private func figure(_ input: DailyPaperRecord, identifier: String) async throws -> DailyPaperRecord {
        let base = URL(string: "https://arxiv.org/html/" + identifier)!
        let (htmlData, _) = try await http.send(URLRequest(url: base), limit: 6_000_000)
        guard let html = String(data: htmlData, encoding: .utf8), let imageURL = Self.figureURL(html: html, base: base) else { return input }
        let (imageData, response) = try await http.send(URLRequest(url: imageURL), limit: 8_000_000)
        guard ["image/png", "image/jpeg", "image/webp"].contains(response.mimeType ?? ""),
              let source = CGImageSourceCreateWithData(imageData as CFData, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 32, height.intValue > 32, width.intValue <= 8192, height.intValue <= 8192, width.intValue * height.intValue <= 24_000_000 else { return input }
        try Task.checkCancellation()
        let key = SHA256.hash(data: Data(imageURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        var record = input; record.imageFile = try store.saveImage(imageData, key: key); record.imageURL = imageURL
        return record
    }
}

private final class DailyPaperAtom: NSObject, XMLParserDelegate {
    private var path: [String] = []
    private var entry = false
    private var complete = false
    private var field = ""
    private var text = ""
    private var values: [String: String] = [:]
    static func parse(_ data: Data) throws -> [String: String] {
        let delegate = DailyPaperAtom(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.complete, delegate.values["title"] != "Error", delegate.values["id"]?.contains("arxiv.org/abs/") == true else { throw DailyPaperError.message("arXiv 未返回有效论文元数据。") }
        return delegate.values
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        path.append(elementName)
        if elementName == "entry", !complete { entry = true }
        guard entry, !complete else { return }
        if ["title", "summary", "id", "arxiv:doi"].contains(elementName), path.dropLast().last == "entry" { field = elementName; text = "" }
        if elementName == "name", path.dropLast().last == "author" { field = "author"; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !field.isEmpty { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if entry, !complete {
            if elementName == field || (field == "author" && elementName == "name") {
                let value = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                if field == "author" { values["authors", default: ""] += value + "\n" }
                else { values[field == "arxiv:doi" ? "doi" : field] = value }
                field = ""; text = ""
            }
            if elementName == "entry" { complete = true; entry = false }
        }
        if !path.isEmpty { path.removeLast() }
    }
}
