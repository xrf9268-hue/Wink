import Foundation
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "PersistenceService")

struct PersistenceService: Sendable {
    struct DiagnosticClient: Sendable {
        let log: @Sendable (String) -> Void

        static let live = DiagnosticClient(log: DiagnosticLog.log)
    }

    enum LoadError: Error, LocalizedError, Sendable {
        case storageUnavailable
        case fileReadFailed(path: String, reason: String)
        case decodeFailed(path: String, reason: String, preservedCopyPath: String?)

        var errorDescription: String? {
            switch self {
            case .storageUnavailable:
                return "Failed to load shortcuts: path unavailable"
            case let .fileReadFailed(path, reason):
                return "Failed to load shortcuts: path=\(path) reason=\(reason)"
            case let .decodeFailed(path, reason, preservedCopyPath):
                let backupDescription = preservedCopyPath ?? "none"
                return "Failed to load shortcuts: path=\(path) reason=\(reason) preservedCopyPath=\(backupDescription)"
            }
        }
    }

    private let storageURLProvider: @Sendable () -> URL?
    private let diagnosticClient: DiagnosticClient
    private let backupIDProvider: @Sendable () -> String

    init(
        storageURLProvider: @escaping @Sendable () -> URL? = {
            StoragePaths.appSupportDirectory()?.appendingPathComponent("shortcuts.json")
        },
        diagnosticClient: DiagnosticClient = .live,
        backupIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.storageURLProvider = storageURLProvider
        self.diagnosticClient = diagnosticClient
        self.backupIDProvider = backupIDProvider
    }

    func load() throws -> [AppShortcut] {
        guard let url = storageURLProvider() else {
            let error = LoadError.storageUnavailable
            logLoadFailure(error)
            throw error
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let loadError = LoadError.fileReadFailed(
                path: url.path,
                reason: error.localizedDescription
            )
            logLoadFailure(loadError)
            throw loadError
        }

        do {
            return try JSONDecoder().decode([AppShortcut].self, from: data)
        } catch {
            let preservedCopyPath = preserveUnreadablePayload(data, originalURL: url)
            let loadError = LoadError.decodeFailed(
                path: url.path,
                reason: error.localizedDescription,
                preservedCopyPath: preservedCopyPath
            )
            logLoadFailure(loadError)
            throw loadError
        }
    }

    func save(_ shortcuts: [AppShortcut]) {
        guard let url = storageURLProvider() else {
            let message = "Failed to save shortcuts: path unavailable"
            logger.error("\(message, privacy: .public)")
            diagnosticClient.log(message)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(shortcuts)
            try data.write(to: url, options: .atomic)
        } catch {
            let message = "Failed to save shortcuts: path=\(url.path) reason=\(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
            diagnosticClient.log(message)
        }
    }

    private func preserveUnreadablePayload(_ data: Data, originalURL: URL) -> String? {
        let backupURL = backupURL(for: originalURL)

        do {
            try data.write(to: backupURL, options: .atomic)
            return backupURL.path
        } catch {
            let message = "Failed to preserve unreadable shortcuts payload: path=\(originalURL.path) backupPath=\(backupURL.path) reason=\(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
            diagnosticClient.log(message)
            return nil
        }
    }

    private func backupURL(for originalURL: URL) -> URL {
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let pathExtension = originalURL.pathExtension.isEmpty ? "json" : originalURL.pathExtension
        let backupName = "\(baseName).load-failure-\(backupIDProvider()).\(pathExtension)"

        return originalURL.deletingLastPathComponent().appendingPathComponent(backupName)
    }

    private func logLoadFailure(_ error: LoadError) {
        let message = error.localizedDescription
        logger.error("\(message, privacy: .public)")
        diagnosticClient.log(message)
    }
}
