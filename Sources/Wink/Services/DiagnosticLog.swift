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

    /// Runs `body` as a consistent snapshot: on the writer's queue, after a
    /// synchronize, with no queued write or rotation able to interleave. The
    /// export reads BOTH log files inside one of these — a flush alone
    /// leaves a window where the next write's rotation tears the pair.
    static func withSnapshot<T>(_ body: () -> T) -> T {
        writer.withSnapshot(body)
    }

    static func logFileURL() -> URL { logURL }
}
