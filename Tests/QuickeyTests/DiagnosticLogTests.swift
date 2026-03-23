import Foundation
import Testing
@testable import Quickey

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

    let contents = try String(contentsOf: fileURL, encoding: .utf8)
    let lines = contents.split(separator: "\n")

    #expect(lines.count == messageCount)
    #expect(lines.contains { $0.contains("message-0-") })
    #expect(lines.contains { $0.contains("message-299-") })
}
