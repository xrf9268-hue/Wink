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
    func duplicationPreservesEveryMemberExceptTheShortcutIDs() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        // Members this build does not model, plus ones it does. Asserting on
        // the modeled fields alone would pass for an implementation that
        // decoded and re-encoded, which is exactly the loss duplication has to
        // avoid.
        let sourceJSON = """
        [
          {
            "id" : "55555555-5555-5555-5555-555555555555",
            "appName" : "Safari",
            "bundleIdentifier" : "com.apple.Safari",
            "keyEquivalent" : "s",
            "modifierFlags" : [ "command", "option" ],
            "isEnabled" : false,
            "futureMemberFromANewerBuild" : { "nested" : [ 1, 2, 3 ] },
            "anotherUnknownMember" : "kept"
          }
        ]
        """
        try harness.writeRawLegacyShortcuts(sourceJSON)

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let copy = try store.createProfile(named: "Work", duplicating: loaded.activeProfileID)

        guard
            let sourceData = harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID)),
            let copyData = harness.data(at: harness.layout.profileDataURL(copy.id)),
            let sourceRows = (try? JSONSerialization.jsonObject(with: sourceData)) as? [[String: Any]],
            let copyRows = (try? JSONSerialization.jsonObject(with: copyData)) as? [[String: Any]]
        else {
            Issue.record("expected both payloads to be readable JSON arrays")
            return
        }

        #expect(sourceRows.count == copyRows.count)
        for (sourceRow, copyRow) in zip(sourceRows, copyRows) {
            #expect(sourceRow["id"] as? String != copyRow["id"] as? String)
            // Every OTHER member, compared as JSON rather than through the
            // model, so an unmodeled member that silently vanished fails here.
            var expected = sourceRow
            var actual = copyRow
            expected.removeValue(forKey: "id")
            actual.removeValue(forKey: "id")
            #expect(NSDictionary(dictionary: expected) == NSDictionary(dictionary: actual))
        }
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
    func modifiedAtIsAMetadataTimestampContentSavesNeverTouchIt() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let clock = MutableBox(Date(timeIntervalSince1970: 1_770_000_000))
        let store = harness.makeStore(dateProvider: { clock.value })
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let before = try #require(store.manifest?.profile(id: loaded.activeProfileID)).modifiedAt

        // A content save's write order is data → mirror → descriptor, with no
        // manifest write (D2/D3): modifiedAt tracks metadata edits, and a save
        // that bumped it would put the profile list on every save's failure
        // path for a value nothing reads.
        clock.value += 100
        let persistence = store.makeActiveProfilePersistenceService()
        try persistence.save([makeTestShortcut(appName: "Mail", bundleIdentifier: "com.apple.mail", keyEquivalent: "m")])
        #expect(store.manifest?.profile(id: loaded.activeProfileID)?.modifiedAt == before)

        // A rename's primary effect is already a manifest commit; modifiedAt
        // rides that commit, adding no write of its own.
        clock.value += 100
        _ = try store.renameProfile(loaded.activeProfileID, to: "Personal")
        #expect(store.manifest?.profile(id: loaded.activeProfileID)?.modifiedAt == clock.value)
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
    func adoptingAMirrorRejectsShortcutIDsHeldBySiblingProfiles() throws {
        let sharedID = UUID()
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut(id: sharedID)])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let work = try store.createProfile(named: "Work", duplicating: nil)
        _ = try store.activateProfile(work.id)

        // Uniqueness inside the payload is not enough: global uniqueness
        // across profiles is what lets usage.db skip a profile column, and an
        // import is the one path that can violate it.
        let foreign = [makeTestShortcut(id: sharedID, appName: "Mail", bundleIdentifier: "com.apple.mail", keyEquivalent: "m")]
        #expect(throws: (any Error).self) {
            _ = try store.adoptForeignMirror(
                ShortcutProfileStore.ForeignMirror(
                    profileID: work.id,
                    shortcuts: foreign,
                    rawBytes: try PersistenceService.encodeShortcuts(foreign)
                )
            )
        }
        #expect(try store.shortcuts(in: loaded.activeProfileID).map(\.id) == [sharedID])
        #expect(try store.shortcuts(in: work.id).isEmpty)
    }

    @Test
    func recoveryRefusesWhenTheManifestCannotEvenBeReadForBackup() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])
        _ = harness.makeStore().load()

        // Present but unreadable is the dangerous shape: the directory can
        // still accept an atomic replacement, so a guard that only runs when
        // the read succeeds would replace a file it never captured.
        try harness.writeRaw("{ broken", to: harness.layout.manifestURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: harness.layout.manifestURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: harness.layout.manifestURL.path
            )
        }

        let store = harness.makeStore()
        guard case .manifestUnreadable = store.load() else {
            Issue.record("expected manifestUnreadable")
            return
        }
        #expect(throws: (any Error).self) {
            _ = try store.recoverManifest()
        }
    }

    @Test
    func aManifestWithEmptyOrCollidingNamesIsALoadFailure() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])
        _ = harness.makeStore().load()

        // Both break every surface that addresses a profile by the name the
        // user reads, so they are load failures exactly like a duplicate id.
        try harness.writeRaw(
            """
            {"schemaVersion": 1, "profiles": [
              {"id": "11111111-1111-1111-1111-111111111111", "name": "Work",
               "createdAt": "2026-08-10T00:00:00Z", "modifiedAt": "2026-08-10T00:00:00Z"},
              {"id": "22222222-2222-2222-2222-222222222222", "name": "work",
               "createdAt": "2026-08-10T00:00:00Z", "modifiedAt": "2026-08-10T00:00:00Z"}
            ]}
            """,
            to: harness.layout.manifestURL
        )
        guard case .manifestUnreadable = harness.makeStore().load() else {
            Issue.record("expected a colliding-name manifest to be a load failure")
            return
        }

        try harness.writeRaw(
            """
            {"schemaVersion": 1, "profiles": [
              {"id": "33333333-3333-3333-3333-333333333333", "name": "   ",
               "createdAt": "2026-08-10T00:00:00Z", "modifiedAt": "2026-08-10T00:00:00Z"}
            ]}
            """,
            to: harness.layout.manifestURL
        )
        guard case .manifestUnreadable = harness.makeStore().load() else {
            Issue.record("expected an empty-name manifest to be a load failure")
            return
        }
    }

    @Test
    func discardReportsFailureWhenTheFileCouldNotBeRewritten() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let mirrorURL = harness.layout.mirrorURL
        let store = harness.makeStore(
            writeClient: ShortcutProfileStore.WriteClient { data, url in
                struct InjectedWriteFailure: Error {}
                if url == mirrorURL { throw InjectedWriteFailure() }
                try data.write(to: url, options: .atomic)
            }
        )
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // Reporting success here would clear the banner and leave the user
        // believing they kept their profile while the file says otherwise.
        #expect(store.discardForeignMirror(activeShortcuts: loaded.activeShortcuts) == false)
    }

    @Test
    func recoveryRefusesToReplaceAManifestItCannotPreserve() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])
        _ = harness.makeStore().load()

        let corrupt = Data("{ broken-manifest".utf8)
        try corrupt.write(to: harness.layout.manifestURL, options: .atomic)

        let store = harness.makeStore(
            writeClient: ShortcutProfileStore.WriteClient { data, url in
                struct InjectedWriteFailure: Error {}
                if url.lastPathComponent.contains(".load-failure-") { throw InjectedWriteFailure() }
                try data.write(to: url, options: .atomic)
            }
        )
        guard case .manifestUnreadable = store.load() else {
            Issue.record("expected manifestUnreadable")
            return
        }

        // The banner promises the unreadable file was kept. If it cannot be,
        // recovery must not proceed rather than replace it and claim it did.
        #expect(throws: (any Error).self) {
            _ = try store.recoverManifest()
        }
        #expect(harness.data(at: harness.layout.manifestURL) == corrupt)
    }

    @Test
    func aDeletedProfilesUsageIdsSurviveACrashInTheJournal() throws {
        let (harness, store, loaded) = try readyStore()
        defer { harness.cleanup() }

        let work = try store.createProfile(named: "Work", duplicating: loaded.activeProfileID)
        let workIDs = try store.shortcuts(in: work.id).map(\.id)
        _ = try store.deleteProfile(work.id)

        // Recorded in the same commit as the removal: by the time the profile
        // is gone, the inventory needed to recompute exclusivity is gone too,
        // so a fire-and-forget task could not be retried.
        #expect(Set(store.pendingUsageDeletions()) == Set(workIDs))

        let reloaded = harness.makeStore()
        _ = reloaded.load()
        #expect(Set(reloaded.pendingUsageDeletions()) == Set(workIDs))

        reloaded.clearPendingUsageDeletions(workIDs)
        #expect(reloaded.pendingUsageDeletions().isEmpty)
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
        // The original bytes travel with the payload; the import installs those
        // rather than a re-encoding, so an unmodelled member would survive.
        let foreignBytes = try PersistenceService.encodeShortcuts(foreign)
        // The edit sits in the compat file itself — the only state production
        // can produce, since every offer captures its bytes FROM that file.
        // Adoption re-reads the file and refuses an offer whose bytes drifted.
        try foreignBytes.write(to: harness.layout.mirrorURL)

        let adopted = try store.adoptForeignMirror(
            ShortcutProfileStore.ForeignMirror(profileID: work.id, shortcuts: foreign, rawBytes: foreignBytes)
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
    func aMissingDataFileIsNotTreatedAsAnEmptyProfile() throws {
        let (harness, store, loaded) = try readyStore()
        defer { harness.cleanup() }

        let work = try store.createProfile(named: "Work", duplicating: nil)
        try FileManager.default.removeItem(at: harness.layout.profileDataURL(work.id))

        // `PersistenceService.load()` returns [] for a file that does not
        // exist, which is right on a first launch and wrong here: a missing
        // profile must not read as an empty one, or "validate before commit"
        // commits a pointer to a profile that is gone.
        #expect(throws: (any Error).self) {
            _ = try store.shortcuts(in: work.id)
        }
        #expect(throws: (any Error).self) {
            _ = try store.activateProfile(work.id)
        }
        #expect(store.locator.currentActiveProfileID() == loaded.activeProfileID)
    }

    @Test
    func deletingAnUnreadableActiveProfileStillCommitsASuccessor() throws {
        let (harness, store, loaded) = try readyStore()
        defer { harness.cleanup() }

        let second = try store.createProfile(named: "Second", duplicating: nil)
        try harness.writeRaw("[ nope", to: harness.layout.profileDataURL(loaded.activeProfileID))

        let reloaded = harness.makeStore()
        guard case .activeProfileUnreadable = reloaded.load() else {
            Issue.record("expected activeProfileUnreadable")
            return
        }
        // The locator is intentionally empty — there is nowhere safe to save
        // — but the durable pointer still names this profile, so deleting it
        // must commit a successor rather than leave a dangling pointer.
        #expect(reloaded.locator.currentActiveProfileID() == nil)

        let outcome = try reloaded.deleteProfile(loaded.activeProfileID)
        #expect(outcome.newActiveProfileID == second.id)

        let third = harness.makeStore()
        guard case let .ready(after) = third.load() else {
            Issue.record("expected a ready load state — a dangling pointer would be ambiguous recovery")
            return
        }
        #expect(after.activeProfileID == second.id)
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
    func adoptionRefusesWhenTheFileChangedAgainAfterTheOffer() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        _ = store.load()
        let firstEdit = [makeTestShortcut(appName: "Mail", bundleIdentifier: "com.apple.mail", keyEquivalent: "m")]
        try harness.writeLegacyShortcuts(firstEdit)

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load(), let mirror = after.foreignMirror else {
            Issue.record("expected a foreign mirror")
            return
        }

        // The other writer runs AGAIN between the offer and the user's click.
        // Adopting the captured bytes now would roll the file back to the
        // first edit and, on the mirror write, overwrite the second edit's
        // only copy.
        let secondEdit = [makeTestShortcut(appName: "Notes", bundleIdentifier: "com.apple.notes", keyEquivalent: "n")]
        try harness.writeLegacyShortcuts(secondEdit)
        let mirrorBytesBefore = harness.data(at: harness.layout.mirrorURL)
        let profileBytesBefore = harness.data(at: harness.layout.profileDataURL(after.activeProfileID))

        #expect(throws: ShortcutProfileStore.StoreError.foreignMirrorChangedSinceOffer) {
            try reloaded.adoptForeignMirror(mirror)
        }
        // Refused means refused: the newer edit still sits in the file and
        // the profile was not rolled back to the captured bytes.
        #expect(harness.data(at: harness.layout.mirrorURL) == mirrorBytesBefore)
        #expect(harness.data(at: harness.layout.profileDataURL(after.activeProfileID)) == profileBytesBefore)

        // The refreshed offer targets the same profile with the newest bytes,
        // and adopting IT succeeds — refusal is a redirect, not a dead end.
        let refreshed = try #require(reloaded.refreshedForeignMirrorOffer(replacing: mirror))
        #expect(refreshed.profileID == mirror.profileID)
        #expect(refreshed.shortcuts == secondEdit)
        let adopted = try reloaded.adoptForeignMirror(refreshed)
        #expect(adopted == secondEdit)
    }

    @Test
    func adoptionProceedsWhenTheFileVanishedAfterTheOffer() throws {
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

        // A vanished file is NOT drift: there is nothing on disk this import
        // can destroy, and in the interrupted-migration recovery the captured
        // bytes can be the last copy anywhere — refusing here would block the
        // only recovery the user has.
        try FileManager.default.removeItem(at: harness.layout.mirrorURL)

        let adopted = try reloaded.adoptForeignMirror(mirror)
        #expect(adopted == foreign)
        #expect(harness.data(at: harness.layout.mirrorURL) == mirror.rawBytes)
    }

    @Test
    func aSecondProfileIsRefusedWhileNoDurablePointerExists() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let first = harness.makeStore()
        _ = first.load()
        try FileManager.default.removeItem(at: harness.layout.activePointerURL)

        // The pointer repair cannot be written. The single profile still
        // arms — refusing to run over a pointer write would be worse than a
        // transient full disk deserves — but a second profile would make the
        // next launch ambiguous, so it is refused until the pointer exists.
        let pointerURL = harness.layout.activePointerURL
        let failing = harness.makeStore(
            writeClient: ShortcutProfileStore.WriteClient { data, url in
                struct InjectedWriteFailure: Error {}
                guard url != pointerURL else { throw InjectedWriteFailure() }
                try data.write(to: url, options: .atomic)
            }
        )
        guard case let .ready(loaded) = failing.load() else {
            Issue.record("expected the sole profile to stay armed")
            return
        }
        #expect(!loaded.activeShortcuts.isEmpty)

        #expect(throws: (any Error).self) {
            _ = try failing.createProfile(named: "Work", duplicating: nil)
        }
        #expect(failing.manifest?.profiles.count == 1)
    }

    @Test
    func discardIsRefusedWhileTheOnlyProfileIsStillUnusable() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        try FileManager.default.removeItem(at: harness.layout.profileDataURL(loaded.activeProfileID))

        let reloaded = harness.makeStore()
        guard case .activeProfileUnreadable = reloaded.load() else {
            Issue.record("expected activeProfileUnreadable")
            return
        }

        // Nothing to keep: there is no active profile whose bindings could
        // replace the file, and clearing the offer would remove the user's
        // only way back.
        #expect(reloaded.discardForeignMirror(activeShortcuts: []) == false)
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
        // Republished through the discard path, which is a real caller with no
        // bytes in hand — the same shape the startup repair uses.
        try harness.writeRaw(withUnknownMember, to: harness.layout.profileDataURL(loaded.activeProfileID))
        #expect(store.discardForeignMirror(activeShortcuts: loaded.activeShortcuts))

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
    func aFailedPreservationRefusesToOverwriteTheOutsideEdit() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        // "Preserve before overwriting" is the condition under which
        // overwriting is allowed, not advice. A full volume can refuse the
        // copy of a large edited payload and still accept the smaller
        // incoming write.
        let store = harness.makeStore(
            writeClient: ShortcutProfileStore.WriteClient { data, url in
                struct InjectedWriteFailure: Error {}
                if url.lastPathComponent.hasPrefix("shortcuts.unknown-") { throw InjectedWriteFailure() }
                try data.write(to: url, options: .atomic)
            }
        )
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        let outsideEdit = Data(#"[{"outside":true}]"#.utf8)
        try outsideEdit.write(to: harness.layout.mirrorURL, options: .atomic)

        try store.makeActiveProfilePersistenceService().save(
            [makeTestShortcut(appName: "Mail", bundleIdentifier: "com.apple.mail", keyEquivalent: "m")]
        )

        #expect(harness.data(at: harness.layout.mirrorURL) == outsideEdit)
    }

    @Test
    func aFutureSchemaDescriptorDoesNotAuthorizeAnOverwrite() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // A newer build wrote both files while this process was running. Its
        // mirror is the payload most likely to carry members this build
        // cannot model, so a descriptor it cannot validate must not be read
        // as permission to replace it.
        let futureBytes = Data(#"[{"future":true}]"#.utf8)
        try futureBytes.write(to: harness.layout.mirrorURL, options: .atomic)
        try harness.writeRaw(
            "{\"schemaVersion\": 2, \"profileID\": \"\(loaded.activeProfileID.uuidString)\", \"sha256\": \"\(ShortcutProfileStore.digest(futureBytes))\"}",
            to: harness.layout.mirrorDescriptorURL
        )

        try store.makeActiveProfilePersistenceService().save(
            [makeTestShortcut(appName: "Mail", bundleIdentifier: "com.apple.mail", keyEquivalent: "m")]
        )

        let copies = (try? FileManager.default.contentsOfDirectory(atPath: harness.directory.path))?
            .filter { $0.hasPrefix("shortcuts.unknown-") } ?? []
        #expect(copies.count == 1)
        #expect(harness.data(at: harness.directory.appendingPathComponent(copies[0])) == futureBytes)
    }

    @Test
    func aStaleRepairIsDeferredWhenItsPreservationCopyFails() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let first = harness.makeStore()
        guard case let .ready(loaded) = first.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let profileID = loaded.activeProfileID
        guard let mirrorBytes = harness.data(at: harness.layout.mirrorURL) else {
            Issue.record("expected a mirror after migration")
            return
        }

        // Same-profile stale: the profile file advanced, while the mirror and
        // its descriptor still agree with each other. `writeMirror` recognizes
        // its own current payload here and skips its guard by design, so the
        // copy taken before the repair is the ONLY thing protecting these
        // bytes — a silent failure would leave the overwrite unguarded.
        try PersistenceService.encodeShortcuts([makeTestShortcut(appName: "Advanced")])
            .write(to: harness.layout.profileDataURL(profileID), options: .atomic)

        let store = harness.makeStore(
            writeClient: ShortcutProfileStore.WriteClient { data, url in
                struct InjectedWriteFailure: Error {}
                if url.lastPathComponent.hasPrefix("shortcuts.unknown-") { throw InjectedWriteFailure() }
                try data.write(to: url, options: .atomic)
            }
        )
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // Deferred rather than forced through: the mirror still holds the
        // bytes nothing has a copy of, and the next save re-attempts.
        #expect(harness.data(at: harness.layout.mirrorURL) == mirrorBytes)
        #expect(
            harness.diagnostics.values.contains {
                $0.contains("PROFILE_TRACE_MIRROR_STALE_REPAIR_DEFERRED")
            }
        )
    }

    @Test
    func anImportIsRefusedWhileThoseIDsAreBeingDeleted() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        let shared = makeTestShortcut()
        try harness.writeLegacyShortcuts([shared])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let defaultID = loaded.activeProfileID
        let work = try store.createProfile(named: "Work", duplicating: nil)
        _ = try store.activateProfile(work.id)

        try harness.writeLegacyShortcuts([shared])
        try harness.writeRaw(
            """
            {"schemaVersion": 1, "profileID": "\(defaultID.uuidString)", "sha256": "\(ShortcutProfileStore.digest(Data("stale".utf8)))"}
            """,
            to: harness.layout.mirrorDescriptorURL
        )
        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }
        guard let mirror = after.foreignMirror else {
            Issue.record("expected an outside edit to be reported")
            return
        }

        // The drain has claimed this id and is mid-hop to the tracker actor.
        // Admitting it now yields a live shortcut whose history is erased a
        // moment later, which nothing can undo — so the import waits instead.
        reloaded.reserveUsageDeletions([shared.id])
        #expect(throws: ShortcutProfileStore.StoreError.usageDeletionInFlight) {
            _ = try reloaded.adoptForeignMirror(mirror)
        }

        // Once the deletion has landed, the same import proceeds.
        reloaded.releaseUsageDeletions([shared.id])
        #expect(throws: Never.self) {
            _ = try reloaded.adoptForeignMirror(mirror)
        }
    }

    @Test
    func aJournalledDeletionIsRecheckedAgainstTheProfilesThatExistNow() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        let shared = makeTestShortcut()
        try harness.writeLegacyShortcuts([shared])

        let store = harness.makeStore()
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let work = try store.createProfile(named: "Work", duplicating: nil)
        try PersistenceService.encodeShortcuts([shared])
            .write(to: harness.layout.profileDataURL(work.id), options: .atomic)

        // The shape a partial backup restore produces: a manifest owing a
        // deletion for an id a live profile still holds. Trusting the journal
        // there erases a live shortcut's Insights history, which is exactly
        // what the exclusivity rule exists to prevent — and is not undoable.
        let manifestData = try #require(harness.data(at: harness.layout.manifestURL))
        var manifestObject = try #require(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        manifestObject["pendingUsageDeletions"] = [shared.id.uuidString]
        try JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys])
            .write(to: harness.layout.manifestURL, options: .atomic)

        let reloaded = harness.makeStore()
        guard case .ready = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let drainable = reloaded.drainableUsageDeletions()
        #expect(drainable.deletable.isEmpty)
        #expect(drainable.retained == [shared.id])
    }

    @Test
    func anOrdinaryProfileSwitchDoesNotAccumulatePreservedCopies() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let defaultID = loaded.activeProfileID
        let work = try store.createProfile(named: "Work", duplicating: nil)

        // Every A->B switch reaches the writer while the mirror still holds A
        // and the descriptor still names A. Those bytes are not at risk: they
        // are exactly what Profiles/A.json contains. Copying them would leave
        // one junk file per distinct payload ever mirrored.
        for _ in 0..<3 {
            _ = try store.activateProfile(work.id)
            _ = try store.activateProfile(defaultID)
        }

        let copies = (try? FileManager.default.contentsOfDirectory(atPath: harness.directory.path))?
            .filter { $0.hasPrefix("shortcuts.unknown-") } ?? []
        #expect(copies.isEmpty)
    }

    @Test
    func migrationDecodesTheExactBytesItCopies() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }

        // An unmodelled member is the whole point: it survives a byte copy and
        // does not survive a re-encode, so it distinguishes the two paths.
        let legacy = """
        [
          {
            "id" : "66666666-6666-6666-6666-666666666666",
            "appName" : "Safari",
            "bundleIdentifier" : "com.apple.Safari",
            "keyEquivalent" : "s",
            "modifierFlags" : [ "command" ],
            "isEnabled" : true,
            "futureMemberFromANewerBuild" : "kept"
          }
        ]
        """
        try harness.writeRawLegacyShortcuts(legacy)

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // One read means the armed payload and the installed file cannot
        // disagree, and there is no second read that could fail and drop the
        // profile into the re-encoding fallback.
        #expect(harness.data(at: harness.layout.profileDataURL(loaded.activeProfileID)) == Data(legacy.utf8))
        #expect(loaded.activeShortcuts.count == 1)
        #expect(loaded.activeShortcuts[0].appName == "Safari")
    }

    @Test
    func aRefusedSwitchIsRejectedBeforeAnythingIsDiscarded() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let work = try store.createProfile(named: "Work", duplicating: nil)
        try harness.writeRaw("[ nope", to: harness.layout.profileDataURL(work.id))

        // Validation writes nothing, so a caller can run it before discarding
        // the recorder, the composer draft, or a pending import.
        #expect(throws: (any Error).self) {
            _ = try store.loadProfileForActivation(work.id)
        }
        #expect(store.locator.currentActiveProfileID() != work.id)
    }

    @Test
    func activationRefusesWhenTheCanonicalBytesChangedUnderIt() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let defaultID = loaded.activeProfileID
        let work = try store.createProfile(named: "Work", duplicating: nil)
        let validated = """
        [ { "id" : "77777777-7777-7777-7777-777777777777", "appName" : "Mail",
            "bundleIdentifier" : "com.apple.mail", "keyEquivalent" : "m",
            "modifierFlags" : [ "command" ], "isEnabled" : true, "futureMember" : "kept" } ]
        """
        try harness.writeRaw(validated, to: harness.layout.profileDataURL(work.id))

        let payload = try store.loadProfileForActivation(work.id)
        let mirrorBefore = harness.data(at: harness.layout.mirrorURL)

        // Validation and commit are not adjacent — `prepareForSwitch()` runs
        // between them — so another process can land a write in the gap.
        // Committing anyway would arm and mirror a payload the canonical file
        // no longer holds, and the next launch would silently arm the other.
        let replacement = """
        [ { "id" : "88888888-8888-8888-8888-888888888888", "appName" : "Replaced",
            "bundleIdentifier" : "com.example.replaced", "keyEquivalent" : "z",
            "modifierFlags" : [ "command" ], "isEnabled" : true } ]
        """
        try harness.writeRaw(replacement, to: harness.layout.profileDataURL(work.id))

        #expect(throws: ShortcutProfileStore.StoreError.profileChangedDuringOperation(id: work.id)) {
            try store.commitActivation(work.id, payload: payload)
        }

        // A refused switch changes nothing: the pointer never moved, and the
        // mirror still describes the profile that is actually armed.
        #expect(store.locator.currentActiveProfileID() == defaultID)
        #expect(harness.data(at: harness.layout.mirrorURL) == mirrorBefore)
        #expect(
            harness.diagnostics.values.contains {
                $0.contains("PROFILE_TRACE_PROFILE_CHANGED_DURING_OPERATION")
            }
        )
    }

    @Test
    func anUnchangedProfileActivatesAndMirrorsTheValidatedBytes() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let work = try store.createProfile(named: "Work", duplicating: nil)
        let validated = """
        [ { "id" : "99999999-9999-9999-9999-999999999999", "appName" : "Mail",
            "bundleIdentifier" : "com.apple.mail", "keyEquivalent" : "m",
            "modifierFlags" : [ "command" ], "isEnabled" : true, "futureMember" : "kept" } ]
        """
        try harness.writeRaw(validated, to: harness.layout.profileDataURL(work.id))

        let payload = try store.loadProfileForActivation(work.id)
        try store.commitActivation(work.id, payload: payload)

        // Canonical, armed, and mirrored are the same bytes — including the
        // member `AppShortcut` does not model, which a re-encode would drop.
        #expect(store.locator.currentActiveProfileID() == work.id)
        #expect(harness.data(at: harness.layout.mirrorURL) == Data(validated.utf8))
        #expect(harness.data(at: harness.layout.profileDataURL(work.id)) == Data(validated.utf8))
    }

    @Test
    func deletingRefusesWhenTheSuccessorChangedUnderThePlan() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let defaultID = loaded.activeProfileID
        let work = try store.createProfile(named: "Work", duplicating: nil)
        _ = try store.activateProfile(work.id)

        // Deleting Work falls back to Default, whose file is then replaced in
        // the same window a switch has.
        let plan = try store.planDeletion(of: work.id)
        try PersistenceService.encodeShortcuts([makeTestShortcut(appName: "Replaced")])
            .write(to: harness.layout.profileDataURL(defaultID), options: .atomic)

        #expect(throws: ShortcutProfileStore.StoreError.profileChangedDuringOperation(id: defaultID)) {
            _ = try store.deleteProfile(plan)
        }
        // Nothing was committed: the profile is still listed and still active.
        #expect(store.manifest?.profile(id: work.id) != nil)
        #expect(store.locator.currentActiveProfileID() == work.id)
    }

    @Test
    func preservationCopiesAreFlushedBeforeTheOverwriteTheyAuthorize() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        let durablePaths = CallbackRecorder<String>()
        let plainPaths = CallbackRecorder<String>()
        let recording = ShortcutProfileStore.WriteClient(
            write: { data, url in
                plainPaths.record(url.lastPathComponent)
                try data.write(to: url, options: .atomic)
            },
            writeDurable: { data, url in
                durablePaths.record(url.lastPathComponent)
                try data.write(to: url, options: .atomic)
            }
        )

        // An outside edit, so the next save has to preserve before overwriting.
        try harness.writeRawLegacyShortcuts("[ { \"appName\" : \"EditedOutside\" } ]")
        let saving = harness.makeStore(writeClient: recording)
        guard case .ready = saving.load() else {
            Issue.record("expected a ready load state")
            return
        }
        try saving.makeActiveProfilePersistenceService().save([makeTestShortcut(appName: "Mail")])

        // `.atomic` is a rename, not a barrier: without the flush the mirror
        // replacement can reach disk while the copy authorizing it does not,
        // and those bytes cannot be reconstructed by any recovery.
        #expect(durablePaths.values.contains { $0.hasPrefix("shortcuts.unknown-") })
        #expect(!plainPaths.values.contains { $0.hasPrefix("shortcuts.unknown-") })
    }

    @Test
    func theStartupRepairAlsoVerifiesAnExistingPreservationCopy() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        guard let mirrorBytes = harness.data(at: harness.layout.mirrorURL) else {
            Issue.record("expected a mirror after migration")
            return
        }
        let mirrorDigest = ShortcutProfileStore.digest(mirrorBytes)

        // Same-profile stale: the profile file advanced, so the repair's copy is
        // the only guard — the writer recognizes its own current payload here
        // and skips its own preservation by design.
        try PersistenceService.encodeShortcuts([makeTestShortcut(appName: "Advanced")])
            .write(to: harness.layout.profileDataURL(loaded.activeProfileID), options: .atomic)

        // ...and the path that copy would take is occupied by something else.
        let squatted = harness.directory
            .appendingPathComponent("shortcuts.unknown-\(mirrorDigest.prefix(12)).json")
        try harness.writeRaw("not the copy", to: squatted)

        guard case .ready = harness.makeStore().load() else {
            Issue.record("expected a ready load state")
            return
        }

        #expect(harness.data(at: squatted) == Data("not the copy".utf8))
        let fullURL = harness.directory.appendingPathComponent("shortcuts.unknown-\(mirrorDigest).json")
        #expect(harness.data(at: fullURL) == mirrorBytes)
    }

    @Test
    func aPreservationCopyThatIsNotTheCopyDoesNotAuthorizeAnOverwrite() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        let outsideEdit = "[ { \"appName\" : \"EditedOutside\" } ]"
        try harness.writeRawLegacyShortcuts(outsideEdit)
        let digest = ShortcutProfileStore.digest(Data(outsideEdit.utf8))

        // The path the copy WOULD take, already occupied by something else —
        // a partial restore, a manual edit, corruption. Treating a filename as
        // proof of a copy would authorize destroying the last real one.
        let squatted = harness.directory
            .appendingPathComponent("shortcuts.unknown-\(digest.prefix(12)).json")
        try harness.writeRaw("not the copy", to: squatted)

        let saving = harness.makeStore()
        guard case .ready = saving.load() else {
            Issue.record("expected a ready load state")
            return
        }
        try saving.makeActiveProfilePersistenceService().save([makeTestShortcut(appName: "Mail")])

        // The squatting file is untouched, and the edit is preserved under the
        // unambiguous full-digest name instead.
        #expect(harness.data(at: squatted) == Data("not the copy".utf8))
        let fullURL = harness.directory.appendingPathComponent("shortcuts.unknown-\(digest).json")
        #expect(harness.data(at: fullURL) == Data(outsideEdit.utf8))
    }

    @Test
    func anImportThatCannotRestoreTheActiveMirrorReportsFailure() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let setup = harness.makeStore()
        guard case let .ready(loaded) = setup.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let defaultID = loaded.activeProfileID
        let work = try setup.createProfile(named: "Work", duplicating: nil)
        _ = try setup.activateProfile(work.id)

        // An outside edit attributed to the INACTIVE Default profile: importing
        // it writes Default's file, then has to put Work's bindings back in the
        // compat file. If that restore fails, the import is not finished.
        let foreign = try PersistenceService.encodeShortcuts([makeTestShortcut(appName: "Mail")])
        try harness.writeRaw(String(decoding: foreign, as: UTF8.self), to: harness.layout.mirrorURL)
        // The descriptor names Default and does NOT match the file's digest:
        // that is what makes these bytes a foreign edit rather than a stale
        // mirror Wink itself left behind.
        try harness.writeRaw(
            """
            {"schemaVersion": 1, "profileID": "\(defaultID.uuidString)", "sha256": "\(ShortcutProfileStore.digest(Data("stale".utf8)))"}
            """,
            to: harness.layout.mirrorDescriptorURL
        )

        let mirrorURL = harness.layout.mirrorURL
        let allowMirrorWrite = MutableBox(true)
        let store = harness.makeStore(
            writeClient: ShortcutProfileStore.WriteClient(
                write: { data, url in
                    struct InjectedWriteFailure: Error {}
                    if url == mirrorURL, !allowMirrorWrite.value { throw InjectedWriteFailure() }
                    try data.write(to: url, options: .atomic)
                }
            )
        )
        guard case let .ready(after) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        guard let mirror = after.foreignMirror else {
            Issue.record("expected an outside edit to be reported")
            return
        }

        allowMirrorWrite.value = false
        #expect(throws: (any Error).self) {
            _ = try store.adoptForeignMirror(mirror)
        }
    }

    @Test
    func aMirrorWriteWithNoReadablePayloadRefusesRatherThanReencoding() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let mirrorBefore = harness.data(at: harness.layout.mirrorURL)

        // The old fallback re-encoded the model here, which ran exactly when
        // the file could not be read and produced a mirror with every
        // unmodelled member stripped — the loss D4 exists to prevent.
        try FileManager.default.removeItem(at: harness.layout.profileDataURL(loaded.activeProfileID))
        #expect(!store.discardForeignMirror(activeShortcuts: loaded.activeShortcuts))

        #expect(harness.data(at: harness.layout.mirrorURL) == mirrorBefore)
        #expect(
            harness.diagnostics.values.contains {
                $0.contains("PROFILE_TRACE_MIRROR_FAILED reason=profile_unreadable")
            }
        )
    }

    @Test
    func aCrashedSwitchIsRepairedWithoutWritingACopy() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let defaultID = loaded.activeProfileID
        let work = try store.createProfile(named: "Work", duplicating: nil)
        try PersistenceService.encodeShortcuts([makeTestShortcut(appName: "Mail")])
            .write(to: harness.layout.profileDataURL(work.id), options: .atomic)

        // A switch that committed its pointer and then died before the mirror
        // write: active is Work, the mirror and descriptor both still describe
        // Default. Default's own file holds those bytes, so the repair has
        // nothing to lose and must not leave a copy behind.
        try harness.writeRaw(
            """
            {"schemaVersion": 1, "activeProfileID": "\(work.id.uuidString)"}
            """,
            to: harness.layout.activePointerURL
        )

        let reloaded = harness.makeStore()
        guard case let .ready(after) = reloaded.load() else {
            Issue.record("expected a ready load state")
            return
        }
        #expect(after.activeProfileID == work.id)
        #expect(after.foreignMirror == nil)

        let copies = (try? FileManager.default.contentsOfDirectory(atPath: harness.directory.path))?
            .filter { $0.hasPrefix("shortcuts.unknown-") } ?? []
        #expect(copies.isEmpty)
        // Still repaired: the mirror now describes the profile that is armed.
        #expect(harness.decodedShortcuts(at: harness.layout.mirrorURL)?.first?.appName == "Mail")
        _ = defaultID
    }

    @Test
    func aMirrorItsSourceProfileNoLongerHoldsIsStillPreserved() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        guard let mirrorBytes = harness.data(at: harness.layout.mirrorURL) else {
            Issue.record("expected a mirror after migration")
            return
        }

        // The profile file advances without the mirror following — a crash
        // between the two writes. Now the mirror is the ONLY copy of those
        // bytes, so the redundancy exemption must not apply to it.
        try PersistenceService.encodeShortcuts([makeTestShortcut(appName: "Advanced")])
            .write(to: harness.layout.profileDataURL(loaded.activeProfileID), options: .atomic)

        guard case .ready = harness.makeStore().load() else {
            Issue.record("expected a ready load state after the stale repair")
            return
        }

        let copies = (try? FileManager.default.contentsOfDirectory(atPath: harness.directory.path))?
            .filter { $0.hasPrefix("shortcuts.unknown-") } ?? []
        #expect(copies.count == 1)
        #expect(harness.data(at: harness.directory.appendingPathComponent(copies[0])) == mirrorBytes)
    }

    @Test
    func anUnreadableCompatMirrorIsNeverReplaced() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case let .ready(loaded) = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let work = try store.createProfile(named: "Work", duplicating: nil)
        let originalBytes = harness.data(at: harness.layout.mirrorURL)

        // Present but unreadable, with a directory that still accepts an
        // atomic replacement. Treating that as absent would destroy the only
        // copy of an older build's or an external tool's edits.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: harness.layout.mirrorURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: harness.layout.mirrorURL.path
            )
        }

        // The switch itself still commits: the mirror is derived data, and its
        // refusal must not fail the operation that produced it.
        _ = try store.activateProfile(work.id)
        #expect(store.locator.currentActiveProfileID() == work.id)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: harness.layout.mirrorURL.path
        )
        #expect(harness.data(at: harness.layout.mirrorURL) == originalBytes)
        #expect(
            harness.diagnostics.values.contains {
                $0.contains("PROFILE_TRACE_MIRROR_WRITE_SKIPPED reason=existing_unreadable")
            }
        )
        _ = loaded
    }

    @Test
    func anUnreadableActivePointerIsNeitherAdoptedNorOverwritten() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])
        _ = harness.makeStore().load()

        let pointerBytes = harness.data(at: harness.layout.activePointerURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: harness.layout.activePointerURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: harness.layout.activePointerURL.path
            )
        }

        // A single profile normally licenses adoption, because there is no
        // other configuration it could be confused with. Bytes that cannot be
        // read are less interpretable than a future schema, which this code
        // already refuses to adopt — so it must not adopt here either, and it
        // must not overwrite the file while doing so.
        guard case .activeProfileAmbiguous = harness.makeStore().load() else {
            Issue.record("expected an unreadable pointer to fail closed")
            return
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: harness.layout.activePointerURL.path
        )
        #expect(harness.data(at: harness.layout.activePointerURL) == pointerBytes)
    }

    @Test
    func aManifestWithAnOverlongNameIsALoadFailure() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])
        _ = harness.makeStore().load()

        // Create and rename both reject this, so a restored or hand-edited
        // manifest must not be the one way into the state.
        let overlong = String(repeating: "a", count: ShortcutProfileNameRules.maximumLength + 1)
        try harness.writeRaw(
            """
            {"schemaVersion": 1, "profiles": [
              {"id": "44444444-4444-4444-4444-444444444444", "name": "\(overlong)",
               "createdAt": "2026-08-10T00:00:00Z", "modifiedAt": "2026-08-10T00:00:00Z"}
            ]}
            """,
            to: harness.layout.manifestURL
        )
        guard case .manifestUnreadable = harness.makeStore().load() else {
            Issue.record("expected an overlong-name manifest to be a load failure")
            return
        }
    }

    @Test
    func recoveryLeavesTheQuarantinedStateWhenThePointerCannotBeCommitted() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])
        _ = harness.makeStore().load()

        let damaged = "{ not a manifest"
        try harness.writeRaw(damaged, to: harness.layout.manifestURL)

        let pointerURL = harness.layout.activePointerURL
        let store = harness.makeStore(
            writeClient: ShortcutProfileStore.WriteClient { data, url in
                struct InjectedWriteFailure: Error {}
                if url == pointerURL { throw InjectedWriteFailure() }
                try data.write(to: url, options: .atomic)
            }
        )
        guard case .manifestUnreadable = store.load() else {
            Issue.record("expected manifestUnreadable")
            return
        }
        #expect(throws: (any Error).self) {
            _ = try store.recoverManifest()
        }

        // The manifest is written LAST, so a failure before it leaves exactly
        // the state the user is looking at rather than a disk that advanced
        // while the UI reported nothing had changed.
        #expect(harness.data(at: harness.layout.manifestURL) == Data(damaged.utf8))
        guard case .manifestUnreadable = harness.makeStore().load() else {
            Issue.record("expected the quarantined state to survive a failed recovery")
            return
        }
    }

    @Test
    func ordinarySavesDoNotAccumulatePreservedCopies() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let persistence = store.makeActiveProfilePersistenceService()

        // Each save supersedes Wink'''s own previous output for the same
        // profile. Preserving that would mean a copy per save — unbounded
        // garbage rather than protection.
        for index in 0..<5 {
            try persistence.save([makeTestShortcut(appName: "App \(index)")])
        }

        let copies = (try? FileManager.default.contentsOfDirectory(atPath: harness.directory.path))?
            .filter { $0.hasPrefix("shortcuts.unknown-") } ?? []
        #expect(copies.isEmpty)
    }

    @Test
    func anEditMadeWhileWinkIsRunningIsPreservedByTheNextSave() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([makeTestShortcut()])

        let store = harness.makeStore()
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }

        // The launch-time classification has already run. An external tool
        // editing the compat file now is invisible to it, so the guarantee
        // has to be re-established at the moment of overwrite instead.
        let outsideEdit = "[ { \"appName\" : \"EditedWhileRunning\" } ]"
        try harness.writeRawLegacyShortcuts(outsideEdit)

        try store.makeActiveProfilePersistenceService().save(
            [makeTestShortcut(appName: "Mail", bundleIdentifier: "com.apple.mail", keyEquivalent: "m")]
        )

        let copies = (try? FileManager.default.contentsOfDirectory(atPath: harness.directory.path))?
            .filter { $0.hasPrefix("shortcuts.unknown-") } ?? []
        #expect(copies.count == 1)
        let copyURL = harness.directory.appendingPathComponent(copies[0])
        #expect(harness.data(at: copyURL) == Data(outsideEdit.utf8))
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
    func duplicateNamingOfALongNameStillProducesAUsableName() {
        // Every length where appending " copy" crosses the limit. Load now
        // rejects an over-length name outright, so a generated one that
        // ignored the limit would either fail the action that needs no input
        // or persist a manifest that cannot be read back.
        let limit = ShortcutProfileNameRules.maximumLength
        for length in (limit - 4)...limit {
            let longName = String(repeating: "x", count: length)
            let existing = ShortcutProfile(name: longName, createdAt: Date(timeIntervalSince1970: 0))

            let name = ShortcutProfileNameRules.duplicateName(
                basedOn: longName,
                in: [existing],
                fallbackSuffix: UUID()
            )

            // Truncating the finished candidate would cut into the suffix and
            // hand back the source name itself, so the default Duplicate
            // action could never succeed for a near-maximum-length profile.
            #expect(name != longName, "length \(length)")
            #expect(name.count <= limit, "length \(length)")
            #expect(ShortcutProfileNameRules.violation(for: name, in: [existing]) == nil, "length \(length)")
        }
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
