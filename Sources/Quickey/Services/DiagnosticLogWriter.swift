import Foundation

final class DiagnosticLogWriter: @unchecked Sendable {
    private let fileURL: URL
    private let logPath: String
    private let formatter: ISO8601DateFormatter
    private let maxFileSize: UInt64
    private let queue: DispatchQueue
    private var directoryEnsured = false

    init(
        fileURL: URL,
        formatter: ISO8601DateFormatter = ISO8601DateFormatter(),
        maxFileSize: UInt64 = 512 * 1024,
        queue: DispatchQueue = DispatchQueue(label: "com.quickey.diagnostic-log")
    ) {
        self.fileURL = fileURL
        self.logPath = fileURL.path
        self.formatter = formatter
        self.maxFileSize = maxFileSize
        self.queue = queue
    }

    func log(_ message: String) {
        queue.sync {
            let line = "\(formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if !directoryEnsured {
                try? FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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
    }

    func rotateIfNeeded() {
        queue.sync {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
                  let size = attrs[.size] as? UInt64,
                  size > maxFileSize else { return }
            let backup = logPath + ".1"
            try? FileManager.default.removeItem(atPath: backup)
            try? FileManager.default.moveItem(atPath: logPath, toPath: backup)
        }
    }
}
