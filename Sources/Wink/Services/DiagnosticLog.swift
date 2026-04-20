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

    static func logFileURL() -> URL { logURL }
}
