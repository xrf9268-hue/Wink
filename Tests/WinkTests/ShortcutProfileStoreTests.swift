import Foundation
import Testing
@testable import Wink

// MARK: - Migration

@Suite("Shortcut profile migration")
@MainActor
struct ShortcutProfileMigrationTests {
    @Test
    func migratesLegacyShortcutsIntoDefaultProfileWithoutIDChurn() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        let legacy = [
            makeTestShortcut(appName: "Safari", bundleIdentifier: "com.apple.Safari", keyEquivalent: "s"),
            makeTestShortcut(appName: "Notes", bundleIdentifier: "com.apple.Notes", keyEquivalent: "n", isEnabled: false),
        ]
        try harness.writeLegacyShortcuts(legacy)

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        #expect(loaded.profiles.count == 1)
        // Ordered ID equality: a switch must never regenerate IDs, and neither
        // may the migration that creates the first profile.
        #expect(loaded.activeShortcuts.map(\.id) == legacy.map(\.id))
        #expect(loaded.activeShortcuts == legacy)
        #expect(loaded.activeProfileID == loaded.profiles[0].id)
    }

    @Test
    func migratedProfileFileReproducesTheSourceBytes() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        let legacy = [makeTestShortcut()]
        try harness.writeLegacyShortcuts(legacy)
        let sourceBytes = harness.data(at: harness.layout.mirrorURL)

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        let profileBytes = harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID))
        #expect(profileBytes == sourceBytes)
        // The mirror is rewritten from the same encoding path, so it stays
        // byte-identical too — the property the foreign-edit digest relies on.
        #expect(harness.data(at: harness.layout.mirrorURL) == sourceBytes)
    }

    @Test
    func freshInstallCreatesAnEmptyDefaultProfile() {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        #expect(loaded.activeShortcuts.isEmpty)
        #expect(loaded.profiles.count == 1)
        #expect(harness.fileExists(harness.layout.manifestURL))
        #expect(harness.fileExists(harness.layout.activePointerURL))
    }

    @Test
    func corruptLegacyFileYieldsAnEmptyProfileAndIsNeverOverwritten() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        let corrupt = "{ not a shortcut array"
        try harness.writeRawLegacyShortcuts(corrupt)

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        #expect(loaded.activeShortcuts.isEmpty)
        // The user's unreadable bytes survive: an empty Default profile must
        // not mirror itself over a file that may still be hand-repairable.
        #expect(harness.data(at: harness.layout.mirrorURL) == Data(corrupt.utf8))
        #expect(!harness.loadFailureCopies(in: harness.directory).isEmpty)
    }

    @Test
    func migrationIsSkippedOnceAManifestExists() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        try harness.writeLegacyShortcuts([makeTestShortcut()])
        let firstStore = harness.makeStore()
        guard case let .ready(first) = firstStore.load() else {
            Issue.record("expected a ready load state")
            return
        }

        let secondStore = harness.makeStore()
        guard case let .ready(second) = secondStore.load() else {
            Issue.record("expected a ready load state")
            return
        }

        #expect(second.profiles.map(\.id) == first.profiles.map(\.id))
        #expect(second.activeProfileID == first.activeProfileID)
    }
}

// MARK: - Recovery table (design record D8)

