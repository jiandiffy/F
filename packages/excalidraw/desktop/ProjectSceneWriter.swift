import Foundation
import Darwin

/// Coordinates native edits with the Agent's project transaction lock.
enum ProjectSceneWriter {
    enum Outcome { case busy, saved(Data, merged: Bool, conflicted: Bool) }

    static func acquireLock(for file: URL) throws -> URL? {
        let locks = file.deletingLastPathComponent().appendingPathComponent("harness/leases", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let lock = locks.appendingPathComponent("transaction.lock", isDirectory: true)
        guard mkdir(lock.path, 0o700) == 0 else {
            if errno == EEXIST { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return lock
    }
    static func releaseLock(_ lock: URL) { rmdir(lock.path) }

    static func save(_ incoming: [String: Any], baseline: Data?, to file: URL, project: URL) throws -> Outcome {
        guard let lock = try acquireLock(for: file) else { return .busy }
        defer { releaseLock(lock) }

        let latest = try Data(contentsOf: file)
        guard var disk = try JSONSerialization.jsonObject(with: latest) as? [String: Any] else {
            throw NSError(domain: "F.Whiteboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "画板文件格式无效"])
        }
        var result = incoming
        var conflicted = false
        if latest != baseline {
            let base = baseline.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let baseElements = base["elements"] as? [[String: Any]] ?? []
            let desired = incoming["elements"] as? [[String: Any]] ?? []
            var current = disk["elements"] as? [[String: Any]] ?? []
            let baseByID = Dictionary(baseElements.compactMap { item in (item["id"] as? String).map { ($0, item) } }, uniquingKeysWith: { _, last in last })
            let desiredByID = Dictionary(desired.compactMap { item in (item["id"] as? String).map { ($0, item) } }, uniquingKeysWith: { _, last in last })
            func equal(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
                if a == nil || b == nil { return a == nil && b == nil }
                return NSDictionary(dictionary: a!).isEqual(to: b!)
            }
            for id in Set(baseByID.keys).union(desiredByID.keys) {
                let before = baseByID[id], after = desiredByID[id]
                guard !equal(before, after) else { continue }
                let index = current.firstIndex { $0["id"] as? String == id }
                let now = index.map { current[$0] }
                guard equal(now, before) || equal(now, after) else { conflicted = true; continue }
                if let after {
                    if let index { current[index] = after } else { current.append(after) }
                } else if let index { current.remove(at: index) }
            }
            disk["elements"] = current
            var files = disk["files"] as? [String: Any] ?? [:]
            for (id, file) in incoming["files"] as? [String: Any] ?? [:] where files[id] == nil { files[id] = file }
            disk["files"] = files
            if let appState = incoming["appState"] { disk["appState"] = appState }
            result = disk
        }
        if conflicted {
            let drafts = file.deletingLastPathComponent().appendingPathComponent("conflicts", isDirectory: true)
            try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: incoming, options: [.sortedKeys])
                .write(to: drafts.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        }
        result["type"] = "f-whiteboard"; result["version"] = 1
        result["project"] = project.path; result.removeValue(forKey: "conversationID")
        result["revision"] = (disk["revision"] as? Int ?? 0) + 1
        result["updatedAt"] = ISO8601DateFormatter().string(from: Date()); result["updatedBy"] = "user"
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
        let incomingContent: [String: Any] = ["elements": incoming["elements"] ?? [], "files": incoming["files"] ?? [:]]
        let savedContent: [String: Any] = ["elements": result["elements"] ?? [], "files": result["files"] ?? [:]]
        return .saved(data, merged: !NSDictionary(dictionary: incomingContent).isEqual(to: savedContent), conflicted: conflicted)
    }
}
