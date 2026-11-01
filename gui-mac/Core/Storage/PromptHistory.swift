import Foundation

/// Shared by the chat and board composers of one project. Never stores model output or credentials.
final class PromptHistory {
    static let limit = 200
    private let defaults: UserDefaults
    private let key: String
    private(set) var entries: [String]

    init(project: URL, conversationID: String? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "FPromptHistory." + BoardStore.directory(for: project).lastPathComponent + (conversationID.map { "." + $0 } ?? "")
        entries = defaults.stringArray(forKey: key) ?? []
    }

    func record(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 1_000_000, entries.last != value else { return }
        entries.append(value)
        // Bound both entry count and total text, including very large pasted prompts.
        while entries.count > Self.limit || (entries.count > 1 && entries.reduce(0, { $0 + $1.utf8.count }) > 1_000_000) {
            entries.removeFirst()
        }
        defaults.set(entries, forKey: key)
    }
}
