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
    func migrationCopiesBytesSoUnmodelledMembersSurvive() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        // `AppShortcut.CodingKeys` omits unknown members, so a migration that
        // decoded and re-encoded would necessarily drop this one — silently
        // discarding a newer build's data on the very first launch after an
        // upgrade-then-downgrade.
        let source = """
        [
          {
            "appName" : "Safari",
            "bundleIdentifier" : "com.apple.Safari",
            "futureField" : { "kind" : "something-new" },
            "id" : "33333333-3333-3333-3333-333333333333",
            "isEnabled" : true,
            "keyEquivalent" : "s",
            "modifierFlags" : [ "command" ]
          }
        ]
        """
        try harness.writeRawLegacyShortcuts(source)

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        let profileBytes = try #require(harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID)))
        #expect(profileBytes == Data(source.utf8))
        #expect(String(decoding: profileBytes, as: UTF8.self).contains("futureField"))
        #expect(loaded.activeShortcuts.count == 1)
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
    func anUnreadableLegacyFileIsReportedRatherThanShownAsAFreshInstall() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeRawLegacyShortcuts("{ not a shortcut array")

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // The store is healthy, but the user's previous configuration was
        // never consciously recovered or discarded — presenting this as an
        // ordinary empty install would hide that their shortcuts vanished.
        #expect(loaded.activeShortcuts.isEmpty)
        #expect(loaded.legacyMigrationFailure != nil)
        #expect(loaded.legacyMigrationFailure?.preservedCopyPath != nil)
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
    func anUnreadablePointerAndUnreadableDataStillArmNothing() throws {
        let (harness, profileID) = try migratedHarness()
        defer { harness.cleanup() }

        // Both stages damaged at once. Pointer resolution adopts the single
        // profile (nothing else it could have named), and the data stage then
        // reports it unreadable — the two stages compose, so no combination is
        // left undefined.
        try harness.writeRaw("{ truncated", to: harness.layout.activePointerURL)
        try harness.writeRaw("[ nope", to: harness.layout.profileDataURL(profileID))

        let store = harness.makeStore()
        guard case let .activeProfileUnreadable(profiles, activeProfileID, preservedCopyPath, _) = store.load() else {
            Issue.record("expected activeProfileUnreadable")
            return
        }

        #expect(profiles.count == 1)
        #expect(activeProfileID == profileID)
        #expect(preservedCopyPath != nil)
        #expect(store.locator.currentActiveProfileID() == nil)
        // Both damaged files are preserved, neither is replaced.
        #expect(harness.data(at: harness.layout.profileDataURL(profileID)) == Data("[ nope".utf8))
    }

    @Test
    func anUnsupportedPointerSchemaFailsClosedEvenWithASingleProfile() throws {
        let (harness, _) = try migratedHarness()
        defer { harness.cleanup() }

        // Well-formed, from a build this one does not understand. Unlike
        // truncation, that is a deliberate signal: a future schema may mean
        // more than "which of today's profiles", so adopting the single
        // profile could arm bindings that build left unarmed.
        try harness.writeRaw(
            #"{"schemaVersion": 99, "activeProfileID": "00000000-0000-0000-0000-000000000000"}"#,
            to: harness.layout.activePointerURL
        )

        let store = harness.makeStore()
        guard case let .activeProfileAmbiguous(profiles, preservedCopyPath) = store.load() else {
            Issue.record("expected activeProfileAmbiguous for an unsupported pointer schema")
            return
        }

        #expect(profiles.count == 1)
        #expect(preservedCopyPath != nil)
        #expect(store.locator.currentActiveProfileID() == nil)
        #expect(harness.diagnostics.values.contains { $0.contains("PROFILE_TRACE_ACTIVE_UNSUPPORTED_SCHEMA") })
    }

    @Test
    func anUnreadablePointerWithSeveralProfilesIsAmbiguousAndPreservesItsBytes() throws {
        let (harness, _) = try migratedHarness()
        defer { harness.cleanup() }

        let store = harness.makeStore()
        _ = store.load()
        try store.createProfile(named: "Work", duplicating: nil)
        try harness.writeRaw("{ truncated", to: harness.layout.activePointerURL)

        let reloaded = harness.makeStore()
        guard case let .activeProfileAmbiguous(profiles, preservedCopyPath) = reloaded.load() else {
            Issue.record("expected activeProfileAmbiguous")
            return
        }

        #expect(profiles.count == 2)
        #expect(preservedCopyPath != nil)
        #expect(reloaded.locator.currentActiveProfileID() == nil)
    }

    @Test
    func unreadableActiveProfileArmsNothingAndPreservesItsBytes() throws {
        let (harness, profileID) = try migratedHarness()
        defer { harness.cleanup() }

        try harness.writeRaw("[ nope", to: harness.layout.profileDataURL(profileID))

        let store = harness.makeStore()
        guard case let .activeProfileUnreadable(profiles, activeProfileID, preservedCopyPath, _) = store.load() else {
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
        guard case let .activeProfileUnreadable(_, _, preservedCopyPath, _) = store.load() else {
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
    func duplicationPreservesMembersTheModelDoesNotCarry() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        let source = """
        [
          {
            "appName" : "Safari",
            "bundleIdentifier" : "com.apple.Safari",
            "futureField" : { "kind" : "something-new" },
            "id" : "55555555-5555-5555-5555-555555555555",
            "isEnabled" : true,
            "keyEquivalent" : "s",
            "modifierFlags" : [ "command" ]
          }
        ]
        """
        try harness.writeRawLegacyShortcuts(source)

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        let copy = try store.createProfile(named: "Work", duplicating: loaded.activeProfileID)
        let copiedBytes = try #require(harness.data(at: harness.layout.profileDataURL(copy.id)))
        let copiedText = String(decoding: copiedBytes, as: UTF8.self)

        // Copied at the JSON level: the unmodelled member survives, and only
        // the id changed.
        #expect(copiedText.contains("futureField"))
        #expect(copiedText.contains("something-new"))
        #expect(!copiedText.contains("55555555-5555-5555-5555-555555555555"))

        let copied = try store.shortcuts(in: copy.id)
        #expect(copied.count == 1)
        #expect(copied[0].id != loaded.activeShortcuts[0].id)
        #expect(copied[0].appName == "Safari")
    }

    @Test
    func recoveryLeavesTheCompatMirrorDescribingTheNewProfile() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        _ = store.load()
        try harness.writeRaw("{ truncated", to: harness.layout.manifestURL)

        let reloaded = harness.makeStore()
        guard case .manifestUnreadable = reloaded.load() else {
            Issue.record("expected manifestUnreadable")
            return
        }
        let recovered = try reloaded.recoverManifest()

        // Without this the E2E harness and a downgraded build would keep
        // reading the pre-recovery bindings until some later save repaired it.
        #expect(
            harness.data(at: harness.layout.mirrorURL)
                == harness.data(at: harness.layout.profileDataURL(recovered.activeProfileID))
        )
    }

    @Test
    func recoveryPreservesTheCompatFileBeforeReplacingIt() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        _ = store.load()

        // Stage 1 stops on the damaged manifest, so the mirror classification
        // never runs — an older build's edits here have never been examined,
        // and Recover would otherwise replace the only copy of them.
        let downgradeEdit = "[ { \"appName\" : \"Mail\" } ]"
        try harness.writeRaw("{ truncated", to: harness.layout.manifestURL)
        try harness.writeRawLegacyShortcuts(downgradeEdit)

        let reloaded = harness.makeStore()
        guard case .manifestUnreadable = reloaded.load() else {
            Issue.record("expected manifestUnreadable")
            return
        }
        _ = try reloaded.recoverManifest()

        let copies = (try? FileManager.default.contentsOfDirectory(atPath: harness.directory.path))?
            .filter { $0.hasPrefix("shortcuts.unknown-") } ?? []
        #expect(copies.count == 1)
        let copyURL = harness.directory.appendingPathComponent(copies[0])
        #expect(harness.data(at: copyURL) == Data(downgradeEdit.utf8))
    }

    @Test
    func duplicationRefusesRatherThanSilentlyDroppingMembers() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // Remove the source file after load so the reshape cannot run. A
        // lossy fallback here would be the very data loss duplication was
        // fixed to avoid, so the operation refuses instead.
        try FileManager.default.removeItem(at: harness.layout.profileDataURL(loaded.activeProfileID))

        #expect(throws: (any Error).self) {
            _ = try store.createProfile(named: "Work", duplicating: loaded.activeProfileID)
        }
        // And it refused before writing anything.
        #expect(store.manifest?.profiles.count == 1)
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
    func aFailedManifestWriteDuringActiveDeletionRollsThePointerBack() throws {
        let (harness, store, loaded) = try readyStore()
        defer { harness.cleanup() }

        let second = try store.createProfile(named: "Second", duplicating: nil)

        // Commit the pointer, then fail the manifest. Left half-applied, the
        // runtime would keep serving the deleted profile while every save
        // landed in the successor's file and overwrote it.
        let manifestURL = harness.layout.manifestURL
        let failing = harness.makeStore(
            writeClient: ShortcutProfileStore.WriteClient { data, url in
                struct InjectedWriteFailure: Error {}
                guard url != manifestURL else { throw InjectedWriteFailure() }
                try data.write(to: url, options: .atomic)
            }
        )
        _ = failing.load()

        #expect(throws: (any Error).self) {
            _ = try failing.deleteProfile(loaded.activeProfileID)
        }

        // Total failure, not a half-applied switch.
        #expect(failing.locator.currentActiveProfileID() == loaded.activeProfileID)
        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }
        #expect(after.activeProfileID == loaded.activeProfileID)
        #expect(after.profiles.count == 2)
        #expect(second.id != after.activeProfileID)
    }

    @Test
    func aFailedRollbackAcceptsTheSwitchRatherThanClaimingItUndidIt() throws {
        let (harness, store, loaded) = try readyStore()
        defer { harness.cleanup() }

        let second = try store.createProfile(named: "Second", duplicating: nil)

        // A persistent storage failure: the manifest write AND the rollback
        // write both fail, which is the realistic shape of a full or
        // read-only volume.
        let manifestURL = harness.layout.manifestURL
        let pointerURL = harness.layout.activePointerURL
        // Counted across isolation domains: the write client is @Sendable.
        let pointerWrites = CallbackRecorder<Int>()
        let failing = harness.makeStore(
            writeClient: ShortcutProfileStore.WriteClient { data, url in
                struct InjectedWriteFailure: Error {}
                if url == manifestURL { throw InjectedWriteFailure() }
                if url == pointerURL {
                    pointerWrites.record(1)
                    // The first pointer write is the delete's own commit; the
                    // second is the rollback, which must also fail.
                    if pointerWrites.count > 1 { throw InjectedWriteFailure() }
                }
                try data.write(to: url, options: .atomic)
            }
        )
        _ = failing.load()

        let outcome = try failing.deleteProfile(loaded.activeProfileID)

        // Not a claimed total rollback: the durable pointer names the
        // successor, so memory says so too and the caller is told.
        #expect(outcome.unrecoverableSwitchReason != nil)
        #expect(outcome.newActiveProfileID == second.id)
        #expect(failing.locator.currentActiveProfileID() == second.id)
        #expect(harness.diagnostics.values.contains { $0.contains("PROFILE_TRACE_DELETE_ROLLBACK_FAILED") })
        // Nothing was deleted: the durable manifest still lists the profile,
        // so the in-memory list must not claim otherwise and the data file
        // must survive.
        #expect(outcome.profiles.contains { $0.id == loaded.activeProfileID })
        #expect(outcome.exclusivelyOwnedShortcutIDs.isEmpty)
        #expect(harness.profileDataFileIDs().contains(loaded.activeProfileID))
        // The switch stuck, so the compat file has to follow it rather than
        // describing bindings nothing is running.
        #expect(
            harness.data(at: harness.layout.mirrorURL)
                == harness.data(at: harness.layout.profileDataURL(second.id))
        )

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }
        // A relaunch agrees with what the user was told: switched, not deleted.
        #expect(after.activeProfileID == second.id)
        #expect(after.profiles.count == 2)
        #expect(after.unreadableProfileIDs.isEmpty)
    }

    @Test
    func ownershipFailsClosedWhenASiblingProfileCannotBeRead() throws {
        let (harness, store, loaded) = try readyStore()
        defer { harness.cleanup() }

        let work = try store.createProfile(named: "Work", duplicating: nil)
        try harness.writeRaw("[ nope", to: harness.layout.profileDataURL(work.id))

        let ownership = store.shortcutOwnership(excluding: loaded.activeProfileID)
        #expect(!ownership.isComplete)
        // An unreadable sibling could be holding any ID, so every question
        // answers "retained" rather than "absent".
        #expect(ownership.isRetainedElsewhere(loaded.activeShortcuts[0].id))
        #expect(ownership.isRetainedElsewhere(UUID()))
    }

    @Test
    func deletingAProfileKeepsUsageWhenASiblingIsUnreadable() throws {
        let (harness, store, loaded) = try readyStore()
        defer { harness.cleanup() }

        let work = try store.createProfile(named: "Work", duplicating: loaded.activeProfileID)
        let unreadable = try store.createProfile(named: "Archive", duplicating: nil)
        try harness.writeRaw("[ nope", to: harness.layout.profileDataURL(unreadable.id))

        let outcome = try store.deleteProfile(work.id)
        // Nothing is reported as exclusively owned while an unreadable profile
        // could still be holding those IDs.
        #expect(outcome.exclusivelyOwnedShortcutIDs.isEmpty)
    }

    @Test
    func adoptionInstallsTheOriginalBytesSoUnmodelledMembersSurvive() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // An older build wrote a file this build only partly models.
        let foreignBytes = """
        [
          {
            "appName" : "Mail",
            "bundleIdentifier" : "com.apple.mail",
            "futureField" : { "kind" : "something-new" },
            "id" : "44444444-4444-4444-4444-444444444444",
            "isEnabled" : true,
            "keyEquivalent" : "m",
            "modifierFlags" : [ "command" ]
          }
        ]
        """
        try harness.writeRawLegacyShortcuts(foreignBytes)

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load(), let mirror = after.foreignMirror else {
            Issue.record("expected a foreign mirror")
            return
        }

        _ = try reloaded.adoptForeignMirror(mirror)

        // Re-encoding would have dropped the member this import exists to
        // rescue.
        let installed = try #require(harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID)))
        #expect(installed == Data(foreignBytes.utf8))
        #expect(String(decoding: installed, as: UTF8.self).contains("futureField"))
    }

    @Test
    func aMirrorWithDuplicateShortcutIDsIsNotOfferedForImport() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // Valid JSON, invalid content: importing it would publish duplicate
        // rows and leave a file the strict loader quarantines next launch.
        try PersistenceService
            .encodeShortcuts(makeDuplicateShortcutIDFixture())
            .write(to: harness.layout.mirrorURL, options: .atomic)

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load(), let mirror = after.foreignMirror else {
            Issue.record("expected a foreign mirror")
            return
        }

        // Only the keep-and-overwrite side is offered.
        #expect(mirror.shortcuts == nil)
        #expect(throws: (any Error).self) {
            _ = try reloaded.adoptForeignMirror(mirror)
        }
    }

    @Test
    func adoptingAMirrorForAnInactiveProfileLeavesTheMirrorOnTheActiveOne() throws {
        let (harness, store, loaded) = try readyStore()
        defer { harness.cleanup() }

        let work = try store.createProfile(named: "Work", duplicating: nil)
        let foreign = [makeTestShortcut(appName: "Mail", bundleIdentifier: "com.apple.mail", keyEquivalent: "m")]

        let adopted = try store.adoptForeignMirror(
            ShortcutProfileStore.ForeignMirror(profileID: work.id, shortcuts: foreign)
        )

        // Nothing to apply — the import went into an inactive profile.
        #expect(adopted == nil)
        #expect(try store.shortcuts(in: work.id) == foreign)
        // And the compat file still describes the ACTIVE profile, so the E2E
        // harness and a downgraded build do not read the wrong bindings.
        #expect(
            harness.data(at: harness.layout.mirrorURL)
                == harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID))
        )
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
    func aSaveThatCrashedBeforeTheMirrorWriteIsRepairedSilently() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // An ordinary save to the SAME profile whose mirror write never lands.
        // The mirror and its descriptor still agree with each other, so only a
        // comparison against the live profile data can catch this.
        let mirrorURL = harness.layout.mirrorURL
        let descriptorURL = harness.layout.mirrorDescriptorURL
        let failing = harness.makeStore(
            writeClient: ShortcutProfileStore.WriteClient { data, url in
                struct InjectedWriteFailure: Error {}
                guard url != mirrorURL, url != descriptorURL else { throw InjectedWriteFailure() }
                try data.write(to: url, options: .atomic)
            }
        )
        _ = failing.load()
        let updated = [makeTestShortcut(appName: "Mail", bundleIdentifier: "com.apple.mail", keyEquivalent: "m")]
        try failing.makeActiveProfilePersistenceService().save(updated)

        // Precondition for the test to mean anything: the mirror really is
        // behind the profile now.
        #expect(
            harness.data(at: mirrorURL) != harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID))
        )

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // Repaired silently: no banner, and the file the E2E harness and a
        // downgraded build read now matches the live profile.
        #expect(after.foreignMirror == nil)
        #expect(after.activeShortcuts == updated)
        #expect(
            harness.data(at: mirrorURL)
                == harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID))
        )
        #expect(harness.diagnostics.values.contains { $0.contains("PROFILE_TRACE_MIRROR_STALE") })

        // Byte equality proves only that Wink wrote these bytes once, not
        // that it wrote them last — an older build restoring the exact
        // previous payload lands here too. The repair therefore preserves a
        // copy first, so the silent branch is non-destructive either way.
        let copies = (try? FileManager.default.contentsOfDirectory(atPath: harness.directory.path))?
            .filter { $0.hasPrefix("shortcuts.unknown-") } ?? []
        #expect(copies.count == 1)
    }

    @Test
    func unmodelledJSONMembersDoNotMakeAByteIdenticalMirrorLookStale() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        // A profile file carrying a member `AppShortcut` does not model — a
        // newer build wrote it, or a user hand-edited it. It decodes fine and
        // is dropped by a re-encode, so comparing the mirror against a model
        // round trip would call a perfect byte copy stale and then strip the
        // member from the file a downgrade reads.
        let withUnknownMember = """
        [
          {
            "appName" : "Safari",
            "bundleIdentifier" : "com.apple.Safari",
            "futureField" : { "kind" : "something-new" },
            "id" : "22222222-2222-2222-2222-222222222222",
            "isEnabled" : true,
            "keyEquivalent" : "s",
            "modifierFlags" : [ "command" ]
          }
        ]
        """
        try harness.writeRawLegacyShortcuts(withUnknownMember)

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // Migration copies bytes, so the profile file still carries the member.
        try harness.writeRaw(withUnknownMember, to: harness.layout.profileDataURL(loaded.activeProfileID))
        store.rewriteMirror(loaded.activeShortcuts, profileID: loaded.activeProfileID)

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }

        #expect(after.foreignMirror == nil)
        // The member survives in BOTH files: no spurious stale rewrite, and
        // the mirror a downgrade reads is still byte-identical to the profile.
        let mirrorBytes = try #require(harness.data(at: harness.layout.mirrorURL))
        let profileBytes = try #require(harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID)))
        #expect(mirrorBytes == profileBytes)
        #expect(String(decoding: mirrorBytes, as: UTF8.self).contains("futureField"))
        #expect(!harness.diagnostics.values.contains { $0.contains("PROFILE_TRACE_MIRROR_STALE") })
    }

    @Test
    func aMirrorOfUnknownProvenanceIsLeftStrictlyAlone() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        // Migration with an unreadable legacy file deliberately skips the
        // mirror write, so the user's bytes survive and no descriptor exists.
        let unreadable = "{ half a shortcuts file"
        try harness.writeRawLegacyShortcuts(unreadable)

        let store = harness.makeStore()
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // Not offered as a foreign edit (whose only available action would be
        // "overwrite", destroying data the user may still repair by hand), and
        // not silently rewritten either.
        #expect(after.foreignMirror == nil)
        #expect(harness.data(at: harness.layout.mirrorURL) == Data(unreadable.utf8))
        #expect(harness.diagnostics.values.contains { $0.contains("PROFILE_TRACE_MIRROR_UNKNOWN") })
    }

    @Test
    func aMirrorOneWriteBehindAsksRatherThanOverwriting() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // The reordering window D7 admits: `Data.write(.atomic)` renames
        // without an fsync, so the descriptor's rename can reach disk while
        // the mirror's does not. That is NOT the same as the mirror write
        // failing — a failure is reported and skips the descriptor, keeping
        // the two consistent. Simulate the real window by letting the mirror
        // write report success while writing nothing, so the descriptor
        // advances alone.
        let mirrorURL = harness.layout.mirrorURL
        let failing = harness.makeStore(
            writeClient: ShortcutProfileStore.WriteClient { data, url in
                guard url != mirrorURL else { return }
                try data.write(to: url, options: .atomic)
            }
        )
        _ = failing.load()
        try failing.makeActiveProfilePersistenceService().save(
            [makeTestShortcut(appName: "Mail", bundleIdentifier: "com.apple.mail", keyEquivalent: "m")]
        )

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // Deliberately NOT silently repaired. These bytes are indistinguishable
        // from a user or older build restoring the previous configuration on
        // purpose, so the classification asks instead of overwriting. The
        // banner names both causes.
        #expect(after.foreignMirror != nil)
        #expect(harness.data(at: mirrorURL) != nil)
    }

    @Test
    func importingTheResumableMirrorRestoresThePointerAndArmsTheProfile() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        let legacy = [makeTestShortcut()]
        try harness.writeLegacyShortcuts(legacy)

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // The interrupted-migration shape: metadata landed, data did not.
        try FileManager.default.removeItem(at: harness.layout.profileDataURL(loaded.activeProfileID))

        let reloaded = harness.makeStore()
        guard case let .activeProfileUnreadable(_, activeProfileID, _, importableMirror) = reloaded.load() else {
            Issue.record("expected activeProfileUnreadable")
            return
        }
        let mirror = try #require(importableMirror)
        #expect(reloaded.locator.currentActiveProfileID() == nil)

        let adopted = try reloaded.adoptForeignMirror(mirror)

        // The import repaired the profile, so recovery must finish here rather
        // than leaving zero armed shortcuts until the next relaunch.
        #expect(adopted == legacy)
        #expect(reloaded.locator.currentActiveProfileID() == activeProfileID)

        let third = harness.makeStore()
        guard case let .ready(after) = third.load() else {
            Issue.record("expected a ready load state")
            return
        }
        #expect(after.activeShortcuts == legacy)
        #expect(after.foreignMirror == nil)
    }

    @Test
    func aDescriptorNamingADeletedProfileIsUnknownProvenanceNotAForeignEdit() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let work = try store.createProfile(named: "Work", duplicating: nil)
        _ = try store.activateProfile(work.id)

        // Hand-write a descriptor naming a profile that no longer exists, then
        // change the mirror out of band. Offering "Import into <deleted>" has
        // no valid destination, and recreating it would resurrect what the
        // orphan policy refuses to adopt.
        _ = try store.deleteProfile(loaded.activeProfileID)
        try harness.writeRaw(
            "{\"schemaVersion\": 1, \"profileID\": \"\(loaded.activeProfileID.uuidString)\", \"sha256\": \"deadbeef\"}",
            to: harness.layout.mirrorDescriptorURL
        )
        try harness.writeLegacyShortcuts([makeTestShortcut(appName: "Mail")])

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }

        #expect(after.foreignMirror == nil)
        #expect(harness.diagnostics.values.contains { $0.contains("descriptor_profile_deleted") })
    }

    @Test
    func anUnattributableMirrorIsCopiedBeforeAnyLaterSaveCanOverwriteIt() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        let unreadable = "{ half a shortcuts file"
        try harness.writeRawLegacyShortcuts(unreadable)
        let store = harness.makeStore()
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        let reloaded = harness.makeStore()
        guard case .ready = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // "Left alone" only protects these bytes until the next save rewrites
        // the mirror. A copy makes every later overwrite non-destructive.
        let copies = (try? FileManager.default.contentsOfDirectory(atPath: harness.directory.path))?
            .filter { $0.hasPrefix("shortcuts.unknown-") } ?? []
        #expect(copies.count == 1)
        let copyURL = harness.directory.appendingPathComponent(copies[0])
        #expect(harness.data(at: copyURL) == Data(unreadable.utf8))
        #expect(harness.diagnostics.values.contains { $0.contains("PROFILE_TRACE_MIRROR_UNKNOWN_PRESERVED") })

        // Relaunching with the same bytes must not accumulate copies.
        let third = harness.makeStore()
        _ = third.load()
        let copiesAgain = (try? FileManager.default.contentsOfDirectory(atPath: harness.directory.path))?
            .filter { $0.hasPrefix("shortcuts.unknown-") } ?? []
        #expect(copiesAgain.count == 1)
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
    func duplicateNamingOfAMaximumLengthNameStillProducesAUsableName() {
        let longName = String(repeating: "x", count: ShortcutProfileNameRules.maximumLength)
        let existing = ShortcutProfile(name: longName, createdAt: Date(timeIntervalSince1970: 0))

        let name = ShortcutProfileNameRules.duplicateName(
            basedOn: longName,
            in: [existing],
            fallbackSuffix: UUID()
        )

        // Truncating the finished candidate would hand back the source name
        // itself, so the default Duplicate action could never succeed for a
        // maximum-length profile.
        #expect(name != longName)
        #expect(name.count <= ShortcutProfileNameRules.maximumLength)
        #expect(ShortcutProfileNameRules.violation(for: name, in: [existing]) == nil)
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
