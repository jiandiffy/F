import Foundation
import CryptoKit

/// 每条对话一块画板，存在 `<画板目录>/conversations/<boardID>/scene.json`。
/// 项目目录只保留会话私有恢复状态和旧共享画板的迁移记录。
enum ConversationBoards {
    private static let key = "FConversationBoardIDs"
    private static let migrationMarker = "conversation-board-migration.json"
    private static let retiredDirectory = "retired"

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

    /// 对话自己的画板文件；视角、论文选择和中断记录仍在同一目录里。
    static func sceneFile(project: URL, id: String) -> URL {
        directory(project: project, id: id).appendingPathComponent("scene.json")
    }

    static func blankScene(project: URL) -> [String: Any] {
        [
            "type": "f-whiteboard",
            "version": 1,
            "revision": 0,
            "project": project.standardizedFileURL.path,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "updatedBy": "system",
            "elements": [],
            "appState": [
                "viewBackgroundColor": "transparent",
                "currentItemFontFamily": 5,
            ],
            "files": [:],
        ]
    }

    /// 兼容旧会话恢复入口：只迁移项目内的旧路径画板，再按对话分配。
    static func migrateLegacy(project: URL, session: String, id: String) {
        BoardStore.migrateLegacyScene(for: project)
        prepare(project: project, id: id)
    }

    /// 把旧共享项目画板一次性分回对话：来自某条对话的元素回到那条对话，
    /// 其余元素归最近使用画板的对话。找不到所属对话时只把旧文件移入
    /// `retired/`，界面不再显示它，但内容仍留在磁盘上。
    static func prepare(project: URL, id: String, defaults: UserDefaults = .standard) {
        let root = BoardStore.directory(for: project)
        let marker = root.appendingPathComponent(migrationMarker)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let projectScene = root.appendingPathComponent("scene.json")
        guard let lock = (try? ProjectSceneWriter.acquireLock(for: projectScene)) ?? nil else { return }
        defer { ProjectSceneWriter.releaseLock(lock) }
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        let archive = root.appendingPathComponent("conversations", isDirectory: true)
        var folders = ((try? FileManager.default.contentsOfDirectory(atPath: archive.path)) ?? []).sorted()
        // 正在打开的对话即使还没有目录、或目录被重建，也要参与本次分配。
        if !folders.contains(id) { folders.append(id) }
        let live = folders.filter { sessionPath(project: project, id: $0, defaults: defaults) != nil }
        let owner = live.isEmpty ? nil : ownerID(project: project, active: id, live: live)
        var record: [String: Any] = ["version": 1, "owner": owner.map { $0 as Any } ?? NSNull(),
            "retiredAt": ISO8601DateFormatter().string(from: Date()),
            "reason": "per-conversation-boards"]

        if let data = try? Data(contentsOf: projectScene),
           let scene = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let elements = scene["elements"] as? [[String: Any]] {
            let split = splitLegacy(elements: elements, files: scene["files"] as? [String: Any] ?? [:], folders: folders)
            if let owner {
                adopt(split.current, into: sceneFile(project: project, id: owner), project: project, scene: scene)
            }
            for (folder, bucket) in split.legacy where live.contains(folder) {
                let target = sceneFile(project: project, id: folder)
                guard !FileManager.default.fileExists(atPath: target.path) else { continue }
                adopt(bucket, into: target, project: project, scene: scene)
            }
            record["legacyFolders"] = split.legacy.keys.sorted()
            record["droppedElements"] = split.dropped
        }

        // 旧项目画板不再参与加载；保留原文件供恢复或人工查看。
        if FileManager.default.fileExists(atPath: projectScene.path) {
            let retired = root.appendingPathComponent(retiredDirectory, isDirectory: true)
            try? FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let target = retired.appendingPathComponent("project-scene-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: projectScene, to: target)
                record["archive"] = target.lastPathComponent
            } catch {
                NSLog("F: shared project board kept in place: %@", error.localizedDescription)
                record["archive"] = NSNull()
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: marker, options: .atomic)
        }
    }

    private struct Bucket {
        var elements: [[String: Any]] = []
        var files: [String: Any] = [:]
        var isEmpty: Bool { elements.isEmpty && files.isEmpty }
    }

