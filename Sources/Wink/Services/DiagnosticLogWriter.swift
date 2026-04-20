import Foundation

final class DiagnosticLogWriter: @unchecked Sendable {
    private let fileURL: URL
    private let logPath: String
    private let formatter: ISO8601DateFormatter
    private let maxFileSize: UInt64
    private let rotationCheckInterval: UInt64
    private let queue: DispatchQueue
    private var directoryEnsured = false
    private var handle: FileHandle?
    private var bytesWrittenSinceRotationCheck: UInt64 = 0

    init(
        fileURL: URL,
        formatter: ISO8601DateFormatter = ISO8601DateFormatter(),
        maxFileSize: UInt64 = 512 * 1024,
        rotationCheckInterval: UInt64 = 64 * 1024,
        queue: DispatchQueue = DispatchQueue(label: "com.wink.diagnostic-log")
    ) {
        self.fileURL = fileURL
        self.logPath = fileURL.path
        self.formatter = formatter
        self.maxFileSize = maxFileSize
        self.rotationCheckInterval = rotationCheckInterval
        self.queue = queue
    }

    deinit {
        try? handle?.close()
    }

    func log(_ message: String) {
        let timestamp = Date()
        queue.async { [self] in
            let line = "\(formatter.string(from: timestamp)) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            guard let handle = ensureHandle() else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                // Backing file may have been removed (e.g. external rotation);
                // drop the current handle so the next write reopens.
                try? handle.close()
                self.handle = nil
                return
            }
            bytesWrittenSinceRotationCheck &+= UInt64(data.count)
            if bytesWrittenSinceRotationCheck >= rotationCheckInterval {
                bytesWrittenSinceRotationCheck = 0
                rotateIfNeededLocked()
            }
        }
    }

    /// Block until all pending writes are flushed.
    func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    func rotateIfNeeded() {
        queue.sync {
            rotateIfNeededLocked()
        }
    }

    // MARK: - Private (queue-bound)

    private func ensureHandle() -> FileHandle? {
        if let handle { return handle }
        if !directoryEnsured {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            directoryEnsured = true
        }
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        guard let newHandle = FileHandle(forWritingAtPath: logPath) else { return nil }
        try? newHandle.seekToEnd()
        handle = newHandle
        return newHandle
    }

    private func rotateIfNeededLocked() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? UInt64,
              size > maxFileSize else { return }
        // Close current handle so the moved file is released before rename.
        try? handle?.close()
        handle = nil
        bytesWrittenSinceRotationCheck = 0
        let backup = logPath + ".1"
        try? FileManager.default.removeItem(atPath: backup)
        try? FileManager.default.moveItem(atPath: logPath, toPath: backup)
        // Next log() call re-opens via ensureHandle().
    }
}
