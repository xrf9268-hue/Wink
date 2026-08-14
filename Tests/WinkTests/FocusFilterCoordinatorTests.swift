import Foundation
import CoreGraphics
import Testing
@testable import WinkFocusShared
@testable import Wink

@Suite("Focus Filter coordinator")
@MainActor
struct FocusFilterCoordinatorTests {
    @Test
    func focusProfileOverridesRuntimeWhileManualChangesOnlyUpdateTheRestoreBase() throws {
        let context = try FocusCoordinatorContext()
        defer { context.cleanup() }
        let defaultID = try #require(context.profileState.activeProfileID)
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        context.profileState.createProfile(named: "Personal", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        let personalID = try #require(context.profileState.profiles.first { $0.name == "Personal" }?.id)

        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-activate")

        #expect(context.profileState.activeProfileID == workID)
        #expect(context.profileState.focusProfileID == workID)
        #expect(context.profileState.manualProfileIDDuringFocus == defaultID)
        #expect(try context.focusStore.loadState().manualProfileID == defaultID)

        context.profileState.switchToProfile(personalID)
        #expect(context.profileState.activeProfileID == workID)
        #expect(context.profileState.manualProfileIDDuringFocus == personalID)
        #expect(try context.focusStore.loadState().manualProfileID == personalID)

        _ = try context.focusStore.applyFocusSelection(profileID: nil, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-deactivate")

        #expect(context.profileState.activeProfileID == personalID)
        #expect(context.profileState.focusProfileID == nil)
        #expect(context.profileState.manualProfileIDDuringFocus == nil)
        #expect(try context.focusStore.loadState().manualProfileID == nil)
    }

    @Test
    func focusToFocusChangePreservesTheOriginalManualRestoreBase() throws {
        let context = try FocusCoordinatorContext()
        defer { context.cleanup() }
        let defaultID = try #require(context.profileState.activeProfileID)
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        context.profileState.createProfile(named: "Personal", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        let personalID = try #require(context.profileState.profiles.first { $0.name == "Personal" }?.id)

        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-first-focus")
        _ = try context.focusStore.applyFocusSelection(profileID: personalID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-second-focus")

        #expect(context.profileState.activeProfileID == personalID)
        #expect(context.profileState.manualProfileIDDuringFocus == defaultID)
        #expect(try context.focusStore.loadState().manualProfileID == defaultID)

        _ = try context.focusStore.applyFocusSelection(profileID: nil, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-deactivate")
        #expect(context.profileState.activeProfileID == defaultID)
    }

    @Test
    func relaunchRebuildsEffectiveManualAndFocusStateFromDurableFiles() throws {
        let context = try FocusCoordinatorContext()
        defer { context.cleanup() }
        let defaultID = try #require(context.profileState.activeProfileID)
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)

        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: true)
        context.coordinator.reconcile(reason: "test-before-relaunch")
        #expect(context.profileState.activeProfileID == workID)
        #expect(context.profileState.manualProfileIDDuringFocus == defaultID)

        context.coordinator.stop()
        context.profileState.clearFocusOverlay()
        context.preferences.setFocusPauseActive(false)
        context.shortcutStore.replaceAll(with: context.profileState.loadAtStartup())
        context.coordinator.start()

        #expect(context.profileState.activeProfileID == workID)
        #expect(context.profileState.focusProfileID == workID)
        #expect(context.profileState.manualProfileIDDuringFocus == defaultID)
        #expect(context.preferences.focusPauseActive)
        #expect(!context.preferences.shortcutsPaused)

        _ = try context.focusStore.applyFocusSelection(profileID: nil, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-after-relaunch-deactivate")
        #expect(context.profileState.activeProfileID == defaultID)
        #expect(!context.preferences.focusPauseActive)
    }

    @Test
    func automaticProfileSwitchDefersWhileEditorWorkIsUnsaved() throws {
        let readiness = FocusReadinessState(hasUnsavedWork: true)
        let context = try FocusCoordinatorContext(readiness: readiness)
        defer { context.cleanup() }
        let defaultID = try #require(context.profileState.activeProfileID)
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)

        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-defer")

        #expect(context.profileState.activeProfileID == defaultID)
        #expect(context.profileState.focusProfileID == workID)
        #expect(context.profileState.manualProfileIDDuringFocus == defaultID)
        #expect(!context.profileState.isFocusProfileApplied)

        readiness.hasUnsavedWork = false
        context.coordinator.reconcile(reason: "test-ready")
        #expect(context.profileState.activeProfileID == workID)
        #expect(context.profileState.isFocusProfileApplied)
    }

    @Test
    func manualRestoreChoicePreservesDeferredAndStaleFocusReporting() throws {
        let readiness = FocusReadinessState(hasUnsavedWork: true)
        let context = try FocusCoordinatorContext(readiness: readiness)
        defer { context.cleanup() }
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        context.profileState.createProfile(named: "Personal", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        let personalID = try #require(context.profileState.profiles.first { $0.name == "Personal" }?.id)

        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-deferred-reporting")
        let deferredStatus = context.profileState.statusMessage

        context.profileState.switchToProfile(personalID)

        #expect(context.profileState.manualProfileIDDuringFocus == personalID)
        #expect(!context.profileState.isFocusProfileApplied)
        #expect(context.profileState.statusMessage == deferredStatus)

        let staleID = UUID()
        let stateURL = context.focusDirectory.appendingPathComponent(
            WinkFocusSharedContract.stateFileName
        )
        try JSONEncoder().encode(
            FocusFilterSharedState(
                profileID: staleID,
                pauseShortcuts: false,
                manualProfileID: personalID
            )
        ).write(to: stateURL, options: .atomic)
        context.coordinator.reconcile(reason: "test-stale-reporting")
        let staleError = context.profileState.errorMessage

        context.profileState.switchToProfile(workID)

        #expect(context.profileState.manualProfileIDDuringFocus == workID)
        #expect(context.profileState.errorMessage == staleError)
        #expect(context.profileState.errorMessage?.contains("no longer exists") == true)
    }

    @Test
    func catalogKeepsStableIDsAcrossRenameAndExcludesUnreadableProfiles() throws {
        let context = try FocusCoordinatorContext()
        defer { context.cleanup() }
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        context.profileState.createProfile(named: "Broken", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        let brokenID = try #require(context.profileState.profiles.first { $0.name == "Broken" }?.id)
        try context.profileHarness.writeRaw(
            "{ unreadable-profile",
            to: context.profileHarness.layout.profileDataURL(brokenID)
        )
        context.shortcutStore.replaceAll(with: context.profileState.loadAtStartup())
        #expect(context.profileState.unreadableProfileIDs.contains(brokenID))

        context.coordinator.start()
        #expect(context.profileState.renameProfile(workID, to: "Renamed Work"))

        let catalog = try context.focusStore.loadCatalog()
        #expect(catalog.profiles.contains { $0.id == workID && $0.name == "Renamed Work" })
        #expect(!catalog.profiles.contains { $0.id == brokenID })
    }

    @Test
    func failedProfileApplyKeepsCurrentProfileAndRetriesAfterRepair() async throws {
        let context = try FocusCoordinatorContext(retryDelays: [.zero])
        defer { context.cleanup() }
        let defaultID = try #require(context.profileState.activeProfileID)
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        let workURL = context.profileHarness.layout.profileDataURL(workID)
        let validBytes = try Data(contentsOf: workURL)

        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        try context.profileHarness.writeRaw("{ unreadable-profile", to: workURL)
        context.coordinator.reconcile(reason: "test-apply-failure")

        #expect(context.profileState.activeProfileID == defaultID)
        #expect(context.profileState.focusProfileID == workID)
        #expect(context.profileState.errorMessage != nil)
        #expect(try context.focusStore.loadState().profileID == workID)
        #expect(context.profileState.unreadableProfileIDs.contains(workID))
        #expect(context.coordinator.hasScheduledRetry)

        try validBytes.write(to: workURL, options: .atomic)
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(context.profileState.activeProfileID == workID)
        #expect(context.profileState.errorMessage == nil)
        #expect((try context.focusStore.loadCatalog()).profiles.contains { $0.id == workID })
    }

    @Test
    func failedManualRestoreRetriesAfterTheProfileBecomesReadable() async throws {
        let context = try FocusCoordinatorContext(retryDelays: [.zero])
        defer { context.cleanup() }
        let defaultID = try #require(context.profileState.activeProfileID)
        let defaultURL = context.profileHarness.layout.profileDataURL(defaultID)
        let validBytes = try Data(contentsOf: defaultURL)
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)

        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-activate-before-restore-failure")
        #expect(context.profileState.activeProfileID == workID)

        try context.profileHarness.writeRaw("{ unreadable-profile", to: defaultURL)
        _ = try context.focusStore.applyFocusSelection(profileID: nil, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-restore-failure")

        #expect(context.profileState.activeProfileID == workID)
        #expect(context.profileState.manualProfileIDDuringFocus == defaultID)
        #expect(try context.focusStore.loadState().manualProfileID == defaultID)
        #expect(context.coordinator.hasScheduledRetry)

        try validBytes.write(to: defaultURL, options: .atomic)
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(context.profileState.activeProfileID == defaultID)
        #expect(context.profileState.manualProfileIDDuringFocus == nil)
        #expect(try context.focusStore.loadState().manualProfileID == nil)
        #expect(!context.coordinator.hasScheduledRetry)
    }

    @Test
    func restoreMarkerSurvivesUntilTheRestoredPointerIsDurable() async throws {
        let writeGate = FocusDurableActivePointerWriteGate()
        let context = try FocusCoordinatorContext(
            profileWriteClient: ShortcutProfileStore.WriteClient(
                write: { data, url in
                    try data.write(to: url, options: .atomic)
                },
                writeDurable: { data, url in
                    if writeGate.shouldFail(url) {
                        throw FocusInjectedWriteFailure()
                    }
                    try data.write(to: url, options: .atomic)
                }
            ),
            retryDelays: [.zero]
        )
        defer { context.cleanup() }
        let defaultID = try #require(context.profileState.activeProfileID)
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)

        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-durable-restore-activate")
        writeGate.failActivePointerWrites = true
        _ = try context.focusStore.applyFocusSelection(profileID: nil, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-durable-restore-failure")

        #expect(context.profileState.activeProfileID == defaultID)
        #expect(context.profileState.focusRestorePending)
        #expect(try context.focusStore.loadState().manualProfileID == defaultID)
        #expect(context.coordinator.hasScheduledRetry)
        #expect(context.profileState.errorMessage != nil)

        writeGate.failActivePointerWrites = false
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(!context.profileState.focusRestorePending)
        #expect(try context.focusStore.loadState().manualProfileID == nil)
        #expect(!context.coordinator.hasScheduledRetry)
        #expect(context.profileState.errorMessage == nil)
    }

    @Test
    func durableFocusSelectionBlocksDeleteBeforeTheInMemoryOverlayCatchesUp() throws {
        let context = try FocusCoordinatorContext()
        defer { context.cleanup() }
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        context.coordinator.start()

        // Simulate the extension winning immediately before the main app's
        // Darwin-notification reconciliation reaches the main actor.
        _ = try context.focusStore.applyFocusSelection(
            profileID: workID,
            pauseShortcuts: false
        )
        #expect(context.profileState.focusProfileID == nil)

        context.profileState.deleteProfile(workID)

        #expect(context.profileState.profiles.contains { $0.id == workID })
        #expect(try context.focusStore.loadCatalog().profiles.contains { $0.id == workID })
        #expect(context.profileState.errorMessage?.contains("in use") == true)
    }

    @Test
    func focusMessagesPreserveCompatibilityMirrorWarnings() throws {
        let context = try FocusCoordinatorContext(
            profileWriteClient: ShortcutProfileStore.WriteClient { data, url in
                if url.lastPathComponent == "shortcuts.json" {
                    throw FocusInjectedWriteFailure()
                }
                try data.write(to: url, options: .atomic)
            }
        )
        defer { context.cleanup() }
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)

        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-mirror-warning-activate")

        #expect(context.profileState.activeProfileID == workID)
        #expect(context.profileState.statusMessage?.contains("Focus is using") == true)
        #expect(context.profileState.statusMessage?.contains("compatibility file could not be rewritten") == true)

        _ = try context.focusStore.applyFocusSelection(profileID: nil, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-mirror-warning-restore")

        #expect(context.profileState.statusMessage?.contains("Focus ended") == true)
        #expect(context.profileState.statusMessage?.contains("compatibility file could not be rewritten") == true)
    }

    @Test
    func successfulProfileMutationsDoNotHideCatalogPublicationFailures() throws {
        let context = try FocusCoordinatorContext()
        defer { context.cleanup() }
        let catalogURL = context.focusDirectory.appendingPathComponent(
            WinkFocusSharedContract.catalogFileName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: catalogURL,
            withIntermediateDirectories: true
        )
        context.coordinator.start()
        let expectedError = try #require(context.profileState.errorMessage)

        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        #expect(context.profileState.errorMessage == expectedError)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)

        #expect(context.profileState.renameProfile(workID, to: "Renamed Work"))
        #expect(context.profileState.errorMessage == expectedError)

        context.profileState.switchToProfile(workID)
        #expect(context.profileState.errorMessage == expectedError)

        context.profileState.deleteProfile(workID)
        #expect(context.profileState.errorMessage == expectedError)
        #expect(context.profileState.profiles.contains { $0.id == workID })
    }

    @Test
    func startupCatalogPublicationRetriesAfterATransientWriteFailure() async throws {
        let context = try FocusCoordinatorContext(retryDelays: [.zero])
        defer { context.cleanup() }
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        let catalogURL = context.focusDirectory.appendingPathComponent(
            WinkFocusSharedContract.catalogFileName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)

        context.coordinator.start()
        #expect(context.coordinator.hasScheduledCatalogRetry)
        #expect(context.profileState.errorMessage != nil)

        try FileManager.default.removeItem(at: catalogURL)
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(!context.coordinator.hasScheduledCatalogRetry)
        #expect(context.profileState.errorMessage == nil)
        #expect(try context.focusStore.loadCatalog().profiles.contains { $0.id == workID })
    }

    @Test
    func failedDeleteRestoresTheCatalogEntryInvalidatedBeforeCommit() throws {
        let writeGate = FocusProfileWriteGate()
        let context = try FocusCoordinatorContext(
            profileWriteClient: ShortcutProfileStore.WriteClient { data, url in
                if writeGate.shouldFail(url) {
                    throw FocusInjectedWriteFailure()
                }
                try data.write(to: url, options: .atomic)
            }
        )
        defer { context.cleanup() }
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        context.coordinator.start()
        #expect((try context.focusStore.loadCatalog()).profiles.contains { $0.id == workID })

        writeGate.failManifestWrites = true
        context.profileState.deleteProfile(workID)

        #expect(context.profileState.profiles.contains { $0.id == workID })
        #expect((try context.focusStore.loadCatalog()).profiles.contains { $0.id == workID })
        #expect(context.profileState.errorMessage != nil)
    }

    @Test
    func failedDeletionDurabilityBarrierRestoresTheStillExistingCatalogEntry() throws {
        let durabilityGate = FocusCatalogDurabilityGate()
        let context = try FocusCoordinatorContext(
            focusDurabilityClient: .init(flush: { url in
                try durabilityGate.flush(url)
            })
        )
        defer { context.cleanup() }
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        context.coordinator.start()
        #expect((try context.focusStore.loadCatalog()).profiles.contains { $0.id == workID })

        let flushCountBeforeDeletion = durabilityGate.catalogFlushCount
        durabilityGate.failNextCatalogFlush = true
        context.profileState.deleteProfile(workID)

        #expect(context.profileState.profiles.contains { $0.id == workID })
        #expect((try context.focusStore.loadCatalog()).profiles.contains { $0.id == workID })
        #expect(durabilityGate.catalogFlushCount == flushCountBeforeDeletion + 2)
        #expect(!context.coordinator.hasScheduledCatalogRetry)
        #expect(context.profileState.errorMessage != nil)
    }

    @Test
    func endingAStaleFocusClearsOnlyTheFocusOwnedError() throws {
        let context = try FocusCoordinatorContext()
        defer { context.cleanup() }
        let catalogURL = context.focusDirectory.appendingPathComponent(
            WinkFocusSharedContract.catalogFileName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: catalogURL,
            withIntermediateDirectories: true
        )
        context.coordinator.start()
        let catalogError = try #require(context.profileState.errorMessage)
        let staleID = UUID()
        let stateURL = context.focusDirectory.appendingPathComponent(
            WinkFocusSharedContract.stateFileName
        )
        try JSONEncoder().encode(
            FocusFilterSharedState(profileID: staleID, pauseShortcuts: false)
        ).write(to: stateURL, options: .atomic)
        context.coordinator.reconcile(reason: "test-stale-focus")
        #expect(context.profileState.errorMessage?.contains("no longer exists") == true)

        _ = try context.focusStore.applyFocusSelection(profileID: nil, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-stale-focus-ended")

        #expect(context.profileState.focusProfileID == nil)
        #expect(context.profileState.errorMessage == catalogError)
        #expect(context.profileState.errorMessage?.contains("no longer exists") == false)
    }

    @Test
    func recoveryChoiceResolvesZeroShortcutStateBeforeApplyingFocus() throws {
        // Keep the generic readiness seam blocked to prove that this explicit
        // recovery transaction does not defer its second apply to a later turn.
        let readiness = FocusReadinessState(hasUnsavedWork: true)
        let context = try FocusCoordinatorContext(readiness: readiness)
        defer { context.cleanup() }
        let defaultID = try #require(context.profileState.activeProfileID)
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        context.profileState.createProfile(named: "Personal", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        let personalID = try #require(context.profileState.profiles.first { $0.name == "Personal" }?.id)

        // System Settings can activate the filter while Wink is absent. On
        // relaunch the old active profile is unreadable, so startup must arm
        // zero shortcuts and ask rather than guessing a replacement.
        context.coordinator.start()
        context.coordinator.stop()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        try context.profileHarness.writeRaw(
            "{ unreadable-profile",
            to: context.profileHarness.layout.profileDataURL(defaultID)
        )
        context.shortcutStore.replaceAll(with: context.profileState.loadAtStartup())
        #expect(context.profileState.activeProfileID == nil)
        #expect(context.shortcutStore.shortcuts.isEmpty)

        context.coordinator.start()
        #expect(context.profileState.focusProfileID == workID)
        context.profileState.switchToProfile(personalID)

        // The explicit choice resolves recovery synchronously, persists the
        // restore base, and reapplies Focus before this main-actor turn can
        // deliver a shortcut against the recovery choice.
        #expect(context.profileState.activeProfileID == workID)
        #expect(context.profileState.recovery == .none)
        #expect(try context.focusStore.loadState().manualProfileID == personalID)
        #expect(context.profileState.manualProfileIDDuringFocus == personalID)
    }

    @Test
    func focusPauseComposesWithoutMutatingManualPause() throws {
        let context = try FocusCoordinatorContext()
        defer { context.cleanup() }
        context.coordinator.start()

        context.preferences.setShortcutsPaused(true)
        _ = try context.focusStore.applyFocusSelection(profileID: nil, pauseShortcuts: true)
        context.coordinator.reconcile(reason: "test-pause")
        #expect(context.preferences.shortcutsPaused)
        #expect(context.preferences.focusPauseActive)
        #expect(context.manager.shortcutCaptureStatus().shortcutsPaused)

        context.preferences.setShortcutsPaused(false)
        #expect(context.manager.shortcutCaptureStatus().shortcutsPaused)

        _ = try context.focusStore.applyFocusSelection(profileID: nil, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-resume")
        #expect(!context.preferences.focusPauseActive)
        #expect(!context.preferences.shortcutsPaused)
        #expect(!context.manager.shortcutCaptureStatus().shortcutsPaused)
    }

    @Test
    func focusAndRestoreProfilesCannotBeDeleted() throws {
        let context = try FocusCoordinatorContext()
        defer { context.cleanup() }
        let defaultID = try #require(context.profileState.activeProfileID)
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-protection")

        context.profileState.deleteProfile(workID)
        #expect(context.profileState.profiles.contains { $0.id == workID })
        context.profileState.deleteProfile(defaultID)
        #expect(context.profileState.profiles.contains { $0.id == defaultID })
    }

    @Test
    func manualChoiceDuringDeferredRestoreBecomesTheNewCrashSafeTarget() async throws {
        let readiness = FocusReadinessState()
        let context = try FocusCoordinatorContext(readiness: readiness)
        defer { context.cleanup() }
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        context.profileState.createProfile(named: "Personal", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        let personalID = try #require(context.profileState.profiles.first { $0.name == "Personal" }?.id)
        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-activate")

        readiness.hasUnsavedWork = true
        _ = try context.focusStore.applyFocusSelection(profileID: nil, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-deferred-restore")
        #expect(context.profileState.focusRestorePending)

        // A manual switch may discard its own drafts. It writes Personal as
        // the restore target before the active pointer changes; the queued
        // reconciliation then sees the target already active and clears it
        // without requiring automatic-switch readiness.
        context.profileState.switchToProfile(personalID)
        await Task.yield()

        #expect(context.profileState.activeProfileID == personalID)
        #expect(!context.profileState.focusRestorePending)
        #expect(try context.focusStore.loadState().manualProfileID == nil)
    }

    @Test
    func manualChoiceDuringDeferredRestoreKeepsTheDraftDiscardWarning() async throws {
        let readiness = FocusReadinessState()
        let discardState = FocusDiscardState()
        let context = try FocusCoordinatorContext(
            readiness: readiness,
            prepareForSwitch: { discardState.snapshot() }
        )
        defer { context.cleanup() }
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        context.profileState.createProfile(named: "Personal", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        let personalID = try #require(context.profileState.profiles.first { $0.name == "Personal" }?.id)
        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-warning-activate")

        readiness.hasUnsavedWork = true
        _ = try context.focusStore.applyFocusSelection(profileID: nil, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-warning-deferred-restore")
        #expect(context.profileState.focusRestorePending)

        discardState.shouldDiscardRecorder = true
        context.profileState.switchToProfile(personalID)
        await Task.yield()

        #expect(context.profileState.activeProfileID == personalID)
        #expect(!context.profileState.focusRestorePending)
        #expect(context.profileState.statusMessage?.contains("Focus ended") == true)
        #expect(context.profileState.statusMessage?.contains("stopped the shortcut recording") == true)
    }

    @Test
    func failedFinalManualRestoreStateCommitRetriesTheDurableMarker() async throws {
        let readiness = FocusReadinessState()
        let writeGate = FocusSharedStateWriteGate()
        let context = try FocusCoordinatorContext(
            readiness: readiness,
            focusWriteClient: .init(write: { data, url in
                if writeGate.shouldFail(url) {
                    throw FocusInjectedWriteFailure()
                }
                try data.write(to: url, options: .atomic)
            }),
            retryDelays: [.zero]
        )
        defer { context.cleanup() }
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        context.profileState.createProfile(named: "Personal", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        let personalID = try #require(context.profileState.profiles.first { $0.name == "Personal" }?.id)
        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-final-commit-activate")

        readiness.hasUnsavedWork = true
        _ = try context.focusStore.applyFocusSelection(profileID: nil, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-final-commit-deferred-restore")
        #expect(context.profileState.focusRestorePending)

        // The first state write durably changes the restore target to Personal.
        // Fail only the second write that clears the marker after runtime apply.
        writeGate.failAfterSuccessfulStateWrites(1)
        context.profileState.switchToProfile(personalID)

        #expect(context.profileState.activeProfileID == personalID)
        #expect(try context.focusStore.loadState().manualProfileID == personalID)
        #expect(context.coordinator.hasScheduledRetry)

        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(try context.focusStore.loadState().manualProfileID == nil)
        #expect(!context.profileState.focusRestorePending)
        #expect(!context.coordinator.hasScheduledRetry)
        #expect(context.profileState.errorMessage == nil)
    }

    @Test
    func newlyActivatedFocusWinsADeferredRestoreManualSelectionSynchronously() throws {
        let readiness = FocusReadinessState()
        let context = try FocusCoordinatorContext(readiness: readiness)
        defer { context.cleanup() }
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        context.profileState.createProfile(named: "Personal", duplicatingActiveProfile: false)
        context.profileState.createProfile(named: "Exercise", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        let personalID = try #require(context.profileState.profiles.first { $0.name == "Personal" }?.id)
        let exerciseID = try #require(context.profileState.profiles.first { $0.name == "Exercise" }?.id)

        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-race-first-focus")
        readiness.hasUnsavedWork = true
        _ = try context.focusStore.applyFocusSelection(profileID: nil, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-race-deferred-restore")
        #expect(context.profileState.focusRestorePending)

        // The new Focus lands before the UI's stale pending-restore branch
        // handles the click. Readiness is now clear, so the callback must
        // re-read and apply Exercise under the shared lock; Personal may only
        // become the later restoration target.
        readiness.hasUnsavedWork = false
        _ = try context.focusStore.applyFocusSelection(
            profileID: exerciseID,
            pauseShortcuts: false
        )
        context.profileState.switchToProfile(personalID)

        #expect(context.profileState.activeProfileID == exerciseID)
        #expect(context.profileState.focusProfileID == exerciseID)
        #expect(context.profileState.manualProfileIDDuringFocus == personalID)
        #expect(try context.focusStore.loadState().manualProfileID == personalID)
    }

    @Test
    func manualSelectionRepairsFocusProfileWithoutReenteringTheSharedLock() async throws {
        let context = try FocusCoordinatorContext()
        defer { context.cleanup() }
        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        context.profileState.createProfile(named: "Personal", duplicatingActiveProfile: false)
        context.profileState.createProfile(named: "Repaired", duplicatingActiveProfile: false)
        let workID = try #require(context.profileState.profiles.first { $0.name == "Work" }?.id)
        let personalID = try #require(context.profileState.profiles.first { $0.name == "Personal" }?.id)
        let repairedID = try #require(context.profileState.profiles.first { $0.name == "Repaired" }?.id)
        let repairedURL = context.profileHarness.layout.profileDataURL(repairedID)
        let validBytes = try Data(contentsOf: repairedURL)

        // Keep the startup classification stale while repairing the file on
        // disk. The next real apply removes the ID from the unreadable set and
        // republishes the Focus catalog.
        try context.profileHarness.writeRaw("{ unreadable-profile", to: repairedURL)
        context.shortcutStore.replaceAll(with: context.profileState.loadAtStartup())
        #expect(context.profileState.unreadableProfileIDs.contains(repairedID))
        try validBytes.write(to: repairedURL, options: .atomic)

        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: workID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-repaired-lock-first-focus")

        // Durable Focus state advances to Repaired before this manual click
        // reaches the coordinator. Applying it happens under focus-filter.lock;
        // the catalog callback must wait until that transaction releases it.
        let stateURL = context.focusDirectory.appendingPathComponent(
            WinkFocusSharedContract.stateFileName
        )
        try JSONEncoder().encode(
            FocusFilterSharedState(
                profileID: repairedID,
                pauseShortcuts: false,
                manualProfileID: try context.focusStore.loadState().manualProfileID
            )
        ).write(to: stateURL, options: .atomic)
        context.profileState.switchToProfile(personalID)
        await Task.yield()

        #expect(context.profileState.activeProfileID == repairedID)
        #expect(!context.profileState.unreadableProfileIDs.contains(repairedID))
        #expect(try context.focusStore.loadCatalog().profiles.contains { $0.id == repairedID })
    }

    @Test
    func deferredFocusStatusPreservesCompatibilityMirrorWarning() throws {
        let readiness = FocusReadinessState()
        let context = try FocusCoordinatorContext(
            readiness: readiness,
            profileWriteClient: ShortcutProfileStore.WriteClient { data, url in
                if url.lastPathComponent == ShortcutProfileLayout.mirrorFileName {
                    throw FocusInjectedWriteFailure()
                }
                try data.write(to: url, options: .atomic)
            }
        )
        defer { context.cleanup() }
        context.profileState.createProfile(named: "Manual", duplicatingActiveProfile: false)
        context.profileState.createProfile(named: "Focus", duplicatingActiveProfile: false)
        let manualID = try #require(context.profileState.profiles.first { $0.name == "Manual" }?.id)
        let focusID = try #require(context.profileState.profiles.first { $0.name == "Focus" }?.id)
        context.profileState.switchToProfile(manualID)
        #expect(context.profileState.statusMessage?.contains("compatibility file could not be rewritten") == true)

        readiness.hasUnsavedWork = true
        context.coordinator.start()
        _ = try context.focusStore.applyFocusSelection(profileID: focusID, pauseShortcuts: false)
        context.coordinator.reconcile(reason: "test-deferred-mirror-warning")

        #expect(context.profileState.activeProfileID == manualID)
        #expect(context.profileState.statusMessage?.contains("waiting") == true)
        #expect(context.profileState.statusMessage?.contains("compatibility file could not be rewritten") == true)
    }
}

@MainActor
private final class FocusCoordinatorContext {
    let profileHarness = TestProfileHarness()
    let focusDirectory: URL
    let focusStore: FocusFilterSharedStore
    let profileStore: ShortcutProfileStore
    let shortcutStore: ShortcutStore
    let manager: ShortcutManager
    let profileState: ShortcutProfileState
    let preferences: AppPreferences
    let coordinator: FocusFilterCoordinator
    private let defaults: UserDefaults
    private let defaultsSuiteName: String

    init(
        readiness: FocusReadinessState = FocusReadinessState(),
        prepareForSwitch: @escaping @MainActor () -> DiscardedProfileSwitchDrafts = { .init() },
        profileWriteClient: ShortcutProfileStore.WriteClient = .live,
        focusWriteClient: FocusFilterSharedStore.WriteClient = .live,
        focusDurabilityClient: FocusFilterSharedStore.DurabilityClient = .live,
        retryDelays: [Duration] = [
            .milliseconds(250),
            .seconds(1),
            .seconds(3),
            .seconds(8),
            .seconds(15),
        ]
    ) throws {
        try profileHarness.writeLegacyShortcuts([])
        profileStore = profileHarness.makeStore(writeClient: profileWriteClient)
        shortcutStore = ShortcutStore()
        manager = ShortcutManager(
            shortcutStore: shortcutStore,
            persistenceService: profileStore.makeActiveProfilePersistenceService(),
            appSwitcher: FocusFakeAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FocusFakeCaptureProvider(),
                hyperProvider: FocusFakeHyperCaptureProvider()
            ),
            permissionService: FocusFakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )
        profileState = ShortcutProfileState(
            store: profileStore,
            shortcutManager: manager,
            prepareForSwitch: prepareForSwitch,
            hasUnsavedEditorWork: { readiness.hasUnsavedWork }
        )
        shortcutStore.replaceAll(with: profileState.loadAtStartup())

        defaultsSuiteName = "FocusFilterCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        preferences = AppPreferences(
            shortcutManager: manager,
            hyperKeyService: HyperKeyService(runner: { _ in true }, defaults: defaults),
            userDefaults: defaults
        )
        focusDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wink-focus-coordinator-\(UUID().uuidString)", isDirectory: true)
        focusStore = FocusFilterSharedStore(
            directoryProvider: { [focusDirectory] in focusDirectory },
            fileManager: .default,
            durabilityClient: focusDurabilityClient,
            writeClient: focusWriteClient
        )
        coordinator = FocusFilterCoordinator(
            store: focusStore,
            profileState: profileState,
            preferences: preferences,
            retryDelays: retryDelays,
            diagnosticClient: .init(log: { _ in })
        )
    }

    func cleanup() {
        coordinator.stop()
        profileHarness.cleanup()
        try? FileManager.default.removeItem(at: focusDirectory)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}

@MainActor
private final class FocusDiscardState {
    var shouldDiscardRecorder = false

    func snapshot() -> DiscardedProfileSwitchDrafts {
        DiscardedProfileSwitchDrafts(cancelledRecorder: shouldDiscardRecorder)
    }
}

private struct FocusInjectedWriteFailure: Error {}

private final class FocusProfileWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _failManifestWrites = false

    var failManifestWrites: Bool {
        get { lock.withLock { _failManifestWrites } }
        set { lock.withLock { _failManifestWrites = newValue } }
    }

    func shouldFail(_ url: URL) -> Bool {
        lock.withLock {
            _failManifestWrites && url.lastPathComponent == ShortcutProfileLayout.manifestFileName
        }
    }
}

private final class FocusDurableActivePointerWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _failActivePointerWrites = false

    var failActivePointerWrites: Bool {
        get { lock.withLock { _failActivePointerWrites } }
        set { lock.withLock { _failActivePointerWrites = newValue } }
    }

    func shouldFail(_ url: URL) -> Bool {
        lock.withLock {
            _failActivePointerWrites
                && url.lastPathComponent == ShortcutProfileLayout.activePointerFileName
        }
    }
}

private final class FocusCatalogDurabilityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _failNextCatalogFlush = false
    private var _catalogFlushCount = 0

    var failNextCatalogFlush: Bool {
        get { lock.withLock { _failNextCatalogFlush } }
        set { lock.withLock { _failNextCatalogFlush = newValue } }
    }

    var catalogFlushCount: Int {
        lock.withLock { _catalogFlushCount }
    }

    func flush(_ url: URL) throws {
        let shouldFail = lock.withLock {
            guard url.lastPathComponent == WinkFocusSharedContract.catalogFileName else {
                return false
            }
            _catalogFlushCount += 1
            guard _failNextCatalogFlush else { return false }
            _failNextCatalogFlush = false
            return true
        }
        if shouldFail {
            throw FocusInjectedWriteFailure()
        }
    }
}

private final class FocusSharedStateWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingSuccessfulStateWritesBeforeFailure: Int?

    func failAfterSuccessfulStateWrites(_ count: Int) {
        lock.withLock {
            remainingSuccessfulStateWritesBeforeFailure = count
        }
    }

    func shouldFail(_ url: URL) -> Bool {
        lock.withLock {
            guard url.lastPathComponent == WinkFocusSharedContract.stateFileName,
                  let remaining = remainingSuccessfulStateWritesBeforeFailure else {
                return false
            }
            if remaining == 0 {
                remainingSuccessfulStateWritesBeforeFailure = nil
                return true
            }
            remainingSuccessfulStateWritesBeforeFailure = remaining - 1
            return false
        }
    }
}

@MainActor
private final class FocusReadinessState {
    var hasUnsavedWork: Bool

    init(hasUnsavedWork: Bool = false) {
        self.hasUnsavedWork = hasUnsavedWork
    }
}

private struct FocusFakePermissionService: PermissionServicing {
    func isTrusted() -> Bool { true }
    func isAccessibilityTrusted() -> Bool { true }
    func isInputMonitoringTrusted() -> Bool { true }
    @discardableResult
    func requestIfNeeded(prompt: Bool, inputMonitoringRequired: Bool) -> Bool { true }
}

@MainActor
private final class FocusFakeCaptureProvider: ShortcutCaptureProvider {
    var isRunning = false
    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(desiredShortcutCount: 0, registeredShortcutCount: 0, failures: [])
    }
    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) { isRunning = true }
    func stop() { isRunning = false }
    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {}
}

@MainActor
private final class FocusFakeHyperCaptureProvider: HyperShortcutCaptureProvider {
    var isRunning = false
    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(desiredShortcutCount: 0, registeredShortcutCount: 0, failures: [])
    }
    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) { isRunning = true }
    func stop() { isRunning = false }
    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {}
    func setHyperKeyEnabled(_ enabled: Bool) {}
    func setHyperReleaseDeferralSuppressed(_ suppressed: Bool) {}
}

@MainActor
private final class FocusFakeAppSwitcher: AppSwitching {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut, bypassCooldown: Bool) -> Bool { true }
    func invalidateWindowCycleSession(reason: String) {}
    func windowPickerSession(for shortcut: AppShortcut) -> WindowPickerSession? { nil }
    @discardableResult
    func focusPickedWindow(windowID: CGWindowID, session: WindowPickerSession) -> Bool { false }
}
