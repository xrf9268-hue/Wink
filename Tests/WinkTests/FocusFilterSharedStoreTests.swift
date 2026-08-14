import Foundation
import Testing
@testable import WinkFocusShared

@Suite("Focus Filter shared store")
struct FocusFilterSharedStoreTests {
    @Test
    func extensionTransitionsPreserveTheExactManualRestoreTarget() throws {
        let harness = FocusSharedStoreHarness()
        defer { harness.cleanup() }
        let store = harness.store
        let baseID = UUID()
        let workID = UUID()

        try store.replaceCatalog(
            FocusProfileCatalog(profiles: [
                FocusProfileRecord(id: baseID, name: "Default"),
                FocusProfileRecord(id: workID, name: "Work"),
            ])
        )
        _ = try store.setManualProfileID(baseID)
        _ = try store.applyFocusSelection(profileID: workID, pauseShortcuts: true)

        var state = try store.loadState()
        #expect(state.profileID == workID)
        #expect(state.pauseShortcuts)
        #expect(state.manualProfileID == baseID)

        // The default-value perform on Focus deactivation removes only the
        // overlay fields. The main app still owns restoring and then clearing
        // this exact base id.
        _ = try store.applyFocusSelection(profileID: nil, pauseShortcuts: false)
        state = try store.loadState()
        #expect(state.profileID == nil)
        #expect(!state.pauseShortcuts)
        #expect(state.manualProfileID == baseID)

        _ = try store.clearManualProfileIDAfterRestore()
        #expect(try store.loadState().manualProfileID == nil)
    }

    @Test
    func stateMutationFlushesTheFileAndDirectoryBeforeReturning() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wink-focus-durable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = FocusDurabilityRecorder()
        let store = FocusFilterSharedStore(
            directoryProvider: { directory },
            fileManager: .default,
            durabilityClient: .init(flush: { recorder.record($0) })
        )
        let baseID = UUID()

        _ = try store.setManualProfileID(baseID)

        #expect(recorder.flushedURLs == [
            directory.appendingPathComponent(WinkFocusSharedContract.stateFileName)
        ])
        #expect(try store.loadState().manualProfileID == baseID)
    }

    @Test
    func catalogDeletionFlushesBeforeItAuthorizesCanonicalDeletion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wink-focus-catalog-durable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = FocusDurabilityRecorder()
        let store = FocusFilterSharedStore(
            directoryProvider: { directory },
            fileManager: .default,
            durabilityClient: .init(flush: { recorder.record($0) })
        )
        let deletedID = UUID()
        try store.replaceCatalog(
            FocusProfileCatalog(
                profiles: [FocusProfileRecord(id: deletedID, name: "Deleted")]
            )
        )

        let result = try store.replaceCatalogForDeletion(
            FocusProfileCatalog(profiles: []),
            deleting: deletedID
        )

        #expect(result == .updated)
        #expect(recorder.flushedURLs == [
            directory.appendingPathComponent(WinkFocusSharedContract.catalogFileName),
            directory.appendingPathComponent(WinkFocusSharedContract.catalogFileName)
        ])
        #expect(try store.loadCatalog().profiles.isEmpty)
    }

    @Test
    func staleEntityFailsWithoutReplacingTheLastValidSelection() throws {
        let harness = FocusSharedStoreHarness()
        defer { harness.cleanup() }
        let store = harness.store
        let validID = UUID()
        let staleID = UUID()

        try store.replaceCatalog(
            FocusProfileCatalog(profiles: [FocusProfileRecord(id: validID, name: "Work")])
        )
        _ = try store.applyFocusSelection(profileID: validID, pauseShortcuts: false)

        #expect(throws: FocusFilterSharedStoreError.profileNotFound(staleID)) {
            _ = try store.applyFocusSelection(profileID: staleID, pauseShortcuts: true)
        }
        let state = try store.loadState()
        #expect(state.profileID == validID)
        #expect(!state.pauseShortcuts)
    }

    @Test
    func compareAndApplySkipsAnObsoleteSnapshotWithoutRunningItsBody() throws {
        let harness = FocusSharedStoreHarness()
        defer { harness.cleanup() }
        let store = harness.store
        let firstID = UUID()
        let secondID = UUID()
        let firstState = FocusFilterSharedState(
            profileID: firstID,
            pauseShortcuts: false,
            manualProfileID: UUID()
        )
        _ = try store.setManualProfileID(firstState.manualProfileID)
        try store.replaceCatalog(
            FocusProfileCatalog(profiles: [
                FocusProfileRecord(id: firstID, name: "First"),
                FocusProfileRecord(id: secondID, name: "Second"),
            ])
        )
        _ = try store.applyFocusSelection(profileID: firstID, pauseShortcuts: false)
        let obsoleteSnapshot = try store.loadState()
        _ = try store.applyFocusSelection(profileID: secondID, pauseShortcuts: true)

        var bodyRan = false
        let result: Bool? = try store.updateStateIfCurrent(obsoleteSnapshot) { _ in
            bodyRan = true
            return true
        }

        #expect(result == nil)
        #expect(!bodyRan)
        #expect(try store.loadState().profileID == secondID)
        #expect(try store.loadState().pauseShortcuts)
    }

    @Test
    func profileDeletionAndFocusSelectionAreSerializedInBothOrders() throws {
        let firstHarness = FocusSharedStoreHarness()
        defer { firstHarness.cleanup() }
        let profileID = UUID()
        let catalog = FocusProfileCatalog(
            profiles: [FocusProfileRecord(id: profileID, name: "Work")]
        )
        try firstHarness.store.replaceCatalog(catalog)
        _ = try firstHarness.store.applyFocusSelection(
            profileID: profileID,
            pauseShortcuts: false
        )

        #expect(
            try firstHarness.store.replaceCatalogForDeletion(
                FocusProfileCatalog(profiles: []),
                deleting: profileID
            ) == .profileInUse
        )
        #expect(try firstHarness.store.loadCatalog().profiles.contains { $0.id == profileID })

        let secondHarness = FocusSharedStoreHarness()
        defer { secondHarness.cleanup() }
        try secondHarness.store.replaceCatalog(catalog)
        #expect(
            try secondHarness.store.replaceCatalogForDeletion(
                FocusProfileCatalog(profiles: []),
                deleting: profileID
            ) == .updated
        )
        #expect(throws: FocusFilterSharedStoreError.profileNotFound(profileID)) {
            _ = try secondHarness.store.applyFocusSelection(
                profileID: profileID,
                pauseShortcuts: false
            )
        }
    }
}

private final class FocusDurabilityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var flushedURLs: [URL] {
        lock.withLock { urls }
    }

    func record(_ url: URL) {
        lock.withLock { urls.append(url) }
    }
}

private final class FocusSharedStoreHarness: @unchecked Sendable {
    let directory: URL
    let store: FocusFilterSharedStore

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wink-focus-shared-\(UUID().uuidString)", isDirectory: true)
        store = FocusFilterSharedStore(directoryProvider: { [directory] in directory })
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
