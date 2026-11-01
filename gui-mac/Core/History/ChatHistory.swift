import AppKit
import AVKit
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

// MARK: - pi 会话记录

struct PiChat {
    let id: String
    let title: String
    let date: Date
    let path: URL
    let cwd: String?
}

enum PiHistory {
    /// 可能的 pi agent 目录，按优先级排列
    static func agentDirectory() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []

        if let configured = Bundle.main.object(forInfoDictionaryKey: "PiAgentDir") as? String,
           !configured.isEmpty {
            candidates.append(configured)
        }
        if let override = UserDefaults.standard.string(forKey: "PiAgentDir"), !override.isEmpty {
            candidates.append(override)
        }
        if let env = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"], !env.isEmpty {
            candidates.append(env)
        }

        let home = fm.homeDirectoryForCurrentUser.path
        candidates += [
            "\(home)/.pi/agent",
            "\(home)/Desktop/fy/pi/agent",
            "\(home)/pi/agent",
            "\(home)/Developer/pi/agent",
        ]

        for candidate in candidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            let sessions = URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: sessions.path, isDirectory: &isDir), isDir.boolValue {
                return sessions
            }
        }
        return nil
    }

    static func load() -> [PiChat] {
        guard let root = agentDirectory(),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              )
        else { return [] }

        var chats: [PiChat] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            guard let header = readHeader(url) else { continue }
            chats.append(PiChat(id: header.id, title: header.title, date: date, path: url, cwd: header.cwd))
        }
        return chats.sorted { $0.date > $1.date }
    }

    /// 读取会话文件开头，取出会话 id 和第一条用户消息
    private static func readHeader(_ url: URL) -> (id: String, title: String, cwd: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let data = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var id = url.deletingPathExtension().lastPathComponent
        var cwd: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: lineData),
                  let object = raw as? [String: Any]
            else { continue }

            switch object["type"] as? String {
            case "session":
                if let sessionID = object["id"] as? String { id = sessionID }
                if let directory = object["cwd"] as? String { cwd = directory }
            case "message":
                guard let message = object["message"] as? [String: Any],
                      message["role"] as? String == "user",
                      let content = textContent(message["content"]),
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                return (id, makeTitle(from: content), cwd ?? decodedProjectDirectory(url))
            default:
                continue
            }
        }
        return nil
    }

    /// 旧会话可能没写 `cwd`，但 pi 会把工作目录编码在会话目录名里：
    /// `--Users-fanfy-Desktop-fy--` → `/Users/fanfy/Desktop/fy`。
    static func decodedProjectDirectory(_ sessionURL: URL) -> String? {
        let name = sessionURL.deletingLastPathComponent().lastPathComponent
        guard name.hasPrefix("--"), name.hasSuffix("--"), name.count > 4 else { return nil }
        let body = name.dropFirst(2).dropLast(2)
        let candidates = [
            "/" + body.replacingOccurrences(of: "-", with: "/"),
            "/" + body,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func textContent(_ content: Any?) -> String? {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            var pieces: [String] = []
            for part in parts where part["type"] as? String == "text" {
                if let text = part["text"] as? String { pieces.append(text) }
            }
            return pieces.isEmpty ? nil : pieces.joined(separator: " ")
        }
        return nil
    }

    static let whiteboardMarker = "[[F_WHITEBOARD]]"

    /// 白板指令会带一段给 Agent 的说明；界面和标题只展示用户真正说的话。
    static func stripWhiteboardPrompt(_ text: String) -> String {
        guard text.contains(whiteboardMarker) else { return text }
        if let range = text.range(of: "用户要求：") {
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
            .replacingOccurrences(of: whiteboardMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 由用户的第一句话拟一个短标题（类似 Codex）
    static func makeTitle(from text: String) -> String {
        var title = stripWhiteboardPrompt(text).replacingOccurrences(of: "\r", with: " ")
        title = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")

        let fillers = ["请你", "请帮忙", "请帮我", "帮我", "帮忙", "麻烦", "能不能", "可以", "我想", "我要", "请"]
        var stripped = true
        while stripped {
            stripped = false
            for filler in fillers where title.hasPrefix(filler) {
                title.removeFirst(filler.count)
                title = title.trimmingCharacters(in: .whitespaces)
                stripped = true
                break
            }
        }

        if let index = title.firstIndex(where: { "。！？!?；;，,".contains($0) }) {
            let head = String(title[..<index]).trimmingCharacters(in: .whitespaces)
            if head.count >= 4 { title = head }
        }

        if title.count > 20 { title = String(title.prefix(20)) + "…" }
        return title.isEmpty ? "未命名对话" : title
    }

}

// MARK: - 自定义标题（Rename 后保存）

enum ChatTitles {
    private static let key = "ChatTitles"

    private static var map: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func title(for id: String) -> String? { map[id] }

    static func set(_ title: String, for id: String) {
        var all = map
        all[id] = title
        map = all
    }

    static func remove(for id: String) {
        var all = map
        all.removeValue(forKey: id)
        map = all
    }
}

// MARK: - 会话内容

struct ChatMessage {
    enum Role { case user, assistant }
    let role: Role
    let text: String
}

enum PiConversation {
    static func load(from url: URL) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        var messages: [ChatMessage] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: lineData),
                  let object = raw as? [String: Any],
                  object["type"] as? String == "message",
                  let message = object["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "user" || role == "assistant",
                  let rawContent = PiHistory.textContent(message["content"])
            else { continue }
            let content = role == "user" ? PiHistory.stripWhiteboardPrompt(rawContent) : rawContent
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            messages.append(ChatMessage(role: role == "user" ? .user : .assistant, text: content))
        }
        return messages
    }
}

