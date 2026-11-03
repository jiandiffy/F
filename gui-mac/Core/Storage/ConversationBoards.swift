import Foundation
import CryptoKit

/// Conversation identity remains private to queues, drafts and restart checkpoints.
/// The project scene lives one level above these legacy conversation directories.
enum ConversationBoards {
    private static let key = "FConversationBoardIDs"

    static func id(for session: String, defaults: UserDefaults = .standard) -> String {
        let path = URL(fileURLWithPath: session).standardizedFileURL.path
        if let id = (defaults.dictionary(forKey: key) as? [String: String])?[path] { return id }
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func bind(session: String, id: String, defaults: UserDefaults = .standard) {
        let path = URL(fileURLWithPath: session).standardizedFileURL.path
        var aliases = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard aliases[path] != id else { return }
        aliases[path] = id
        defaults.set(aliases, forKey: key)
    }

    static func directory(project: URL, id: String) -> URL {
        precondition(!id.isEmpty && id.range(of: "^[a-f0-9-]+$", options: .regularExpression) != nil)
        return BoardStore.directory(for: project).appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    /// Compatibility entry point for callers restoring an older session.
    static func migrateLegacy(project: URL, session: String, id: String) {
        BoardStore.migrateLegacyScene(for: project)
        mergeIntoProject(project: project)
    }

    /// Copy old diagrams beside the current project scene, retaining every original file.
    /// Namespaced IDs preserve bindings and image references when conversations reused IDs.
    static func mergeIntoProject(project: URL) {
        let root = BoardStore.directory(for: project)
        let archive = root.appendingPathComponent("conversations", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil) else { return }
        let target = root.appendingPathComponent("scene.json")
        let marker = root.appendingPathComponent("project-board-migration.json")
        do {
            guard let lock = try ProjectSceneWriter.acquireLock(for: target) else { return }
            defer { ProjectSceneWriter.releaseLock(lock) }
            var imported = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: marker))) ?? []
            var scene: [String: Any] = ["type": "f-whiteboard", "version": 1, "revision": 0, "project": project.path,
                                       "elements": [], "files": [:], "appState": ["viewBackgroundColor": "transparent"]]
            if FileManager.default.fileExists(atPath: target.path) {
                guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any] else { return }
                scene = existing
            }
            var elements = scene["elements"] as? [[String: Any]] ?? []
            var files = scene["files"] as? [String: Any] ?? [:]
            var changed = false
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !imported.contains(folder.lastPathComponent) {
                let source = folder.appendingPathComponent("scene.json")
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let old = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any]
                guard let oldElements = old?["elements"] as? [[String: Any]] else { continue }
                let prefix = "legacy-" + folder.lastPathComponent + "-"
                let existingIDs = Set(elements.compactMap { $0["id"] as? String })
                let maxX = elements.map { ($0["x"] as? Double ?? 0) + ($0["width"] as? Double ?? 0) }.max() ?? -160
                let minX = oldElements.map { $0["x"] as? Double ?? 0 }.min() ?? 0
                let minY = oldElements.map { $0["y"] as? Double ?? 0 }.min() ?? 0
                func reference(_ value: Any) -> Any {
                    if var object = value as? [String: Any], let id = object["elementId"] as? String {
                        object["elementId"] = prefix + id; return object
                    }
                    return value
                }
                for var element in oldElements {
                    guard let id = element["id"] as? String, !existingIDs.contains(prefix + id) else { continue }
                    element["id"] = prefix + id
                    element["x"] = (element["x"] as? Double ?? 0) - minX + maxX + 160
                    element["y"] = (element["y"] as? Double ?? 0) - minY
                    for key in ["containerId", "frameId", "fileId"] {
                        if let value = element[key] as? String { element[key] = prefix + value }
                    }
                    for key in ["startBinding", "endBinding"] {
                        if let value = element[key] { element[key] = reference(value) }
                    }
                    if let groups = element["groupIds"] as? [String] { element["groupIds"] = groups.map { prefix + $0 } }
                    if let bound = element["boundElements"] as? [[String: Any]] {
                        element["boundElements"] = bound.map { item -> [String: Any] in
                            var item = item
                            if let id = item["id"] as? String { item["id"] = prefix + id }
                            return item
                        }
                    }
                    elements.append(element)
                }
                for (id, value) in old?["files"] as? [String: Any] ?? [:] {
                    var file = value as? [String: Any] ?? [:]
                    file["id"] = prefix + id; files[prefix + id] = file
                }
                imported.append(folder.lastPathComponent); changed = true
            }
            guard changed else { return }
            scene["elements"] = elements; scene["files"] = files
            scene["revision"] = (scene["revision"] as? Int ?? 0) + 1
            try JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys]).write(to: target, options: .atomic)
            try JSONEncoder().encode(imported).write(to: marker, options: .atomic)
        } catch { NSLog("F: project board migration retained originals: %@", error.localizedDescription) }
    }
}