@Suite("Shortcut profile recovery table")
@MainActor
struct ShortcutProfileRecoveryTests {
    /// Builds a store that has already migrated one shortcut, then lets the
    /// caller corrupt the on-disk state before reloading.
    private func migratedHarness() throws -> (TestProfileHarness, UUID) {
        let harness = TestProfileHarness()
        try harness.writeLegacyShortcuts([makeTestShortcut()])
        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            throw TestFailure.unexpectedLoadState
        }
        return (harness, loaded.activeProfileID)
    }

    enum TestFailure: Error { case unexpectedLoadState }

    @Test
    func storageUnavailableWhenNoDirectoryResolves() {
        let store = ShortcutProfileStore(directoryProvider: { nil })
        #expect(store.load() == .storageUnavailable)
    }

    @Test
    func unreadableManifestQuarantinesAndArmsNothing() throws {
        let (harness, _) = try migratedHarness()
        defer { harness.cleanup() }

        try harness.writeRaw("{ truncated", to: harness.layout.manifestURL)

        let store = harness.makeStore()
        guard case let .manifestUnreadable(preservedCopyPath) = store.load() else {
            Issue.record("expected manifestUnreadable")
            return
        }

        #expect(preservedCopyPath != nil)
        // The source is preserved, never replaced.
        #expect(harness.data(at: harness.layout.manifestURL) == Data("{ truncated".utf8))
        #expect(!harness.loadFailureCopies(in: harness.layout.profilesDirectory).isEmpty)
        // Nothing may be written while quarantined.
        #expect(throws: ShortcutProfileStore.StoreError.manifestQuarantined) {
            try store.createProfile(named: "Work", duplicating: nil)
        }
    }

    @Test
    func manifestWithAHigherSchemaVersionIsRefusedRatherThanGuessedAt() throws {
        let (harness, _) = try migratedHarness()
        defer { harness.cleanup() }

        try harness.writeRaw(
            #"{"schemaVersion": 99, "profiles": []}"#,
            to: harness.layout.manifestURL
        )

        let store = harness.makeStore()
        guard case .manifestUnreadable = store.load() else {
            Issue.record("expected manifestUnreadable for an unsupported schema version")
            return
        }
    }

    @Test
    func missingPointerWithASingleProfileIsAdoptedNotGuessed() throws {
        let (harness, profileID) = try migratedHarness()
        defer { harness.cleanup() }

        try FileManager.default.removeItem(at: harness.layout.activePointerURL)

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        #expect(loaded.activeProfileID == profileID)
        #expect(harness.fileExists(harness.layout.activePointerURL))
    }

    @Test
    func missingPointerWithSeveralProfilesIsAmbiguousAndArmsNothing() throws {
        let (harness, _) = try migratedHarness()
        defer { harness.cleanup() }

        let store = harness.makeStore()
        _ = store.load()
        try store.createProfile(named: "Work", duplicating: nil)
        try FileManager.default.removeItem(at: harness.layout.activePointerURL)

        let reloaded = harness.makeStore()
        guard case let .activeProfileAmbiguous(profiles, _) = reloaded.load() else {
            Issue.record("expected activeProfileAmbiguous")
            return
        }

        #expect(profiles.count == 2)
        // Zero armed shortcuts: never auto-select a different configuration.
        #expect(reloaded.locator.currentActiveProfileID() == nil)
    }

    @Test
    func pointerNamingAnUnknownProfileNeverFallsThroughToAnother() throws {
        let (harness, _) = try migratedHarness()
        defer { harness.cleanup() }

        let store = harness.makeStore()
        _ = store.load()
        try store.createProfile(named: "Work", duplicating: nil)

        try harness.writeRaw(
            #"{"schemaVersion": 1, "activeProfileID": "00000000-0000-0000-0000-000000000000"}"#,
            to: harness.layout.activePointerURL
        )

        let reloaded = harness.makeStore()
        guard case .activeProfileAmbiguous = reloaded.load() else {
            Issue.record("expected activeProfileAmbiguous")
            return
        }
        #expect(reloaded.locator.currentActiveProfileID() == nil)
    }

    @Test
    func unreadableActiveProfileArmsNothingAndPreservesItsBytes() throws {
        let (harness, profileID) = try migratedHarness()
        defer { harness.cleanup() }

        try harness.writeRaw("[ nope", to: harness.layout.profileDataURL(profileID))

        let store = harness.makeStore()
        guard case let .activeProfileUnreadable(profiles, activeProfileID, preservedCopyPath) = store.load() else {
            Issue.record("expected activeProfileUnreadable")
            return
        }

        #expect(profiles.count == 1)
        #expect(activeProfileID == profileID)
        #expect(preservedCopyPath != nil)
        #expect(harness.data(at: harness.layout.profileDataURL(profileID)) == Data("[ nope".utf8))
        #expect(store.locator.currentActiveProfileID() == nil)
    }

    @Test
    func missingActiveProfileFileArmsNothing() throws {
        let (harness, profileID) = try migratedHarness()
        defer { harness.cleanup() }

        try FileManager.default.removeItem(at: harness.layout.profileDataURL(profileID))

        let store = harness.makeStore()
        guard case let .activeProfileUnreadable(_, _, preservedCopyPath) = store.load() else {
            Issue.record("expected activeProfileUnreadable")
            return
        }
        #expect(preservedCopyPath == nil)
        #expect(store.locator.currentActiveProfileID() == nil)
    }

    @Test
    func duplicateShortcutIDsInsideTheActiveProfileStayALoadFailure() throws {
        let (harness, profileID) = try migratedHarness()
        defer { harness.cleanup() }

        let duplicates = try PersistenceService.encodeShortcuts(makeDuplicateShortcutIDFixture())
        try duplicates.write(to: harness.layout.profileDataURL(profileID), options: .atomic)

        let store = harness.makeStore()
        guard case .activeProfileUnreadable = store.load() else {
            Issue.record("expected the existing duplicate-ID load failure to fire")
            return
        }
    }

    @Test
    func unreadableInactiveProfileIsReportedWithoutQuarantiningIt() throws {
        let (harness, _) = try migratedHarness()
        defer { harness.cleanup() }

        let store = harness.makeStore()
        _ = store.load()
        let work = try store.createProfile(named: "Work", duplicating: nil)
        try harness.writeRaw("[ nope", to: harness.layout.profileDataURL(work.id))

        let reloaded = harness.makeStore()
        guard case let .ready(loaded) = reloaded.load() else {
            Issue.record("expected a ready load state — an unreadable INACTIVE profile must not block startup")
            return
        }

        #expect(loaded.unreadableProfileIDs == [work.id])
        // Nothing is about to overwrite it, so no `.load-failure-` copy is
        // scattered for data nobody touched.
        #expect(harness.loadFailureCopies(in: harness.layout.profilesDirectory).isEmpty)
    }

    @Test
    func orphanDataFilesAreReportedAndNeverAdopted() throws {
        let (harness, _) = try migratedHarness()
        defer { harness.cleanup() }

        let orphanID = UUID()
        try harness.writeRaw("[]", to: harness.layout.profileDataURL(orphanID))

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        #expect(loaded.orphanProfileIDs == [orphanID])
        #expect(!loaded.profiles.contains { $0.id == orphanID })
        #expect(harness.diagnostics.values.contains { $0.contains("PROFILE_TRACE_ORPHAN") })
    }

    @Test
    func crossProfileDuplicateIDsAreReportedButNotFatal() throws {
        let (harness, activeID) = try migratedHarness()
        defer { harness.cleanup() }

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let sharedID = loaded.activeShortcuts[0].id
        let work = try store.createProfile(named: "Work", duplicating: nil)
        try PersistenceService
            .encodeShortcuts([makeTestShortcut(id: sharedID, appName: "Notes")])
            .write(to: harness.layout.profileDataURL(work.id), options: .atomic)

        let reloaded = harness.makeStore()
        guard case let .ready(second) = reloaded.load() else {
            Issue.record("expected a ready load state — a cross-profile duplicate is reported, not fatal")
            return
        }

        #expect(second.activeProfileID == activeID)
        #expect(second.duplicateShortcutIDs == [sharedID])
        #expect(harness.diagnostics.values.contains { $0.contains("PROFILE_TRACE_DUPLICATE_ID") })
    }

    @Test
    func recoverManifestPreservesTheBadFileBeforeReplacingIt() throws {
        let (harness, _) = try migratedHarness()
        defer { harness.cleanup() }

        try harness.writeRaw("{ truncated", to: harness.layout.manifestURL)
        let store = harness.makeStore()
        guard case .manifestUnreadable = store.load() else {
            Issue.record("expected manifestUnreadable")
            return
        }

        let recovered = try store.recoverManifest()
        #expect(recovered.profiles.count == 1)
        #expect(recovered.activeShortcuts.isEmpty)
        #expect(!harness.loadFailureCopies(in: harness.layout.profilesDirectory).isEmpty)

        // And the store is writable again.
        try store.createProfile(named: "Work", duplicating: nil)
        #expect(store.manifest?.profiles.count == 2)
    }
}

