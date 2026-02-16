import Foundation

final class SessionLogger: @unchecked Sendable {
    private let fileHandle: FileHandle
    let logPath: String
    private let sessionStart: Date

    /// Max sessions to keep on disk. Older logs are deleted at startup.
    private static let maxSessions = 5

    init() {
        let fm = FileManager.default
        let logsDir = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("logs").path

        // Create logs directory if needed
        try? fm.createDirectory(atPath: logsDir, withIntermediateDirectories: true)

        // Auto-cleanup: keep only the most recent sessions
        SessionLogger.pruneOldLogs(in: logsDir, keep: SessionLogger.maxSessions)

        // Create session log file with timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let path = "\(logsDir)/session_\(timestamp).log"
        self.logPath = path
        self.sessionStart = Date()

        fm.createFile(atPath: path, contents: nil)
        self.fileHandle = FileHandle(forWritingAtPath: path)!
    }

    deinit {
        fileHandle.closeFile()
    }

    func log(_ message: String) {
        let elapsed = Date().timeIntervalSince(sessionStart)
        let line = String(format: "[%7.2fs] %@\n", elapsed, message)
        if let data = line.data(using: .utf8) {
            fileHandle.write(data)
        }
    }

    func logRaw(_ label: String, _ content: String) {
        let maxBytes = 4000
        let capped = content.count > maxBytes
            ? String(content.prefix(maxBytes)) + "\n... [truncated \(content.count - maxBytes) chars]"
            : content
        log("--- \(label) ---")
        if let data = (capped + "\n").data(using: .utf8) {
            fileHandle.write(data)
        }
    }

    func logSeparator() {
        log(String(repeating: "=", count: 60))
    }

    /// Delete old session logs, keeping only the most recent `keep` files.
    private static func pruneOldLogs(in dir: String, keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let logFiles = files.filter { $0.hasPrefix("session_") && $0.hasSuffix(".log") }.sorted()
        if logFiles.count > keep {
            let toDelete = logFiles.prefix(logFiles.count - keep)
            for file in toDelete {
                try? fm.removeItem(atPath: "\(dir)/\(file)")
            }
        }
    }
}
