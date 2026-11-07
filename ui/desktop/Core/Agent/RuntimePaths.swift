import Foundation

enum PiPaths {
    static var isBundled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "FDistribution") as? String == "dmg"
    }

    static var userDataDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["F_USER_DATA_DIRECTORY"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("F", isDirectory: true)
    }

    static var defaultAgentDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return userDataDirectory.appendingPathComponent("agent", isDirectory: true)
    }

    static func environment(for cli: String, agentDirectory: URL? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PI_CODING_AGENT_DIR"] = agentDirectory?.path ?? defaultAgentDirectory.path
        env["F_USER_DATA_DIRECTORY"] = userDataDirectory.path
        env["F_DISTRIBUTION"] = isBundled ? "dmg" : "source"
        let node = nodeURL(for: cli)
        env["PATH"] = node.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        if isBundled {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
            env["F_CACHE_DIRECTORY"] = caches.appendingPathComponent("F").path
        }
        return env
    }

    /// Resolve the shared Node beside the Agent host, including compatibility CLI links.
    static func nodeURL(for cli: String) -> URL {
        URL(fileURLWithPath: cli).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("node/bin/node")
    }

    static var cliPath: String? {
        if isBundled, let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("runtime/agent/bin/f").path
            if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        }
        if let path = Bundle.main.object(forInfoDictionaryKey: "PiCLIPath") as? String,
           !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let path = ProcessInfo.processInfo.environment["PI_CLI"],
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let source = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in [source.appendingPathComponent("runtime/agent/bin/f").path, "\(home)/runtime/agent/bin/f"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