// MARK: - Crash points (design record V6)

@Suite("Shortcut profile crash points")
@MainActor
struct ShortcutProfileCrashPointTests {
    /// Fails writes whose destination matches `predicate`, so a test can stop
    /// at exactly one of the four write points without killing a process.
    private func failingWriteClient(
        when predicate: @escaping @Sendable (URL) -> Bool
    ) -> ShortcutProfileStore.WriteClient {
        ShortcutProfileStore.WriteClient { data, url in
            struct InjectedWriteFailure: Error {}
            guard !predicate(url) else { throw InjectedWriteFailure() }
            try data.write(to: url, options: .atomic)
        }
    }

    @Test
    func aFailedPointerCommitLeavesTheSwitchUnapplied() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let work = try store.createProfile(named: "Work", duplicating: nil)

        let pointerURL = harness.layout.activePointerURL
        let failing = harness.makeStore(
            writeClient: failingWriteClient { $0 == pointerURL }
        )
        _ = failing.load()

        #expect(throws: (any Error).self) {
            _ = try failing.activateProfile(work.id)
        }
        // Nothing moved: the commit point is the only thing that decides.
        #expect(failing.locator.currentActiveProfileID() == loaded.activeProfileID)

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }
        #expect(after.activeProfileID == loaded.activeProfileID)
    }

    @Test
    func aFailedMirrorWriteNeverFailsTheSwitch() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        _ = store.load()
        let work = try store.createProfile(named: "Work", duplicating: nil)

        let mirrorURL = harness.layout.mirrorURL
        let failing = harness.makeStore(writeClient: failingWriteClient { $0 == mirrorURL })
        _ = failing.load()

        let shortcuts = try failing.activateProfile(work.id)
        #expect(shortcuts.isEmpty)
        #expect(failing.locator.currentActiveProfileID() == work.id)
        #expect(harness.diagnostics.values.contains { $0.contains("PROFILE_TRACE_MIRROR_FAILED") })
    }

    @Test
    func aFailedManifestWriteDuringCreateLeavesAnOrphanNotADanglingEntry() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let manifestURL = harness.layout.manifestURL
        let store = harness.makeStore()
        _ = store.load()

        let failing = harness.makeStore(writeClient: failingWriteClient { $0 == manifestURL })
        _ = failing.load()

        #expect(throws: (any Error).self) {
            _ = try failing.createProfile(named: "Work", duplicating: nil)
        }

        let reloaded = harness.makeStore()
        guard case let .ready(loaded) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }
        #expect(loaded.profiles.count == 1)
        // A data file with no manifest entry — reported, never auto-imported.
        #expect(loaded.orphanProfileIDs.count == 1)
    }
}

