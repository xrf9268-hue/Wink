import Foundation
@testable import Wink

final class TestPersistenceHarness {
    let directory: URL
    let shortcutsURL: URL
    private let handle: TemporaryPersistenceDirectory

    init(fileManager: FileManager = .default) {
        let handle = TemporaryPersistenceDirectory(fileManager: fileManager)
        self.handle = handle
        self.directory = handle.directory
        self.shortcutsURL = handle.shortcutsURL
    }

    func makePersistenceService(
        diagnosticClient: PersistenceService.DiagnosticClient = .live,
        backupIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) -> PersistenceService {
        let handle = self.handle
        return PersistenceService(
            storageURLProvider: { handle.shortcutsURL },
            diagnosticClient: diagnosticClient,
            backupIDProvider: backupIDProvider
        )
    }

    func cleanup() {
        handle.cleanup()
    }
}

private final class TemporaryPersistenceDirectory: @unchecked Sendable {
    let directory: URL
    let shortcutsURL: URL
    private let fileManager: FileManager
    private var didCleanup = false

    init(fileManager: FileManager) {
        self.fileManager = fileManager
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fatalError("Failed to create temporary persistence directory: \(error)")
        }

        self.directory = directory
        self.shortcutsURL = directory.appendingPathComponent("shortcuts.json")
    }

    deinit {
        cleanup()
    }

    func cleanup() {
        guard !didCleanup else {
            return
        }

        didCleanup = true
        try? fileManager.removeItem(at: directory)
    }
}