    /// `legacy-<boardID>-` 前缀来自上一次合并，属于对应对话自己的图元。
    /// 返回有归属的元素、按对话拆分的旧元素，以及找不到对话而不再显示的旧元素数量。
    private static func splitLegacy(elements: [[String: Any]], files: [String: Any], folders: [String]) -> (current: Bucket, legacy: [String: Bucket], dropped: Int) {
        var current = Bucket()
        var legacy: [String: Bucket] = [:]
        var dropped = 0
        for var element in elements {
            guard let id = element["id"] as? String else { continue }
            if let folder = folders.first(where: { id.hasPrefix("legacy-" + $0 + "-") }) {
                strip("legacy-" + folder + "-", from: &element)
                legacy[folder, default: Bucket()].elements.append(element)
            } else if id.hasPrefix("legacy-") {
                dropped += 1
            } else {
                current.elements.append(element)
            }
        }
        for (id, value) in files {
            if let folder = folders.first(where: { id.hasPrefix("legacy-" + $0 + "-") }) {
                var file = value as? [String: Any] ?? [:]
                file["id"] = String(id.dropFirst("legacy-".count + folder.count + 1))
                legacy[folder, default: Bucket()].files[file["id"] as? String ?? id] = file
            } else if id.hasPrefix("legacy-") {
                dropped += 1
            } else {
                current.files[id] = value
            }
        }
        return (current, legacy, dropped)
    }

    /// 去掉命名空间前缀，同时修正所有指向它的引用，绑定关系和图片仍可编辑。
    private static func strip(_ prefix: String, from element: inout [String: Any]) {
        func plain(_ value: String) -> String { value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value }
        for key in ["id", "containerId", "frameId", "fileId"] {
            if let value = element[key] as? String { element[key] = plain(value) }
        }
        for key in ["startBinding", "endBinding"] {
            if var binding = element[key] as? [String: Any], let id = binding["elementId"] as? String {
                binding["elementId"] = plain(id)
                element[key] = binding
            }
        }
        if let groups = element["groupIds"] as? [String] { element["groupIds"] = groups.map(plain) }
        if let bound = element["boundElements"] as? [[String: Any]] {
            element["boundElements"] = bound.map { item -> [String: Any] in
                var item = item
                if let id = item["id"] as? String { item["id"] = plain(id) }
                return item
            }
        }
    }

    /// 新对话直接接收整块内容；已有画板只追加缺失元素并向右排开，避免覆盖已有图形。
    private static func adopt(_ bucket: Bucket, into target: URL, project: URL, scene: [String: Any]) {
        guard !bucket.isEmpty else { return }
        var result = blankScene(project: project)
        var existing: [[String: Any]] = []
        if FileManager.default.fileExists(atPath: target.path),
           let data = try? Data(contentsOf: target),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            result = object
            existing = object["elements"] as? [[String: Any]] ?? []
        }
        let known = Set(existing.compactMap { $0["id"] as? String })
        var incoming = bucket.elements.filter { !known.contains($0["id"] as? String ?? "") }
        if !existing.isEmpty, !incoming.isEmpty {
            let maxX = existing.map { ($0["x"] as? Double ?? 0) + ($0["width"] as? Double ?? 0) }.max() ?? -160
            let minX = incoming.map { $0["x"] as? Double ?? 0 }.min() ?? 0
            let minY = incoming.map { $0["y"] as? Double ?? 0 }.min() ?? 0
            for index in incoming.indices {
                incoming[index]["x"] = (incoming[index]["x"] as? Double ?? 0) - minX + maxX + 160
                incoming[index]["y"] = (incoming[index]["y"] as? Double ?? 0) - minY + (existing.map { $0["y"] as? Double ?? 0 }.min() ?? 0)
            }
        }
        guard !incoming.isEmpty || !bucket.files.isEmpty else { return }
        result["elements"] = existing + incoming
        var files = result["files"] as? [String: Any] ?? [:]
        for (id, value) in bucket.files { files[id] = value }
        result["files"] = files
        result["revision"] = (result["revision"] as? Int ?? scene["revision"] as? Int ?? 0) + 1
        result["updatedAt"] = (scene["updatedAt"] as? String) ?? ISO8601DateFormatter().string(from: Date())
        result["updatedBy"] = "system"
        result["project"] = project.standardizedFileURL.path
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: target, options: .atomic)
        } catch {
            NSLog("F: conversation board adoption failed: %@", error.localizedDescription)
        }
    }

    /// 会话文件存在才算“找到对应的对话”。
    static func sessionPath(project: URL, id: String, defaults: UserDefaults = .standard) -> String? {
        let aliases = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return aliases.filter { $0.value == id }.keys.sorted().first { FileManager.default.fileExists(atPath: $0) }
    }

    /// 最近使用画板的对话接收共享画板里没有归属的图元。
    private static func ownerID(project: URL, active: String, live: [String]) -> String {
        func date(_ id: String, _ name: String) -> TimeInterval {
            let file = directory(project: project, id: id).appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modified = attributes[.modificationDate] as? Date else { return 0 }
            return modified.timeIntervalSince1970
        }
        return live.max { lhs, rhs in
            let left = (date(lhs, "viewport.json"), date(lhs, "scene.json"), lhs == active ? 1 : 0, lhs)
            let right = (date(rhs, "viewport.json"), date(rhs, "scene.json"), rhs == active ? 1 : 0, rhs)
            return left < right
        } ?? active
    }
}
