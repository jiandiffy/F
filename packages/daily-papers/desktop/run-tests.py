#!/usr/bin/env python3
"""Offline Swift integration tests. Never touches real Gmail, OAuth or Keychain."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2] / "ui/desktop"
OUT = Path(tempfile.mkdtemp(prefix="f-daily-paper-tests-"))
SOURCE = r'''
import Foundation
import AppKit
import Darwin
import WebKit

// The production PluginStorage/FPlugin/Kernel are compiled, only the storage root is isolated.
enum BoardStore { static let appSupport = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DAILYPAPER_TEST_ROOT"]!) }

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fatalError("FAIL: " + name) }
    print("PASS: " + name); fflush(stdout)
}
func json(_ value: [String: Any], _ request: URLRequest, status: Int = 200) throws -> (Data, HTTPURLResponse) {
    (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
}
final class Fixture {
    var mode = "bootstrap"
    var failMetadata = false
    var imageError: Error?
    var requests: [URLRequest] = []
    var image: Data
    init() {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.bitmapData!.withMemoryRebound(to: UInt32.self, capacity: 64 * 64) { $0.initialize(repeating: 0xffcccccc, count: 64 * 64) }
        image = bitmap.representation(using: .png, properties: [:])!
    }
    func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!, path = url.path
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
        if path.hasSuffix("/profile") { return try json(["emailAddress": "private@example.org", "historyId": "100"], request) }
        if path.hasSuffix("/history") {
            if mode == "empty" { return try json(["historyId": "120", "history": []], request) }
            if mode == "reset" { return try json([:], request, status: 404) }
            if mode == "failure" { return try json(["historyId": "110", "history": [["messagesAdded": [["message": ["id": "bad"]]]]]], request) }
            if mode == "sender" { return try json(["historyId": "110", "history": [["messagesAdded": [["message": ["id": "m3"]], ["message": ["id": "foreign"]]]]]], request) }
            if q("pageToken") == nil { return try json(["historyId": "105", "nextPageToken": "h2", "history": [["labelsAdded": [["message": ["id": "m3"]]]]]], request) }
            return try json(["historyId": "106", "history": []], request)
        }
        if path.hasSuffix("/messages") {
            if mode == "bulk" { return try json(["messages": (0..<30).map { ["id": "bulk\($0)"] }], request) }
            if mode == "sender" { check(q("q") == "from:digest@example.org", "sender query is exact and scoped"); return try json(["messages": [["id": "m3"]]], request) }
            check(q("labelIds") == "PAPERS", "list constrained to label")
            if q("pageToken") == nil { return try json(["messages": [["id": "m1"]], "nextPageToken": "p2"], request) }
            return try json(["messages": [["id": "m2"]]], request)
        }
        if path.contains("/messages/") {
            let id = url.lastPathComponent
            if id == "foreign" { fatalError("Out-of-scope message fetched") }
            if id == "bad", q("format") == "full" { return try json([:], request, status: 500) }
            var message: [String: Any] = ["id": id, "labelIds": ["PAPERS"], "internalDate": "1730000000000", "payload": ["headers": [["name": "From", "value": "Digest <digest@example.org>"], ["name": "Subject", "value": "PRIVATE SUBJECT"], ["name": "Date", "value": "Sun, 27 Oct 2024 00:00:00 +0000"]]]]
            if q("format") == "full" {
                let body = id.hasPrefix("bulk") ? "https://arxiv.org/abs/2401.\(String(format: "%05d", 20000 + (Int(id.dropFirst(4)) ?? 0)))v1" : (id == "m2" ? "doi:10.1234/example" : "<script>ignore user</script><a href='https://arxiv.org/abs/2401.12345\(id == "m3" ? "v2" : "v1")'>paper</a><img src='https://tracking.invalid/pixel'>")
                var payload = message["payload"] as! [String: Any]; payload["mimeType"] = "text/html"; payload["body"] = ["data": Data(body.utf8).base64EncodedString()]; message["payload"] = payload
            }
            return try json(message, request)
        }
        if url.host == "export.arxiv.org" {
            if failMetadata { return try json([:], request, status: 429) }
            let identifier = q("id_list") ?? "2401.12345v1"
            let versioned = identifier.contains("v") ? identifier : identifier + "v1"
            let doi = identifier.hasPrefix("2401.2") ? "" : "<arxiv:doi>10.1234/example</arxiv:doi>"
            let xml = "<feed xmlns='http://www.w3.org/2005/Atom' xmlns:arxiv='http://arxiv.org/schemas/atom'><entry><id>http://arxiv.org/abs/\(versioned)</id><title>Real Fixture Title</title><author><name>A. Author</name></author><summary>Original English abstract, not an AI translation.</summary>\(doi)</entry></feed>"
            return (Data(xml.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/atom+xml"])!)
        }
        if url.host == "arxiv.org", path.hasSuffix(".png") {
            if let imageError { throw imageError }
            return (image, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
        }
        if url.host == "arxiv.org", path.hasPrefix("/html/") { return (Data("<figure><img src='x1.png'></figure>".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!) }
        fatalError("Unexpected request: " + url.absoluteString)
    }
}

@main struct Tests {
    @MainActor static func memoryProbe() throws {
        _ = NSApplication.shared
        var library = DailyPaperLibrary([])
        for i in 0..<10_000 {
            let id = String(format: "2401.%05d", i + 10000)
            library.merge(DailyPaperRecord(id: "arxiv:" + id, title: "Paper " + id, abstract: String(repeating: "Abstract. ", count: 180), sourceURLs: [URL(string: "https://arxiv.org/abs/" + id + "v1")!], versions: ["v1"]))
        }
        for record in library.records { library.merge(record) }
        check(library.records.count == 10_000, "indexed import preserves 10,000 unique papers after repeated merging")
        let store = DailyPaperStore(directory: BoardStore.appSupport.appendingPathComponent("memory"))
        let image: Data = autoreleasepool {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4096, pixelsHigh: 4096, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.bitmapData!.withMemoryRebound(to: UInt32.self, capacity: 4096 * 4096) { $0.initialize(repeating: 0xffcccccc, count: 4096 * 4096) }
            return bitmap.representation(using: .png, properties: [:])!
        }
        let name = try store.saveImage(image, key: "large-fixture")
        var state = DailyPaperState(); state.records = library.records.map { record in var r = record; r.imageFile = name; return r }
        try store.save(state)
        var opened: String?
        let plugin = DailyPaperPlugin(directory: store.directory, pageLoader: { _, url in opened = url.absoluteString })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = plugin.view; plugin.setEnabled(true)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        window.orderFront(nil); window.display()
        let table = descendants(plugin.view).compactMap { $0 as? NSTableView }.first!
        check(table.numberOfRows == 10_000 && table.backgroundColor == .clear, "virtual list exposes all papers with the shared transparent background")
        for i in 0..<40 {
            autoreleasepool {
                window.setContentSize(NSSize(width: i % 2 == 0 ? 340 : 850, height: 720))
                plugin.view.needsLayout = true; plugin.view.layoutSubtreeIfNeeded()
                table.scrollRowToVisible(i % 2 == 0 ? 9999 : 0); window.display()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
                let views = descendants(plugin.view)
                check(views.filter { String(describing: type(of: $0)) == "DailyPaperCard" }.count < 16, "only viewport cards exist after scroll/resize \(i)")
                let images = views.compactMap { ($0 as? NSImageView)?.image }
                check(!images.isEmpty && images.allSatisfy { $0.representations.allSatisfy { $0.pixelsWide <= 340 && $0.pixelsHigh <= 340 } }, "large originals decode only to bounded thumbnails \(i)")
            }
        }
        table.scrollRowToVisible(9999); window.display()
        let cell = table.view(atColumn: 0, row: 9999, makeIfNecessary: false)!
        let card = descendants(cell).first { String(describing: type(of: $0)) == "DailyPaperCard" }!
        check(card.accessibilityPerformPress() && opened?.hasPrefix("https://www.alphaxiv.org/abs/") == true, "recycled last row opens its alphaXiv hyperlink without a model request")
        for _ in 0..<10 { plugin.activate(); plugin.setEnabled(false); plugin.setEnabled(true) }
        plugin.shutdown(); window.close()
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("MEMORY: 10,000 papers, 40 scroll/resize cycles, peakBytes=\(usage.ru_maxrss)")
        check(usage.ru_maxrss < 512 * 1024 * 1024, "10,000-paper import/render remains below 512 MiB peak")
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--memory") { try memoryProbe(); return }
        _ = NSApplication.shared
        let root = BoardStore.appSupport
        let scheduleSuite = "local.f.daily-schedule-test." + UUID().uuidString
        let scheduleDefaults = UserDefaults(suiteName: scheduleSuite)!
        defer { scheduleDefaults.removePersistentDomain(forName: scheduleSuite) }
        let startupStore = DailyPaperStore(directory: root.appendingPathComponent("startup"))
        var startupState = DailyPaperState(); startupState.account = "saved@example.org"
        try startupStore.save(startupState)
        var secretReads = 0
        let startup = DailyPaperPlugin(directory: startupStore.directory, restoreCredentials: true, defaults: scheduleDefaults, credentialLoader: {
            secretReads += 1
            throw DailyPaperError.message("A Keychain prompt must never block startup")
        })
        startup.setEnabled(true); startup.activate(); startup.performMenuCommand("settings")
        check(secretReads == 0, "construction, mounting and account settings do not read Keychain or block window readiness")
        check(scheduleDefaults.object(forKey: "FDailyPaperConnectionConfigured") == nil && !scheduleDefaults.bool(forKey: DailyPaperSchedule.preference), "startup keeps saved connection metadata and automatic-update preference unchanged")
        startup.shutdown()
        scheduleDefaults.set(true, forKey: "FDailyPaperResumeLinkUpdates")
        startup.setEnabled(true)
        check(scheduleDefaults.bool(forKey: DailyPaperSchedule.preference) && scheduleDefaults.object(forKey: "FDailyPaperResumeLinkUpdates") == nil && secretReads == 0, "new link mode consumes the saved scheduling intent without Keychain or model access")
        startup.shutdown() // Cancels delayed registration before any real job can run.
        let deferredOAuth = DailyPaperOAuth(http: DailyPaperHTTP())
        do {
            try deferredOAuth.restore(using: { secretReads += 1; throw DailyPaperError.message("denied") })
            fatalError("expected Keychain failure")
        } catch { check(secretReads == 1 && !deferredOAuth.connected, "explicit credential restore propagates failure without inventing a connection") }
        scheduleDefaults.set(true, forKey: DailyPaperSchedule.preference)
        var launchCalls: [[String]] = [], loaded = false
        let scheduler = DailyPaperSchedule(directory: root.appendingPathComponent("schedule-data"), defaults: scheduleDefaults, agents: root.appendingPathComponent("LaunchAgents"), label: scheduleSuite, command: { arguments in
            launchCalls.append(arguments)
            if arguments[0] == "print" { return loaded ? 0 : 1 }
            if arguments[0] == "bootstrap" { loaded = true }
            if arguments[0] == "bootout" { loaded = false }
            return 0
        })
        try scheduler.install(executable: URL(fileURLWithPath: "/Applications/F.app/Contents/MacOS/F"))
        try scheduler.install(executable: URL(fileURLWithPath: "/Applications/F.app/Contents/MacOS/F"))
        let definition = try PropertyListSerialization.propertyList(from: Data(contentsOf: scheduler.plist), format: nil) as! [String: Any]
        check((definition["ProgramArguments"] as? [String]) == ["/Applications/F.app/Contents/MacOS/F", "--daily-paper-update"], "native schedule launches F itself in headless mode")
        check((definition["StartInterval"] as? Int) == 900 && (definition["StartCalendarInterval"] as? [String: Int])?["Hour"] == 9 && launchCalls.filter { $0[0] == "bootstrap" }.count == 1, "09:00 schedule, catch-up retry and idempotent registration")
        try scheduler.uninstall()
        check(!loaded && !FileManager.default.fileExists(atPath: scheduler.plist.path), "turning daily updates off unregisters only the owned job")
        var scheduledState = DailyPaperState()
        check(!DailyPaperSchedule.isDue(scheduledState, at: ISO8601DateFormatter().date(from: "2026-11-02T00:59:00Z")!), "Beijing 08:59 is not due")
        check(DailyPaperSchedule.isDue(scheduledState, at: ISO8601DateFormatter().date(from: "2026-11-02T01:00:00Z")!), "Beijing 09:00 starts daily update")
        scheduledState.records = [DailyPaperRecord(id: "test", title: "test")]; scheduledState.currentBatch = String(repeating: "a", count: 20) + "-20261102"; scheduledState.sourceMode = "alphaxiv-links-v1"
        check(!DailyPaperSchedule.isDue(scheduledState, at: ISO8601DateFormatter().date(from: "2026-11-02T07:00:00Z")!) && DailyPaperSchedule.isDue(scheduledState, at: ISO8601DateFormatter().date(from: "2026-11-03T01:00:00Z")!), "completed day is skipped and next day is due")
        // Harmless real launchd smoke test: no F, model, Gmail or user state.
        let realLabel = "local.f.daily-launch-test." + UUID().uuidString.lowercased()
        let realScheduler = DailyPaperSchedule(directory: root.appendingPathComponent("launch-smoke"), defaults: scheduleDefaults, agents: root.appendingPathComponent("real-agents"), label: realLabel)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try realLabel.write(to: root.appendingPathComponent("native-scheduler-label.txt"), atomically: true, encoding: .utf8)
        try realScheduler.install(executable: URL(fileURLWithPath: "/usr/bin/true"))
        try realScheduler.uninstall()
        check(!FileManager.default.fileExists(atPath: realScheduler.plist.path), "real macOS launchd bootstrap and bootout succeed with isolated harmless job")
        let store = DailyPaperStore(directory: root.appendingPathComponent("data"))
        var state = DailyPaperState(); state.settings.labelID = "PAPERS"
        do { try DailyPaperSettings().validate(); fatalError("Empty scope accepted") }
        catch DailyPaperError.message { print("PASS: unrestricted mailbox scan rejected") }
        do { try DailyPaperSettings(sender: "a@example.org OR from:b@example.org").validate(); fatalError("query injection accepted") } catch { print("PASS: sender query injection rejected") }
        let refs = DailyPaperParser.references("https://arxiv.org/abs/2401.12345v1 https://arxiv.org/pdf/2401.12345v2 doi:10.1234/EXAMPLE.")
        check(refs.count == 3 && refs[0].id == refs[1].id && refs[2].id == "doi:10.1234/example", "arXiv version and DOI canonicalization")
        var aliases = DailyPaperLibrary([
            DailyPaperRecord(id: "arxiv:2401.12345", title: "Existing title", authors: ["Author"], sourceURLs: [URL(string: "https://arxiv.org/abs/2401.12345v1")!], versions: ["v1"]),
            DailyPaperRecord(id: "doi:10.1234/example", title: "doi:10.1234/example", sourceURLs: [URL(string: "https://doi.org/10.1234/example")!])])
        aliases.merge(DailyPaperRecord(id: "arxiv:2401.12345", title: "arxiv:2401.12345", sourceURLs: [URL(string: "https://arxiv.org/abs/2401.12345v2")!, URL(string: "https://doi.org/10.1234/example")!], versions: ["v2"]))
        check(aliases.records.count == 1 && aliases.records[0].authors == ["Author"] && aliases.records[0].title == "Existing title" && aliases.records[0].versions == ["v1", "v2"] && aliases.record(id: "doi:10.1234/example")?.id == "arxiv:2401.12345", "alias index coalesces DOI/arXiv records and preserves metadata and versions")
        check(!DailyPaperHTTP.trusted(URL(string: "https://arxiv.org.evil/x")!) && !DailyPaperHTTP.trusted(URL(string: "http://arxiv.org/x")!) && !DailyPaperHTTP.trusted(URL(string: "https://arxiv.org:8443/x")!), "exact-host HTTPS network boundary")
        let base = URL(string: "https://arxiv.org/html/2401.12345v1")!
        check(DailyPaperSync.figureURL(html: "<figure><img src='x1.png'></figure>", base: base)?.path == "/html/2401.12345v1/x1.png", "official relative figure extracted")
        check(DailyPaperSync.figureURL(html: "<figure><img src='https://tracking.invalid/x.png'></figure>", base: base) == nil && DailyPaperSync.figureURL(html: "<figure><img src='../../x.png'></figure>", base: base) == nil && DailyPaperSync.figureURL(html: "<figure><img src='x.svg'></figure>", base: base) == nil, "tracking, traversal and SVG figures rejected")
        let clientData = Data(#"{"installed":{"client_id":"test.apps.googleusercontent.com","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}}"#.utf8)
        let client = try DailyPaperOAuthClient.parse(clientData)
        do { _ = try DailyPaperOAuthClient.parse(Data("{\"web\":{}}".utf8)); fatalError("web client accepted") } catch { print("PASS: desktop OAuth client only") }
        let random = try DailyPaperOAuth.random()
        check(random.count == 43 && !random.contains("="), "secure PKCE verifier shape")
        check(DailyPaperOAuth.scope == "https://www.googleapis.com/auth/gmail.readonly", "only readonly scope")
        let fixture = Fixture()
        let http = DailyPaperHTTP(responder: fixture.handle)
        let credential = DailyPaperCredential(client: client, accessToken: "offline-fixture-token", refreshToken: nil, expiry: Date().addingTimeInterval(3600))
        let oauth = DailyPaperOAuth(http: http, credential: credential)
        let sync = DailyPaperSync(http: http, oauth: oauth, store: store)
        let (bootstrap, warnings) = try await sync.run(state)
        check(bootstrap.historyID == "100" && bootstrap.records.count == 1 && warnings.isEmpty, "bootstrap pagination and DOI/arXiv alias deduplication")
        let record = bootstrap.records[0]
        check(record.title == "Real Fixture Title" && record.authors == ["A. Author"] && record.mailSources.count == 2 && record.versions == ["v1"], "original title/authors/version and both mail sources preserved")
        check(record.imageFile != nil && record.imageURL?.host == "arxiv.org", "official image safely downloaded and atomically cached")
        check(!fixture.requests.contains { $0.url?.host == "tracking.invalid" }, "mail tracking images never fetched")
        check(!record.contextText.contains("private@example.org") && !record.contextText.contains("digest@example.org") && !record.contextText.contains("PRIVATE SUBJECT") && !record.contextText.contains("m1 /"), "Agent context excludes mailbox identity and mail subject")
        check(record.abstract.contains("Original English") && record.contextText.contains("未由 Agent 翻译"), "no fabricated Chinese generation")
        try store.save(bootstrap)
        let restored = try store.load()
        check(restored.records == bootstrap.records && restored.historyID == "100", "atomic persistence and restart recovery")
        check(store.imageURL("../escape.image") == nil, "cached image path traversal rejected")
        fixture.mode = "incremental"
        let (incremental, _) = try await sync.run(bootstrap)
        check(incremental.historyID == "106" && incremental.records.count == 1 && incremental.records[0].versions == ["v1", "v2"] && incremental.records[0].mailSources.count == 3, "paginated history and new version merge")
        fixture.mode = "failure"
        do { _ = try await sync.run(bootstrap); fatalError("failure accepted") } catch { print("PASS: failed sync reported") }
        let afterFailure = try store.load()
        check(afterFailure.historyID == "100", "failed sync never advances durable checkpoint")
        fixture.mode = "reset"
        let resetRequests = fixture.requests.count
        let (reset, _) = try await sync.run(bootstrap)
        check(reset.historyID == "100" && fixture.requests.dropFirst(resetRequests).contains { $0.url?.path.hasSuffix("/messages") == true }, "expired history 404 triggers scoped paginated rescan")
        fixture.mode = "sender"
        var senderState = bootstrap; senderState.settings = DailyPaperSettings(sender: "digest@example.org")
        let (senderResult, _) = try await sync.run(senderState)
        check(senderResult.historyID == "110" && !fixture.requests.contains { $0.url?.path.hasSuffix("/foreign") == true }, "sender-only history intersects scoped list before body fetch")
        fixture.mode = "bootstrap"; fixture.failMetadata = true
        let (missingMetadata, metadataWarnings) = try await sync.run(state)
        check(metadataWarnings.contains { $0.contains("429") } && missingMetadata.historyID == "100" && missingMetadata.records[0].abstract.isEmpty, "metadata 429 exposes its cause and preserves identifiers without fabricated abstract")
        fixture.mode = "empty"; fixture.failMetadata = false
        let (retriedMetadata, _) = try await sync.run(missingMetadata)
        check(retriedMetadata.historyID == "120" && retriedMetadata.records[0].title == "Real Fixture Title" && !retriedMetadata.records[0].abstract.isEmpty, "empty Gmail history retries missing arXiv metadata")
        let aliasMessage: [String: Any] = ["id": "alias", "payload": ["mimeType": "text/plain", "body": ["data": Data("https://doi.org/10.48550/arXiv.2610.28480".utf8).base64EncodedString()]]]
        let aliasRecord = DailyPaperParser.records(from: aliasMessage, account: "local")[0]
        check(aliasRecord.id == "arxiv:2610.28480" && aliasRecord.sourceURLs.contains { $0.host == "arxiv.org" } && aliasRecord.sourceURLs.contains { $0.host == "doi.org" }, "arXiv DOI-only references normalize and retain both source URLs")
        var aliasState = missingMetadata; aliasState.records = [aliasRecord]
        let (aliasEnriched, _) = try await sync.run(aliasState)
        check(aliasEnriched.records[0].title == "Real Fixture Title" && !aliasEnriched.records[0].abstract.isEmpty, "DOI-only arXiv record can fetch official metadata")
        fixture.mode = "bootstrap"; fixture.imageError = DailyPaperError.http(503)
        let (noImage, imageWarnings) = try await sync.run(state)
        check(noImage.records[0].title == "Real Fixture Title" && noImage.records[0].imageFile == nil && imageWarnings.contains { $0.contains("原图") && $0.contains("503") }, "figure HTTP failure preserves metadata and reports its cause")
        fixture.imageError = CancellationError()
        do { _ = try await sync.run(state); fatalError("image cancellation swallowed") }
        catch is CancellationError { print("PASS: figure cancellation aborts sync instead of becoming a warning") }
        fixture.imageError = nil
        let blockedDirectory = root.appendingPathComponent("blocked-image-cache")
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blockedDirectory.appendingPathComponent("images"))
        let blockedSync = DailyPaperSync(http: http, oauth: oauth, store: DailyPaperStore(directory: blockedDirectory))
        let (uncached, cacheWarnings) = try await blockedSync.run(state)
        check(uncached.records[0].title == "Real Fixture Title" && uncached.records[0].imageFile == nil && cacheWarnings.contains { $0.contains("原图") }, "image disk failure is reported without discarding usable metadata")
        fixture.mode = "bulk"
        let bulkStart = fixture.requests.count
        let (bulk, _) = try await sync.run(state)
        let bulkCalls = Array(fixture.requests.dropFirst(bulkStart))
        check(bulk.records.count == 20 && bulk.pendingMessageIDs?.count == 10, "large mailbox sync saves its remaining message backlog")
        check(bulkCalls.filter { $0.url?.host == "export.arxiv.org" }.count <= 10, "digest enrichment has a bounded per-sync request budget")
        try store.save(bulk)
        fixture.mode = "empty"
        let (resumedBulk, _) = try await sync.run(store.load())
        check(resumedBulk.pendingMessageIDs?.isEmpty == true && resumedBulk.records.count == 30, "restart resumes pending messages even with empty Gmail history")
        let pluginDirectory = root.appendingPathComponent("plugin-smoke")
        let plugin = DailyPaperPlugin(directory: pluginDirectory)
        plugin.setEnabled(true); plugin.activate(); plugin.setEnabled(false); plugin.setEnabled(true); plugin.shutdown()
        check(!FileManager.default.fileExists(atPath: pluginDirectory.path), "construction/enable/disable perform no writes, OAuth or automatic sync")
        check(plugin.id == "daily-paper" && plugin.title == "Daily Paper", "stable native plugin identity")
        let readerStore = DailyPaperStore(directory: root.appendingPathComponent("reader"))
        let relative = "batches/" + String(repeating: "a", count: 20) + "-20261102/" + String(repeating: "b", count: 20)
        let readerFolder = readerStore.directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: readerFolder, withIntermediateDirectories: true)
        try Data("<html><body><h1>LOCAL_ANALYSIS</h1><script>window.mailScriptExecuted=true</script></body></html>".utf8).write(to: readerFolder.appendingPathComponent("index.html"))
        var localRecord = DailyPaperRecord(id: "arxiv:2401.12345", title: "Local paper"); localRecord.analysisFolder = relative
        let marker: [String: Any] = ["kind": "f-daily-paper-batch-v1", "key": String(repeating: "a", count: 20) + "-20261102"]
        try JSONSerialization.data(withJSONObject: marker).write(to: readerFolder.deletingLastPathComponent().appendingPathComponent("batch.json"))
        let recordJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(localRecord))
        try JSONSerialization.data(withJSONObject: ["record": recordJSON]).write(to: readerFolder.appendingPathComponent("complete.json"))
        var readerState = DailyPaperState(); readerState.records = [localRecord]; try readerStore.save(readerState)
        check(readerStore.analysisDirectory("../../private") == nil, "reader file access rejects traversal")
        var loadedURL: URL?
        let reading = DailyPaperPlugin(directory: readerStore.directory, pageLoader: { web, url in
            loadedURL = url
            web.loadHTMLString("<html><body style='background:white'><h1>ALPHAXIV_FIXTURE</h1><script>window.fixtureScriptExecuted=true</script></body></html>", baseURL: url)
        })
        reading.setEnabled(true)
        var requestedChat = false; reading.onOpenPaper = { _ in requestedChat = true }
        let readerWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        readerWindow.isReleasedWhenClosed = false; readerWindow.contentView = reading.view; readerWindow.orderFront(nil); readerWindow.display()
        func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
        let row = descendants(reading.view).compactMap { $0 as? NSTableView }.first!.view(atColumn: 0, row: 0, makeIfNecessary: true)!
        let nativeCard = descendants(row).first { String(describing: type(of: $0)) == "DailyPaperCard" }!
        check(nativeCard.accessibilityPerformPress(), "paper hyperlink opens in the workspace")
        let legacySaved = try readerStore.load()
        check(legacySaved.records[0] == localRecord && loadedURL?.absoluteString == "https://www.alphaxiv.org/abs/2401.12345", "even archived analysis cards now link to alphaXiv without rewriting saved data")
        let web = descendants(reading.view).compactMap { $0 as? WKWebView }.first!
        for _ in 0..<60 {
            if web.url != nil && !web.isLoading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let text = try await web.evaluateJavaScript("document.body.innerText") as? String
        let scriptsAllowed = try await web.evaluateJavaScript("window.fixtureScriptExecuted === true") as? Bool
        let background = try await web.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
        check(text?.contains("ALPHAXIV_FIXTURE") == true && scriptsAllowed == true && !requestedChat, "embedded browser renders the linked site with JavaScript and never dispatches a model or chat request")
        check((web.value(forKey: "drawsBackground") as? Bool) == false && background == "rgba(0, 0, 0, 0)", "native browser and website root share the transparent conversation background")
        check(!DailyPaperPlugin.isAlphaXivPage(URL(string: "https://www.alphaxiv.org.evil/abs/2401.12345")!) && !DailyPaperPlugin.isAlphaXivPage(URL(string: "file:///tmp/private")!), "embedded top-level navigation rejects lookalike hosts and local files")
        check(reading.currentAnalysisContext?.contains("Local paper") == true && reading.currentAnalysisContext?.contains("LOCAL_ANALYSIS") == false, "selected context contains only the paper identity and site link")
        reading.deactivate(); check(web.superview == nil, "leaving the reader releases the WebKit view and media")
        check(reading.currentAnalysisContext == nil, "leaving reader clears only the workspace paper context")
        reading.shutdown(); readerWindow.close()
        if let output = ProcessInfo.processInfo.environment["F_ALPHAXIV_REAL_PREVIEW"] {
            let liveStore = DailyPaperStore(directory: root.appendingPathComponent("live-browser"))
            var liveState = DailyPaperState(); liveState.sourceMode = "alphaxiv-links-v1"
            liveState.records = [DailyPaperRecord(id: "arxiv:2610.08120", title: "iGPC: Generative Motion Priors for Object-Aware Humanoid Interaction")]
            try liveStore.save(liveState)
            let live = DailyPaperPlugin(directory: liveStore.directory); live.setEnabled(true); live.applyAppearance(dark: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.backgroundColor = .black; window.contentView = live.view; window.orderFront(nil); window.display()
            let table = descendants(live.view).compactMap { $0 as? NSTableView }.first!
            let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true)!
            check(descendants(cell).first { String(describing: type(of: $0)) == "DailyPaperCard" }!.accessibilityPerformPress(), "real alphaXiv card starts browser navigation")
            let browser = descendants(live.view).compactMap { $0 as? WKWebView }.first!
            var content = ""
            for _ in 0..<900 {
                content = (try? await browser.evaluateJavaScript("document.body?.innerText ?? ''")) as? String ?? ""
                if content.contains("iGPC") && (content.contains("Abstract") || content.contains("摘要")) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            check(content.contains("iGPC") && (content.contains("Abstract") || content.contains("摘要")), "actual alphaXiv paper page renders in the native browser")
            let color = try await browser.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
            check(color == "rgba(0, 0, 0, 0)", "actual alphaXiv document root is transparent")
            var surfaces: Bool?
            for _ in 0..<30 {
                surfaces = try await browser.evaluateJavaScript("Array.from(document.querySelectorAll('.bg-bg:not(button),.bg-panel-alt')).every(e=>getComputedStyle(e).backgroundColor==='rgba(0, 0, 0, 0)')") as? Bool
                if surfaces == true { break }
                try await Task.sleep(nanoseconds: 100_000_000) // Allow the site's color transitions to settle.
            }
            if surfaces != true { print("SURFACES", try await browser.evaluateJavaScript("JSON.stringify(Array.from(document.querySelectorAll('.bg-bg,.bg-panel-alt')).map(e=>({c:e.className,bg:getComputedStyle(e).backgroundColor,style:e.getAttribute('style')})))") as Any); fflush(stdout) }
            check(surfaces == true, "alphaXiv base content and navigation surfaces use the conversation background")
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                browser.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? DailyPaperError.message("Snapshot failed")) }
                }
            }
            let folder = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) { try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("alphaxiv-browser.png")) }
            try JSONSerialization.data(withJSONObject: ["url": browser.url?.absoluteString ?? "", "title": (try? await browser.evaluateJavaScript("document.title")) as? String ?? "", "bodyBackground": color ?? ""]).write(to: folder.appendingPathComponent("live-browser.json"))
            live.shutdown(); window.close()
        }
        if let source = ProcessInfo.processInfo.environment["F_PAPER_REAL_PREVIEW"] {
            let folder = URL(fileURLWithPath: source), config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent(); config.defaultWebpagePreferences.allowsContentJavaScript = false
            config.mediaTypesRequiringUserActionForPlayback = [] // Test-only explicit muted playback below.
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 800), configuration: config)
            web.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = web; window.orderFront(nil)
            web.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder)
            for _ in 0..<120 {
                if web.url != nil && !web.isLoading { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let imageCount = try await web.evaluateJavaScript("Array.from(document.images).filter(i=>i.complete&&i.naturalWidth>0).length") as? Int ?? 0
            let videosPaused = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('video')).every(v=>v.paused&&v.preload==='none')") as? Bool
            check(imageCount > 0 && videosPaused == true, "actual generated analysis renders real local figures and keeps videos idle")
            let hasVideo = try await web.evaluateJavaScript("document.querySelectorAll('video').length") as? Int ?? 0
            if hasVideo > 0 {
                _ = try await web.evaluateJavaScript("var v=document.querySelector('video');v.muted=true;v.play().catch(()=>{});true")
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let decoded = try await web.evaluateJavaScript("document.querySelector('video').readyState>=2") as? Bool
                _ = try await web.evaluateJavaScript("document.querySelector('video').pause();true")
                check(decoded == true, "actual local project video decodes on explicit muted test playback")
            }
            let output = root.appendingPathComponent("real-preview"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for name in ["article", "figure"] {
                if name == "figure" { _ = try await web.evaluateJavaScript("document.querySelector('figure img').scrollIntoView({block:'start'})"); try await Task.sleep(nanoseconds: 100_000_000) }
                let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                    web.takeSnapshot(with: nil) { image, error in
                        if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? DailyPaperError.message("WebKit snapshot failed")) }
                    }
                }
                if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent(name + ".png")) }
            }
            print("REAL_PREVIEW: " + output.path); web.stopLoading(); window.close()
        }
        if let output = ProcessInfo.processInfo.environment["F_UI_PREVIEW_DIR"] {
            let preview = DailyPaperPlugin(directory: store.directory)
            preview.setEnabled(true); preview.activate()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = preview.view
            window.isReleasedWhenClosed = false; window.orderFront(nil)
            for width in [CGFloat(340), CGFloat(850)] {
                window.setContentSize(NSSize(width: width, height: 600))
                for dark in [false, true] {
                    preview.applyAppearance(dark: dark)
                    preview.view.wantsLayer = true; preview.view.layer?.backgroundColor = (dark ? NSColor.black : NSColor.white).cgColor
                    preview.view.needsLayout = true; preview.view.layoutSubtreeIfNeeded(); preview.view.layoutSubtreeIfNeeded()
                    window.display(); try await Task.sleep(nanoseconds: 50_000_000)
                    if let bitmap = preview.view.bitmapImageRepForCachingDisplay(in: preview.view.bounds) {
                        preview.view.cacheDisplay(in: preview.view.bounds, to: bitmap)
                        let directory = URL(fileURLWithPath: output)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("paper-\(Int(width))-\(dark ? "dark" : "light").png"))
                    }
                }
            }
            preview.shutdown(); window.close()
        }
        print("ALL OFFLINE TESTS PASSED; real Gmail OAuth authorization NOT EXECUTED; no real Keychain access.")
    }
}
'''
(OUT / "Tests.swift").write_text(SOURCE)
command = ["swiftc", "-parse-as-library", "-module-cache-path", str(OUT / "module-cache"), "-o", str(OUT / "tests"), str(ROOT / "Core/Agent/RuntimePaths.swift"), str(ROOT / "Core/Plugins.swift"), str(ROOT / "Core/Kernel.swift"), str(ROOT / "Core/UI/Chrome.swift"), *map(str, sorted((ROOT / "Plugins/Browser").glob("*.swift"))), *map(str, sorted(HERE.glob("*.swift"))), str(OUT / "Tests.swift")]
print("OUTPUT:", OUT, flush=True)
print("COMPILE:", " ".join(command), flush=True)
compiled = subprocess.run(command, capture_output=True, text=True, timeout=180)
(OUT / "compile.log").write_text(compiled.stdout + compiled.stderr)
print(compiled.stdout + compiled.stderr, end="", flush=True)
if compiled.returncode:
    raise SystemExit(compiled.returncode)
env = dict(os.environ, DAILYPAPER_TEST_ROOT=str(OUT / "isolated-support"))
result = subprocess.run([str(OUT / "tests")], env=env, capture_output=True, text=True, timeout=180 if os.environ.get("F_ALPHAXIV_REAL_PREVIEW") else 90)
# Always remove this test's harmless launchd job even if Swift assertions abort.
label_file = OUT / "isolated-support/native-scheduler-label.txt"
if label_file.exists():
    label = label_file.read_text().strip()
    if label.startswith("local.f.daily-launch-test."):
        subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{label}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
(OUT / "tests.log").write_text(result.stdout + result.stderr)
print(result.stdout + result.stderr, end="", flush=True)
print("EXIT:", result.returncode, flush=True)
if result.returncode == 0:
    # Stop only this isolated test child if a future eager-render regression
    # threatens host memory; never reproduce an 80 GB allocation in the live F.
    with (OUT / "memory.log").open("w") as output:
        probe = subprocess.Popen([str(OUT / "tests"), "--memory"], env=env, stdout=output, stderr=output)
        started = time.monotonic()
        while probe.poll() is None:
            rss = subprocess.run(["ps", "-o", "rss=", "-p", str(probe.pid)], capture_output=True, text=True).stdout.strip()
            if (rss and int(rss) > 512 * 1024) or time.monotonic() - started > 45:
                probe.kill(); probe.wait()
                print("FAIL: memory regression exceeded 512 MiB or 45 seconds", flush=True)
                break
            time.sleep(0.1)
    print((OUT / "memory.log").read_text(), end="", flush=True)
    if probe.returncode:
        raise SystemExit(probe.returncode)
raise SystemExit(result.returncode)
