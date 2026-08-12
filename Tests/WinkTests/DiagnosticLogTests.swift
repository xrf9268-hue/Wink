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

// MARK: - Flush barrier before export reads the log (#461 finding 4)

@Test
func flushMakesEveryQueuedWriteVisibleToAnImmediateRead() throws {
    // Mirrors what a diagnostics export needs: log() queues its write on the
    // writer's private queue and returns immediately, so a read taken right
    // after the last log() call — with no sleep, no delay — must still see
    // every one of them once flush() returns. flush() is the only thing
    // standing between the last enqueued write and the read.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("debug.log")
    let writer = DiagnosticLogWriter(fileURL: fileURL, maxFileSize: .max)

    for index in 0..<200 {
        writer.log("event-\(index)")
    }
    writer.flush()

    let contents = try String(contentsOf: fileURL, encoding: .utf8)
    let lines = contents.split(separator: "\n")

    #expect(lines.count == 200)
    #expect(lines.contains { $0.contains("event-199") })
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
func anExportNeverMergesIntoAnExistingFolder() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    // The folder from an earlier export, holding a file the CURRENT package
    // no longer contains. Merging would leave it inside the folder the user
    // shares — data the preview never showed.
    let destination = parent.appendingPathComponent("Wink-diagnostics-20260812-010203", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let stale = destination.appendingPathComponent("debug.log.1")
    try "earlier session, absent from the new preview".write(to: stale, atomically: true, encoding: .utf8)

    let package = DiagnosticsPackage(entries: [
        .init(name: "report.md", summary: "summary", contents: "fresh report"),
    ])
    let written = try DiagnosticsClientLive.write(package, to: destination)

    // A unique sibling, containing exactly the previewed entries.
    #expect(written != destination)
    #expect(written.lastPathComponent == "Wink-diagnostics-20260812-010203-2")
    let names = try FileManager.default.contentsOfDirectory(atPath: written.path).sorted()
    #expect(names == ["report.md"])
    // And the earlier export was left exactly as it was.
    #expect(try String(contentsOf: stale, encoding: .utf8) == "earlier session, absent from the new preview")
}

@Test
func anExportToAFreshNameUsesThatNameUnchanged() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let destination = parent.appendingPathComponent("Wink-diagnostics-20260812-010203", isDirectory: true)
    let package = DiagnosticsPackage(entries: [
        .init(name: "report.md", summary: "summary", contents: "fresh report"),
    ])
    let written = try DiagnosticsClientLive.write(package, to: destination)

    #expect(written == destination)
    #expect(try String(contentsOf: destination.appendingPathComponent("report.md"), encoding: .utf8) == "fresh report")
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
