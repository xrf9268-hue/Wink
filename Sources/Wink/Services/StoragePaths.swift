import Foundation
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "StoragePaths")

enum StoragePaths {
    static let appDirectoryName = "Wink"

    static func appSupportDirectory() -> URL? {
        appSupportDirectory(fileManager: .default)
    }

    /// Returns nil when the directory cannot be created, so callers take
    /// their designed unavailability fallbacks (e.g. UsageTracker's :memory:
    /// database) instead of failing later at first write/open against a
    /// valid-looking URL.
    ///
    /// Logs via os.log only — DiagnosticLog writes to a file under this very
    /// directory, so routing the failure there would recurse.
    static func appSupportDirectory(fileManager fm: FileManager) -> URL? {
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directory = appSupport.appendingPathComponent(appDirectoryName, isDirectory: true)
        if !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                logger.error("Failed to create Application Support directory at \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return directory
    }
}
