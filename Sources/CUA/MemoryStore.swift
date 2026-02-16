import Foundation

/// Simple JSON-backed memory store for user preferences and context.
/// Persists at ~/.cua/memory.json across sessions.
final class MemoryStore: @unchecked Sendable {
    private var facts: [String] = []
    private let lock = NSLock()
    private let filePath: String
    private let logger: SessionLogger?

    init(logger: SessionLogger? = nil) {
        self.logger = logger
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.cua"
        self.filePath = "\(dir)/memory.json"

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Load existing memories
        if let data = FileManager.default.contents(atPath: filePath),
           let loaded = try? JSONDecoder().decode([String].self, from: data) {
            facts = loaded
            logger?.log("[memory] loaded \(loaded.count) facts")
        }
    }

    /// Add a new fact to memory. Deduplicates.
    func add(_ fact: String) {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        // Don't add duplicates (case-insensitive check)
        if !facts.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            facts.append(trimmed)
            save()
            logger?.log("[memory] stored: \(trimmed)")
        }
        lock.unlock()
    }

    /// Get all stored facts.
    func getAll() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return facts
    }

    /// Format facts as prompt context for injection into system prompts.
    func asPromptContext() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !facts.isEmpty else { return nil }
        let joined = facts.map { "- \($0)" }.joined(separator: "\n")
        return "User preferences and context from previous interactions:\n\(joined)"
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(facts) else { return }
        FileManager.default.createFile(atPath: filePath, contents: data)
    }
}
