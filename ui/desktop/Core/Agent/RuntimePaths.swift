import Foundation

enum PiPaths {
    /// Resolve the shared Node beside the Agent host, including compatibility CLI links.
    static func nodeURL(for cli: String) -> URL {
        URL(fileURLWithPath: cli).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("node/bin/node")
    }

    static var cliPath: String? {
        if let path = Bundle.main.object(forInfoDictionaryKey: "PiCLIPath") as? String,
           !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let path = ProcessInfo.processInfo.environment["PI_CLI"],
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["\(home)/Desktop/fy/F/runtime/agent/bin/f", "\(home)/runtime/agent/bin/f"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

