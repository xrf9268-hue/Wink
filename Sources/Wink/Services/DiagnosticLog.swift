import Foundation

/// File-based diagnostic log for user-exportable diagnostics.
/// Independent of os.log — not a Logger wrapper.
enum DiagnosticLog: Sendable {
    /// Shared subsystem identifier for all Logger instances in the app.
    static let subsystem = "com.wink.app"

    private static let logURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/Wink/debug.log")
    private static let writer = DiagnosticLogWriter(fileURL: logURL)

    static func log(_ message: String) {
        writer.log(message)
    }

    static func rotateIfNeeded() {
        writer.rotateIfNeeded()
    }

    /// Blocks until every `log()` call queued before this one has been
    /// written. `log()` is fire-and-forget for the sake of the hot path, so
    /// anything that reads the log file back out — the diagnostics export in
    /// particular — must call this first or it can race the writer's queue
    /// and silently miss the most recent lines.
    static func flush() {
        writer.flush()
    }

    static func logFileURL() -> URL { logURL }
}