// MARK: - CRUD

@Suite("Shortcut profile CRUD")
@MainActor
struct ShortcutProfileCRUDTests {
    private func readyStore() throws -> (TestProfileHarness, ShortcutProfileStore, ShortcutProfileStore.LoadedProfiles) {
        let harness = TestProfileHarness()
        try harness.writeLegacyShortcuts([
            makeTestShortcut(appName: "Safari", bundleIdentifier: "com.apple.Safari", keyEquivalent: "s"),
            makeTestShortcut(appName: "Notes", bundleIdentifier: "com.apple.Notes", keyEquivalent: "n"),
        ])
        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            throw ShortcutProfileRecoveryTests.TestFailure.unexpectedLoadState
        }
        return (harness, store, loaded)
    }

    @Test
    func duplicationMintsFreshShortcutIDsAndCopiesEverythingElse() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        let source = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"],
            isEnabled: false,
            frontmostBehaviorOverride: .focus,
            target: .app,
            holdAction: .windowPicker
        )
        try harness.writeLegacyShortcuts([source])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        let copy = try store.createProfile(named: "Work", duplicating: loaded.activeProfileID)
        let copied = try store.shortcuts(in: copy.id)

        #expect(copied.count == 1)
        #expect(copied[0].id != source.id)
        #expect(copied[0].appName == source.appName)
        #expect(copied[0].bundleIdentifier == source.bundleIdentifier)
        #expect(copied[0].keyEquivalent == source.keyEquivalent)
        #expect(copied[0].modifierFlags == source.modifierFlags)
        #expect(copied[0].isEnabled == source.isEnabled)
        #expect(copied[0].frontmostBehaviorOverride == source.frontmostBehaviorOverride)
        #expect(copied[0].target == source.target)
        #expect(copied[0].holdAction == source.holdAction)
    }

    @Test
    func duplicationCarriesThePreservedInvalidTargetGate() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        // A row written by a newer build whose `target` this build does not
        // know. Dropping the gate on copy would let the absent-key backfill
        // re-arm it (#404).
        try harness.writeRawLegacyShortcuts("""
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "appName": "Future",
            "bundleIdentifier": "wink.target.future",
            "keyEquivalent": "f",
            "modifierFlags": ["command"],
            "isEnabled": true,
            "target": "someFutureKind"
          }
        ]
        """)

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        #expect(loaded.activeShortcuts[0].exportedInvalidTargetRawValue == "someFutureKind")

        let copy = try store.createProfile(named: "Work", duplicating: loaded.activeProfileID)
        let copied = try store.shortcuts(in: copy.id)
        #expect(copied[0].exportedInvalidTargetRawValue == "someFutureKind")
        #expect(copied[0].hasPersistedInvalidTarget)
    }

    @Test
    func nameRulesRejectEmptyTooLongAndCaseInsensitiveDuplicates() throws {
        let (harness, store, _) = try readyStore()
        defer { harness.cleanup() }

        try store.createProfile(named: "Work", duplicating: nil)

        #expect(throws: ShortcutProfileStore.StoreError.nameRejected(.empty)) {
            try store.createProfile(named: "   ", duplicating: nil)
        }
        #expect(throws: ShortcutProfileStore.StoreError.nameRejected(.tooLong(limit: 64))) {
            try store.createProfile(named: String(repeating: "x", count: 65), duplicating: nil)
        }
        // Case-insensitive, canonical-composition-aware comparison.
        do {
            _ = try store.createProfile(named: "wORK", duplicating: nil)
            Issue.record("expected a case-insensitive duplicate name to be rejected")
        } catch let error as ShortcutProfileStore.StoreError {
            guard case let .nameRejected(violation) = error, case .duplicate = violation else {
                Issue.record("expected a duplicate-name violation, got \(error)")
                return
            }
        }
    }

    @Test
    func renameIsMetadataOnlyAndLeavesShortcutIDsUntouched() throws {
        let (harness, store, loaded) = try readyStore()
        defer { harness.cleanup() }

        let before = harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID))
        _ = try store.renameProfile(loaded.activeProfileID, to: "Personal")
        let after = harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID))

        #expect(before == after)
        #expect(store.manifest?.profile(id: loaded.activeProfileID)?.name == "Personal")
    }

    @Test
    func theProfileCapIsEnforced() throws {
        let (harness, store, _) = try readyStore()
        defer { harness.cleanup() }

        for index in 2...ShortcutProfileManifest.maximumProfileCount {
            try store.createProfile(named: "Profile \(index)", duplicating: nil)
        }

        #expect(
            throws: ShortcutProfileStore.StoreError.profileLimitReached(
                limit: ShortcutProfileManifest.maximumProfileCount
            )
        ) {
            try store.createProfile(named: "One too many", duplicating: nil)
        }
    }

    @Test
    func theLastProfileCannotBeDeleted() throws {
        let (harness, store, loaded) = try readyStore()
        defer { harness.cleanup() }

        #expect(throws: ShortcutProfileStore.StoreError.cannotDeleteLastProfile) {
            _ = try store.deleteProfile(loaded.activeProfileID)
        }
    }

    @Test
    func deletingTheActiveProfileFallsBackDeterministically() throws {
        let (harness, store, loaded) = try readyStore()
        defer { harness.cleanup() }

        let second = try store.createProfile(named: "Second", duplicating: nil)
        let third = try store.createProfile(named: "Third", duplicating: nil)

        // Deleting the FIRST entry falls forward to the new first entry.
        let outcome = try store.deleteProfile(loaded.activeProfileID)
        #expect(outcome.newActiveProfileID == second.id)

        // Deleting a middle/last entry falls back to the preceding one.
        _ = try store.activateProfile(third.id)
        let secondOutcome = try store.deleteProfile(third.id)
        #expect(secondOutcome.newActiveProfileID == second.id)
    }

    @Test
    func deletingAProfileOnlyReportsShortcutIDsItExclusivelyOwns() throws {
        let (harness, store, loaded) = try readyStore()
        defer { harness.cleanup() }

        let shared = loaded.activeShortcuts[0]
        let work = try store.createProfile(named: "Work", duplicating: nil)
        // Hand-place a row that shares an ID with the active profile.
        try PersistenceService
            .encodeShortcuts([shared, makeTestShortcut(appName: "Mail")])
            .write(to: harness.layout.profileDataURL(work.id), options: .atomic)

        let outcome = try store.deleteProfile(work.id)
        #expect(!outcome.exclusivelyOwnedShortcutIDs.contains(shared.id))
        #expect(outcome.exclusivelyOwnedShortcutIDs.count == 1)
    }

    @Test
    func deletingAProfileRemovesItsDataFile() throws {
        let (harness, store, _) = try readyStore()
        defer { harness.cleanup() }

        let work = try store.createProfile(named: "Work", duplicating: nil)
        #expect(harness.profileDataFileIDs().contains(work.id))

        _ = try store.deleteProfile(work.id)
        #expect(!harness.profileDataFileIDs().contains(work.id))
    }

    @Test
    func activatingAProfileCommitsThePointerAndRewritesTheMirror() throws {
        let (harness, store, loaded) = try readyStore()
        defer { harness.cleanup() }

        let work = try store.createProfile(named: "Work", duplicating: loaded.activeProfileID)
        let switched = try store.activateProfile(work.id)

        #expect(switched.count == loaded.activeShortcuts.count)
        #expect(store.locator.currentActiveProfileID() == work.id)
        #expect(
            harness.data(at: harness.layout.mirrorURL)
                == harness.data(at: harness.layout.profileDataURL(work.id))
        )

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }
        #expect(after.activeProfileID == work.id)
        #expect(after.foreignMirror == nil)
    }
}

