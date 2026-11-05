import Foundation
import CryptoKit

struct RemoteProject: Codable, Equatable {
    let connection: SSHConnection
    let endpoint: String
    let path: String
    var displayName: String { "\(connection.address):\(path)" }
}

/// Metadata lives with F's data. The unchanged BoardStore maps this stable project URL to a board.
enum RemoteProjects {
    static func create(_ project: RemoteProject, root: URL = BoardStore.appSupport.appendingPathComponent("projects")) throws -> URL {
        guard project.path.hasPrefix("/"), !project.path.contains("\0") else { throw SSHFailure.message("远程项目路径无效。") }
        let identity = project.endpoint + "\0" + project.path
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent("ssh-" + hash, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(project)
        try data.write(to: directory.appendingPathComponent("remote-project.json"), options: .atomic)
        return directory
    }
    static func load(_ directory: URL) -> RemoteProject? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("remote-project.json")) else { return nil }
        return try? JSONDecoder().decode(RemoteProject.self, from: data)
    }
    static func display(_ directory: URL) -> String { load(directory)?.displayName ?? directory.path }
}
