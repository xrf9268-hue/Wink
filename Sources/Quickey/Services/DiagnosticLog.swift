import Foundation

/// File-based diagnostic log for user-exportable diagnostics.
/// Independent of os.log — not a Logger wrapper.
enum DiagnosticLog: Sendable {
    /// Shared subsystem identifier for all Logger instances in the app.
    static let subsystem = "com.quickey.app"

    private static let logURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/Quickey/debug.log")

    private static let logPath: String = logURL.path

    private static let maxFileSize: UInt64 = 512 * 1024 // 512 KB

    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private nonisolated(unsafe) static var directoryEnsured = false

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !directoryEnsured {
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            directoryEnsured = true
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }

    static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? UInt64,
              size > maxFileSize else { return }
        let backup = logPath + ".1"
        try? FileManager.default.removeItem(atPath: backup)
        try? FileManager.default.moveItem(atPath: logPath, toPath: backup)
    }

    static func logFileURL() -> URL { logURL }
}