// MARK: - Mirror and foreign edits

@Suite("Shortcut profile mirror")
@MainActor
struct ShortcutProfileMirrorTests {
    @Test
    func savingThroughTheActiveProfileServiceKeepsTheMirrorByteIdentical() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        let persistence = store.makeActiveProfilePersistenceService()
        let updated = [makeTestShortcut(appName: "Mail", bundleIdentifier: "com.apple.mail", keyEquivalent: "m")]
        try persistence.save(updated)

        let profileBytes = harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID))
        #expect(harness.data(at: harness.layout.mirrorURL) == profileBytes)

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }
        #expect(after.foreignMirror == nil)
        #expect(after.activeShortcuts == updated)
    }

    @Test
    func anExternallyRewrittenMirrorIsReportedAndNothingIsChangedUntilAChoiceIsMade() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let profileBytesBefore = harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID))

        // What an older build does: rewrite shortcuts.json directly.
        let foreign = [makeTestShortcut(appName: "Mail", bundleIdentifier: "com.apple.mail", keyEquivalent: "m")]
        try harness.writeLegacyShortcuts(foreign)

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }

        #expect(after.foreignMirror?.profileID == loaded.activeProfileID)
        #expect(after.foreignMirror?.shortcuts == foreign)
        // The profile still holds its own data; the runtime is unchanged.
        #expect(after.activeShortcuts == loaded.activeShortcuts)
        #expect(harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID)) == profileBytesBefore)
        #expect(harness.diagnostics.values.contains { $0.contains("PROFILE_TRACE_FOREIGN_MIRROR") })
    }

    @Test
    func adoptingAForeignMirrorWritesItIntoTheProfileTheMirrorDescribed() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        _ = store.load()
        let foreign = [makeTestShortcut(appName: "Mail", bundleIdentifier: "com.apple.mail", keyEquivalent: "m")]
        try harness.writeLegacyShortcuts(foreign)

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load(), let mirror = after.foreignMirror else {
            Issue.record("expected a foreign mirror")
            return
        }

        let adopted = try reloaded.adoptForeignMirror(mirror)
        #expect(adopted == foreign)

        // The adoption is durable and the descriptor now matches, so the next
        // launch sees no foreign edit.
        let third = harness.makeStore()
        guard case let .ready(final) = third.load() else {
            Issue.record("expected a ready load state")
            return
        }
        #expect(final.activeShortcuts == foreign)
        #expect(final.foreignMirror == nil)
    }

    @Test
    func discardingAForeignMirrorRewritesTheFileAndKeepsTheProfile() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        let original = [makeTestShortcut()]
        try harness.writeLegacyShortcuts(original)

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        try harness.writeLegacyShortcuts([makeTestShortcut(appName: "Mail")])

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load(), after.foreignMirror != nil else {
            Issue.record("expected a foreign mirror")
            return
        }

        reloaded.discardForeignMirror(activeShortcuts: after.activeShortcuts)

        let third = harness.makeStore()
        guard case let .ready(final) = third.load() else {
            Issue.record("expected a ready load state")
            return
        }
        #expect(final.foreignMirror == nil)
        #expect(final.activeShortcuts == loaded.activeShortcuts)
        #expect(final.activeShortcuts == original)
    }

    @Test
    func aMissingDescriptorIsRebuiltRatherThanTreatedAsForeign() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        _ = store.load()
        try FileManager.default.removeItem(at: harness.layout.mirrorDescriptorURL)

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }
        #expect(after.foreignMirror == nil)
        #expect(harness.fileExists(harness.layout.mirrorDescriptorURL))
    }
}

