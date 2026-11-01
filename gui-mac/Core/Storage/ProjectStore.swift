import AppKit
import AVKit
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

// MARK: - 项目文件夹

enum ProjectStore {
    private static let key = "LastProjectDirectory"
    private static let foldersKey = "FProjectFolders"

    /// A project exists as soon as its folder is opened, before its first message.
    static func folders(chats: [PiChat] = []) -> [URL] {
        var paths = UserDefaults.standard.stringArray(forKey: foldersKey) ?? []
        paths += chats.compactMap(\.cwd).filter { !$0.isEmpty }
        var seen = Set<String>()
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    static func title(for project: URL) -> String {
        if let remote = RemoteProjects.load(project) {
            return "\((remote.path as NSString).lastPathComponent) · \(remote.connection.address)"
        }
        return project.path == FileManager.default.homeDirectoryForCurrentUser.path ? "主目录" : project.lastPathComponent
    }

    static func initial() -> URL {
        if let path = UserDefaults.standard.string(forKey: key),
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let cwd = PiHistory.load().first?.cwd, !cwd.isEmpty {
            return URL(fileURLWithPath: cwd)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func remember(_ url: URL) {
        let path = url.standardizedFileURL.path
        UserDefaults.standard.set(path, forKey: key)
        var paths = UserDefaults.standard.stringArray(forKey: foldersKey) ?? []
        if !paths.contains(path) { paths.append(path); UserDefaults.standard.set(paths, forKey: foldersKey) }
    }
}

// MARK: - 画板存储

/// 画板数据不再散在项目里，统一放在 F 的软件数据目录下，一个项目一个子目录。
/// 目录名 = <项目名>-<路径哈希>，稳定、可读，也不会因重名冲突。
enum BoardStore {
    private static let rootKey = "BoardStorageRoot"

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("F", isDirectory: true)
    }

    static var defaultRoot: URL { appSupport.appendingPathComponent("boards", isDirectory: true) }

    /// 用户在设置里指定的保存路径；空 = 默认（软件数据目录）。
    static var root: URL {
        if let custom = UserDefaults.standard.string(forKey: rootKey),
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultRoot
    }

    static var isCustom: Bool {
        guard let custom = UserDefaults.standard.string(forKey: rootKey) else { return false }
        return !custom.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func setRoot(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: rootKey)
        } else {
            UserDefaults.standard.removeObject(forKey: rootKey)
        }
    }

    /// 展示用的、压缩过的路径（~ 开头）
    static var displayRoot: String {
        let path = root.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func directory(for project: URL) -> URL {
        let resolved = project.standardizedFileURL
        let raw = resolved.lastPathComponent.isEmpty ? "root" : resolved.lastPathComponent
        let slug = raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in resolved.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return root.appendingPathComponent("\(slug)-\(String(hash % 0xFFFFFF, radix: 16))", isDirectory: true)
    }

    static func sceneFile(for project: URL) -> URL {
        directory(for: project).appendingPathComponent("scene.json")
    }

    /// 旧版本把画板存在 <project>/.f/whiteboard/scene.json，首次切换到新位置时迁移过来。
    @discardableResult
    static func migrateLegacyScene(for project: URL) -> Bool {
        let legacy = project.standardizedFileURL
            .appendingPathComponent(".f/whiteboard", isDirectory: true)
            .appendingPathComponent("scene.json")
        let target = sceneFile(for: project)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return false }
        // 只迁移一次。统一存储中的现有画板始终优先，避免旧副本覆盖新数据。
        guard !FileManager.default.fileExists(atPath: target.path) else { return false }
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try FileManager.default.copyItem(at: legacy, to: target)
            return true
        } catch {
            return false
        }
    }
}

