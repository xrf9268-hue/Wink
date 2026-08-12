import Foundation
import Testing
@testable import Wink

@Test
func concurrentWritesProduceOneLinePerMessage() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("debug.log")
    let writer = DiagnosticLogWriter(fileURL: fileURL, maxFileSize: .max)
    let messageCount = 300

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<messageCount {
            group.addTask {
                writer.log("message-\(index)-" + String(repeating: "x", count: 256))
            }
        }
    }
    writer.flush()

    let contents = try String(contentsOf: fileURL, encoding: .utf8)
    let lines = contents.split(separator: "\n")

    #expect(lines.count == messageCount)
    #expect(lines.contains { $0.contains("message-0-") })
    #expect(lines.contains { $0.contains("message-299-") })
}

@Test
func exceedingMaxFileSizeRotatesAndContinuesWritingToNewFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("debug.log")
    // Force rotation on every write by making both thresholds small.
    let writer = DiagnosticLogWriter(
        fileURL: fileURL,
        maxFileSize: 256,
        rotationCheckInterval: 32
    )

    // Fill well past maxFileSize; a tail line will land in the freshly
    // rotated file.
    let padding = String(repeating: "a", count: 128)
    for i in 0..<20 {
        writer.log("bulk-\(i)-\(padding)")
    }
    writer.log("tail")
    writer.flush()

    let backupURL = URL(fileURLWithPath: fileURL.path + ".1")
    #expect(FileManager.default.fileExists(atPath: backupURL.path))

    let current = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(current.contains("tail"))

    let currentSize = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64) ?? 0
    #expect(currentSize <= 256)
}

@Test
func explicitRotateIfNeededMovesFileAndLetsNextWriteContinue() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("debug.log")
    let writer = DiagnosticLogWriter(
        fileURL: fileURL,
        maxFileSize: 64,
        rotationCheckInterval: .max // disable inline rotation
    )

    let padding = String(repeating: "b", count: 32)
    for i in 0..<8 {
        writer.log("line-\(i)-\(padding)")
    }
    writer.flush()

    writer.rotateIfNeeded()

    writer.log("post-rotate")
    writer.flush()

    let backupURL = URL(fileURLWithPath: fileURL.path + ".1")
    #expect(FileManager.default.fileExists(atPath: backupURL.path))

    let current = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(current.contains("post-rotate"))
    #expect(!current.contains("line-0-"))
}

// MARK: - Rotated backup inclusion (#461 finding 3)

@Test
func collectLogsIncludesTheRotatedBackupWhenOneExists() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let primaryURL = directory.appendingPathComponent("debug.log")
    try "current session".write(to: primaryURL, atomically: true, encoding: .utf8)
    let backupURL = directory.appendingPathComponent("debug.log.1")
    try "earlier session".write(to: backupURL, atomically: true, encoding: .utf8)

    let logs = DiagnosticsClientLive.collectLogs(primaryURL: primaryURL, fileManager: .default)

    #expect(logs.count == 2)
    #expect(logs[0].name == "debug.log")
    #expect(logs[0].contents == "current session")
    #expect(logs[1].name == "debug.log.1")
    #expect(logs[1].contents == "earlier session")
}

@Test
func collectLogsOmitsTheBackupEntryWhenNoRotationHasHappened() throws {
    // The common case: most exports never see a rotation, so an export must
    // not carry a permanent "debug.log.1 was missing" note that trains users
    // to ignore real gaps.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let primaryURL = directory.appendingPathComponent("debug.log")
    try "current session".write(to: primaryURL, atomically: true, encoding: .utf8)

    let logs = DiagnosticsClientLive.collectLogs(primaryURL: primaryURL, fileManager: .default)

    #expect(logs.count == 1)
    #expect(logs[0].name == "debug.log")
}

@Test
func collectLogsReportsAMissingPrimaryLogWithoutThrowing() {
    // A log that cannot be read is a diagnostic in its own right — collectLogs
    // must not throw or crash when the primary file does not exist.
    let missingURL = URL(fileURLWithPath: "/tmp/wink-diagnostics-test-\(UUID().uuidString)/debug.log")

    let logs = DiagnosticsClientLive.collectLogs(primaryURL: missingURL, fileManager: .default)

    #expect(logs.count == 1)
    #expect(logs[0].contents == nil)
}