// MARK: - Name rules

@Suite("Shortcut profile name rules")
struct ShortcutProfileNameRuleTests {
    private func profile(_ name: String) -> ShortcutProfile {
        ShortcutProfile(name: name, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test
    func trimmingAndEmptinessAreRejectedBeforeLength() {
        #expect(ShortcutProfileNameRules.violation(for: "  \n ", in: []) == .empty)
    }

    @Test
    func comparisonIsCanonicalAndLocaleIndependent() {
        let existing = profile("Café")
        // "Cafe" + combining acute — the same name to a reader.
        let decomposed = "Cafe\u{0301}"
        #expect(ShortcutProfileNameRules.comparisonKey(decomposed) == ShortcutProfileNameRules.comparisonKey("café"))
        guard case .duplicate? = ShortcutProfileNameRules.violation(for: decomposed, in: [existing]) else {
            Issue.record("expected a duplicate violation for a canonically equal name")
            return
        }
    }

    @Test
    func renamingAProfileToItsOwnNameIsAllowed() {
        let existing = profile("Work")
        #expect(ShortcutProfileNameRules.violation(for: "Work", excluding: existing.id, in: [existing]) == nil)
    }

    @Test
    func duplicateNamingSkipsTakenSpellings() {
        let taken = [profile("Work"), profile("Work copy")]
        let name = ShortcutProfileNameRules.duplicateName(
            basedOn: "Work",
            in: taken,
            fallbackSuffix: UUID()
        )
        #expect(ShortcutProfileNameRules.violation(for: name, in: taken) == nil)
    }
}
