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
