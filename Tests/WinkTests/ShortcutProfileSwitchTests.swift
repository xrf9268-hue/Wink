import Carbon.HIToolbox
import Foundation
import Testing
@testable import Wink

// MARK: - Local fakes (per-file-fakes convention)

@MainActor
private final class FakeCaptureProvider: ShortcutCaptureProvider {
    var isRunning = false
    var inputMonitoringRequired = false
    private(set) var registeredShortcuts: Set<KeyPress> = []
    /// One entry per `updateRegisteredShortcuts` call, so a test can prove a
    /// switch reconfigures capture exactly once.
    private(set) var registrationUpdates: [Set<KeyPress>] = []
    private var onKeyPress: (@MainActor @Sendable (KeyPress) -> Void)?
    private var phasedObserver: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?

    func setPhasedKeyObserver(_ observer: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?) {
        phasedObserver = observer
    }

    func emitPhased(_ keyPress: KeyPress, _ phase: KeyEventPhase) {
        phasedObserver?(keyPress, phase)
    }

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: registeredShortcuts.count,
            registeredShortcutCount: registeredShortcuts.count,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        self.onKeyPress = onKeyPress
        isRunning = true
    }

    func stop() {
        isRunning = false
        onKeyPress = nil
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {
        registeredShortcuts = keyPresses
        registrationUpdates.append(keyPresses)
    }

    func emit(_ keyPress: KeyPress) {
        onKeyPress?(keyPress)
    }
}

@MainActor
private final class FakeHyperCaptureProvider: HyperShortcutCaptureProvider {
    var isRunning = false
    private var onKeyPress: (@MainActor @Sendable (KeyPress) -> Void)?

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(desiredShortcutCount: 0, registeredShortcutCount: 0, failures: [])
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        self.onKeyPress = onKeyPress
    }

    func stop() {
        onKeyPress = nil
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {}
    func setHyperKeyEnabled(_ enabled: Bool) {}
    func setHyperReleaseDeferralSuppressed(_ suppressed: Bool) {}
}

private struct FakePermissionService: PermissionServicing {
    func isTrusted() -> Bool { true }
    func isAccessibilityTrusted() -> Bool { true }
    func isInputMonitoringTrusted() -> Bool { true }
    @discardableResult
    func requestIfNeeded(prompt: Bool, inputMonitoringRequired: Bool) -> Bool { true }
}

@MainActor
private final class RecordingAppSwitcher: AppSwitching {
    private(set) var toggledBundleIdentifiers: [String] = []
    private(set) var cycleInvalidationReasons: [String] = []

    @discardableResult
    func toggleApplication(for shortcut: AppShortcut, bypassCooldown: Bool) -> Bool {
        toggledBundleIdentifiers.append(shortcut.bundleIdentifier)
        return true
    }

    func invalidateWindowCycleSession(reason: String) {
        cycleInvalidationReasons.append(reason)
    }

    func windowPickerSession(for shortcut: AppShortcut) -> WindowPickerSession? { nil }

    @discardableResult
    func focusPickedWindow(windowID: CGWindowID, session: WindowPickerSession) -> Bool { false }
}

// MARK: - Harness

@MainActor
private struct SwitchContext {
    let harness: TestProfileHarness
    let store: ShortcutProfileStore
    let state: ShortcutProfileState
    let manager: ShortcutManager
    let shortcutStore: ShortcutStore
    let appSwitcher: RecordingAppSwitcher
    let standardProvider: FakeCaptureProvider
    let prepared: CallbackRecorder<Bool>
}

private func safariShortcut(id: UUID = UUID()) -> AppShortcut {
    AppShortcut(
        id: id,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )
}

private func terminalShortcut(id: UUID = UUID()) -> AppShortcut {
    AppShortcut(
        id: id,
        appName: "Terminal",
        bundleIdentifier: "com.apple.Terminal",
        keyEquivalent: "t",
        modifierFlags: ["command", "shift"]
    )
}

private func safariKeyPress() -> KeyPress {
    KeyPress(keyCode: UInt16(kVK_ANSI_S), modifiers: [.command, .shift])
}

private func terminalKeyPress() -> KeyPress {
    KeyPress(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command, .shift])
}

@MainActor
private func makeSwitchContext(
    legacyShortcuts: [AppShortcut],
    drafts: DiscardedProfileSwitchDrafts = DiscardedProfileSwitchDrafts()
) throws -> SwitchContext {
    let harness = TestProfileHarness()
    try harness.writeLegacyShortcuts(legacyShortcuts)

    let store = harness.makeStore()
    let shortcutStore = ShortcutStore()
    let standardProvider = FakeCaptureProvider()
    let appSwitcher = RecordingAppSwitcher()
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: store.makeActiveProfilePersistenceService(),
        appSwitcher: appSwitcher,
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: standardProvider,
            hyperProvider: FakeHyperCaptureProvider()
        ),
        permissionService: FakePermissionService(),
        appBundleLocator: TestAppBundleLocator(entries: [
            "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app"),
            "com.apple.Terminal": URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
        ]).locator,
        automaticPermissionPromptingEnabled: false,
        diagnosticClient: .init(log: { _ in })
    )

    let prepared = CallbackRecorder<Bool>()
    let state = ShortcutProfileState(
        store: store,
        shortcutManager: manager,
        prepareForSwitch: {
            prepared.record(true)
            return drafts
        }
    )

    let loaded = state.loadAtStartup()
    shortcutStore.replaceAll(with: loaded)
    manager.start()

    return SwitchContext(
        harness: harness,
        store: store,
        state: state,
        manager: manager,
        shortcutStore: shortcutStore,
        appSwitcher: appSwitcher,
        standardProvider: standardProvider,
        prepared: prepared
    )
}

// MARK: - Runtime apply contract

@Suite("Shortcut profile runtime apply")
@MainActor
struct ShortcutProfileRuntimeApplyTests {
    @Test
    func switchingReplacesTheArmedSetAtomically() throws {
        let context = try makeSwitchContext(legacyShortcuts: [safariShortcut()])
        defer { context.harness.cleanup() }

        let defaultProfileID = try #require(context.state.activeProfileID)
        context.state.createProfile(named: "Work", duplicatingActiveProfile: false)
        let work = try #require(context.state.profiles.first { $0.id != defaultProfileID })
        try PersistenceService
            .encodeShortcuts([terminalShortcut()])
            .write(to: context.harness.layout.profileDataURL(work.id), options: .atomic)

        #expect(context.standardProvider.registeredShortcuts == [safariKeyPress()])

        context.state.switchToProfile(work.id)

        #expect(context.state.activeProfileID == work.id)
        #expect(context.shortcutStore.shortcuts.map(\.appName) == ["Terminal"])
        // The armed chord set follows in the same synchronous block: the
        // outgoing chord is gone and the incoming one is registered.
        #expect(context.standardProvider.registeredShortcuts == [terminalKeyPress()])
    }

    @Test
    func aSwitchReconfiguresCaptureExactlyOnce() throws {
        let context = try makeSwitchContext(legacyShortcuts: [safariShortcut()])
        defer { context.harness.cleanup() }

        let defaultProfileID = try #require(context.state.activeProfileID)
        context.state.createProfile(named: "Work", duplicatingActiveProfile: false)
        let work = try #require(context.state.profiles.first { $0.id != defaultProfileID })
        try PersistenceService
            .encodeShortcuts([terminalShortcut()])
            .write(to: context.harness.layout.profileDataURL(work.id), options: .atomic)

        let before = context.standardProvider.registrationUpdates.count
        context.state.switchToProfile(work.id)
        let updates = context.standardProvider.registrationUpdates.count - before

        #expect(updates == 1)
    }

    @Test
    func aRefusedSwitchAppliesNothing() throws {
        let context = try makeSwitchContext(legacyShortcuts: [safariShortcut()])
        defer { context.harness.cleanup() }

        let defaultProfileID = try #require(context.state.activeProfileID)
        context.state.createProfile(named: "Work", duplicatingActiveProfile: false)
        let work = try #require(context.state.profiles.first { $0.id != defaultProfileID })
        // An unreadable target: the switch must refuse before any commit.
        try context.harness.writeRaw("[ nope", to: context.harness.layout.profileDataURL(work.id))

        let updatesBefore = context.standardProvider.registrationUpdates.count
        context.state.switchToProfile(work.id)

        #expect(context.state.activeProfileID == defaultProfileID)
        #expect(context.shortcutStore.shortcuts.map(\.appName) == ["Safari"])
        #expect(context.standardProvider.registrationUpdates.count == updatesBefore)
        #expect(context.state.errorMessage != nil)
    }

    @Test
    func switchingInvalidatesTheWindowCycleSessionWithItsOwnReason() throws {
        let context = try makeSwitchContext(legacyShortcuts: [safariShortcut()])
        defer { context.harness.cleanup() }

        let defaultProfileID = try #require(context.state.activeProfileID)
        context.state.createProfile(named: "Work", duplicatingActiveProfile: true)
        let work = try #require(context.state.profiles.first { $0.id != defaultProfileID })

        let before = context.appSwitcher.cycleInvalidationReasons.count
        context.state.switchToProfile(work.id)
        let added = Array(context.appSwitcher.cycleInvalidationReasons.dropFirst(before))

        #expect(added == ["profile_switched"])
    }

    @Test
    func switchingToTheActiveProfileIsANoOp() throws {
        let context = try makeSwitchContext(legacyShortcuts: [safariShortcut()])
        defer { context.harness.cleanup() }

        let activeProfileID = try #require(context.state.activeProfileID)
        let updatesBefore = context.standardProvider.registrationUpdates.count

        context.state.switchToProfile(activeProfileID)

        #expect(context.standardProvider.registrationUpdates.count == updatesBefore)
        #expect(context.prepared.isEmpty)
    }

    @Test
    func savingAfterASwitchWritesIntoTheNewProfileAndItsMirror() throws {
        let context = try makeSwitchContext(legacyShortcuts: [safariShortcut()])
        defer { context.harness.cleanup() }

        let defaultProfileID = try #require(context.state.activeProfileID)
        context.state.createProfile(named: "Work", duplicatingActiveProfile: false)
        let work = try #require(context.state.profiles.first { $0.id != defaultProfileID })
        context.state.switchToProfile(work.id)

        try context.manager.save(shortcuts: [terminalShortcut()])

        let workBytes = context.harness.decodedShortcuts(at: context.harness.layout.profileDataURL(work.id))
        let defaultBytes = context.harness.decodedShortcuts(at: context.harness.layout.profileDataURL(defaultProfileID))
        #expect(workBytes?.map(\.appName) == ["Terminal"])
        // The previously active profile is untouched by a save made after the
        // switch — the locator, not a captured URL, decides the destination.
        #expect(defaultBytes?.map(\.appName) == ["Safari"])
        #expect(
            context.harness.data(at: context.harness.layout.mirrorURL)
                == context.harness.data(at: context.harness.layout.profileDataURL(work.id))
        )
    }
}

// MARK: - Editor conflict semantics (design record D14)

@Suite("Shortcut profile editor conflicts")
@MainActor
struct ShortcutProfileEditorConflictTests {
    @Test
    func aManualSwitchCancelsDraftsAndSaysSo() throws {
        let context = try makeSwitchContext(
            legacyShortcuts: [safariShortcut()],
            drafts: DiscardedProfileSwitchDrafts(
                cancelledRecorder: false,
                discardedComposerDraft: false,
                discardedImportPreview: true
            )
        )
        defer { context.harness.cleanup() }

        let defaultProfileID = try #require(context.state.activeProfileID)
        context.state.createProfile(named: "Work", duplicatingActiveProfile: true)
        let work = try #require(context.state.profiles.first { $0.id != defaultProfileID })

        context.state.switchToProfile(work.id)

        #expect(context.prepared.count == 1)
        // Discarded, but never silently.
        #expect(context.state.statusMessage != nil)
    }

    @Test
    func aRefusedSwitchStillReportsDraftsItAlreadyDiscarded() throws {
        let context = try makeSwitchContext(
            legacyShortcuts: [safariShortcut()],
            drafts: DiscardedProfileSwitchDrafts(
                cancelledRecorder: true,
                discardedComposerDraft: false,
                discardedImportPreview: false
            )
        )
        defer { context.harness.cleanup() }

        let defaultProfileID = try #require(context.state.activeProfileID)
        context.state.createProfile(named: "Work", duplicatingActiveProfile: false)
        let work = try #require(context.state.profiles.first { $0.id != defaultProfileID })
        try context.harness.writeRaw("[ nope", to: context.harness.layout.profileDataURL(work.id))

        context.state.switchToProfile(work.id)

        #expect(context.state.errorMessage != nil)
        #expect(context.state.statusMessage != nil)
    }

    @Test
    func externalSwitchesDeferWhileTheEditorHoldsUnsavedWork() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([safariShortcut()])

        let store = harness.makeStore()
        let shortcutStore = ShortcutStore()
        let manager = ShortcutManager(
            shortcutStore: shortcutStore,
            persistenceService: store.makeActiveProfilePersistenceService(),
            appSwitcher: RecordingAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )

        let hasUnsavedWork = CallbackRecorder<Bool>()
        let state = ShortcutProfileState(
            store: store,
            shortcutManager: manager,
            hasUnsavedEditorWork: { hasUnsavedWork.values.last ?? false }
        )
        _ = state.loadAtStartup()

        hasUnsavedWork.record(false)
        #expect(state.canApplyExternalSwitch)

        hasUnsavedWork.record(true)
        #expect(!state.canApplyExternalSwitch)
    }

    @Test
    func cancellingDraftsClearsTheRecorderGateAndTheImportPreview() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([safariShortcut()])

        let store = harness.makeStore()
        let shortcutStore = ShortcutStore()
        let manager = ShortcutManager(
            shortcutStore: shortcutStore,
            persistenceService: store.makeActiveProfilePersistenceService(),
            appSwitcher: RecordingAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )
        let editor = ShortcutEditorState(shortcutStore: shortcutStore, shortcutManager: manager)

        editor.selectedAppName = "Mail"
        editor.selectedBundleIdentifier = "com.apple.mail"
        editor.recordedShortcut = RecordedShortcut(keyEquivalent: "m", modifierFlags: ["command"])
        editor.isRecordingShortcut = true
        #expect(editor.hasUnsavedWork)

        let discarded = editor.cancelDraftsForProfileSwitch()

        #expect(discarded.cancelledRecorder)
        #expect(discarded.discardedComposerDraft)
        #expect(!editor.isRecordingShortcut)
        #expect(!editor.isRecordingSearchPaletteShortcut)
        #expect(editor.recordedShortcut == nil)
        #expect(editor.selectedBundleIdentifier.isEmpty)
        #expect(!editor.hasUnsavedWork)
    }
}

// MARK: - Deletion

@Suite("Shortcut profile deletion runtime")
@MainActor
struct ShortcutProfileDeletionRuntimeTests {
    @Test
    func deletingTheActiveProfileAppliesTheSuccessorToTheRuntime() throws {
        let context = try makeSwitchContext(legacyShortcuts: [safariShortcut()])
        defer { context.harness.cleanup() }

        let defaultProfileID = try #require(context.state.activeProfileID)
        context.state.createProfile(named: "Work", duplicatingActiveProfile: false)
        let work = try #require(context.state.profiles.first { $0.id != defaultProfileID })
        try PersistenceService
            .encodeShortcuts([terminalShortcut()])
            .write(to: context.harness.layout.profileDataURL(work.id), options: .atomic)
        context.state.switchToProfile(work.id)
        #expect(context.standardProvider.registeredShortcuts == [terminalKeyPress()])

        context.state.deleteProfile(work.id)

        #expect(context.state.activeProfileID == defaultProfileID)
        #expect(context.shortcutStore.shortcuts.map(\.appName) == ["Safari"])
        #expect(context.standardProvider.registeredShortcuts == [safariKeyPress()])
    }

    @Test
    func deletingAnInactiveProfileLeavesTheRuntimeAlone() throws {
        let context = try makeSwitchContext(legacyShortcuts: [safariShortcut()])
        defer { context.harness.cleanup() }

        let defaultProfileID = try #require(context.state.activeProfileID)
        context.state.createProfile(named: "Work", duplicatingActiveProfile: false)
        let work = try #require(context.state.profiles.first { $0.id != defaultProfileID })

        let updatesBefore = context.standardProvider.registrationUpdates.count
        context.state.deleteProfile(work.id)

        #expect(context.state.activeProfileID == defaultProfileID)
        #expect(context.standardProvider.registrationUpdates.count == updatesBefore)
        #expect(context.prepared.isEmpty)
    }
}

// MARK: - Recovery states arm nothing

@Suite("Shortcut profile recovery arms nothing")
@MainActor
struct ShortcutProfileRecoveryRuntimeTests {
    @Test
    func aQuarantinedManifestArmsNothingAndBlocksMutation() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([safariShortcut()])

        let firstStore = harness.makeStore()
        _ = firstStore.load()
        try harness.writeRaw("{ truncated", to: harness.layout.manifestURL)

        let store = harness.makeStore()
        let manager = ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: store.makeActiveProfilePersistenceService(),
            appSwitcher: RecordingAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )
        let state = ShortcutProfileState(store: store, shortcutManager: manager)

        let armed = state.loadAtStartup()

        #expect(armed.isEmpty)
        #expect(!state.isMutable)
        #expect(!state.canApplyExternalSwitch)

        state.createProfile(named: "Work", duplicatingActiveProfile: false)
        #expect(state.errorMessage != nil)
        #expect(state.profiles.isEmpty)

        state.recoverFromUnreadableManifest()
        #expect(state.isMutable)
        #expect(state.profiles.count == 1)
    }

    @Test
    func anAmbiguousActivePointerArmsNothingAndNeverAutoSelects() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([safariShortcut()])

        let firstStore = harness.makeStore()
        _ = firstStore.load()
        try firstStore.createProfile(named: "Work", duplicating: nil)
        try FileManager.default.removeItem(at: harness.layout.activePointerURL)

        let store = harness.makeStore()
        let manager = ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: store.makeActiveProfilePersistenceService(),
            appSwitcher: RecordingAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )
        let state = ShortcutProfileState(store: store, shortcutManager: manager)

        let armed = state.loadAtStartup()

        #expect(armed.isEmpty)
        #expect(state.activeProfileID == nil)
        #expect(state.profiles.count == 2)
        // The list is offered so the user can pick — but nothing is chosen.
        #expect(state.recovery != .none)
    }

    @MainActor
    @Test
    func duplicatingWithNoActiveProfileIsRefusedRatherThanEmptied() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([safariShortcut()])
        let firstLoad = harness.makeStore()
        guard case let .ready(loaded) = firstLoad.load() else {
            Issue.record("expected a ready load state")
            return
        }
        _ = try firstLoad.createProfile(named: "Work", duplicating: nil)

        // activeProfileUnreadable keeps the manager usable on purpose — the
        // user is meant to be able to pick their way out of it — but there is
        // no active profile to copy.
        try harness.writeRaw("[ nope", to: harness.layout.profileDataURL(loaded.activeProfileID))

        let store = harness.makeStore()
        let manager = ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: store.makeActiveProfilePersistenceService(),
            appSwitcher: RecordingAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )
        let state = ShortcutProfileState(store: store, shortcutManager: manager)
        _ = state.loadAtStartup()

        #expect(state.activeProfileID == nil)
        #expect(state.canCreateProfile)
        #expect(!state.canDuplicateActiveProfile)

        let before = state.profiles.count
        state.createProfile(named: "Copy", duplicatingActiveProfile: true)
        #expect(state.profiles.count == before)
        #expect(state.errorMessage != nil)
    }

    @MainActor
    @Test
    func deletingTheProfileAnOutsideEditTargetsClearsTheOffer() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([safariShortcut()])

        let setup = harness.makeStore()
        guard case let .ready(loaded) = setup.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let defaultID = loaded.activeProfileID
        _ = try setup.createProfile(named: "Work", duplicating: nil)

        // What an older build does: rewrite shortcuts.json directly. The
        // resulting offer addresses the Default profile by id, so deleting
        // that profile leaves it rendering a name with nothing behind it and
        // an import that can only fail with profileNotFound.
        try harness.writeLegacyShortcuts([
            AppShortcut(
                appName: "Mail",
                bundleIdentifier: "com.apple.mail",
                keyEquivalent: "m",
                modifierFlags: ["command"]
            )
        ])

        let store = harness.makeStore()
        let manager = ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: store.makeActiveProfilePersistenceService(),
            appSwitcher: RecordingAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )
        let state = ShortcutProfileState(store: store, shortcutManager: manager)
        _ = state.loadAtStartup()
        #expect(state.pendingForeignMirror?.profileID == defaultID)

        state.deleteProfile(defaultID)
        #expect(state.pendingForeignMirror == nil)
    }

    @MainActor
    @Test
    func switchingToAnUnreadableProfileKeepsTheUsersInFlightWork() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([safariShortcut()])

        let setup = harness.makeStore()
        guard case let .ready(loaded) = setup.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let defaultID = loaded.activeProfileID
        let work = try setup.createProfile(named: "Work", duplicating: nil)
        try harness.writeRaw("[ nope", to: harness.layout.profileDataURL(work.id))

        let store = harness.makeStore()
        let manager = ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: store.makeActiveProfilePersistenceService(),
            appSwitcher: RecordingAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )
        let prepareCount = CallbackRecorder<Bool>()
        let state = ShortcutProfileState(
            store: store,
            shortcutManager: manager,
            prepareForSwitch: {
                prepareCount.record(true)
                return DiscardedProfileSwitchDrafts()
            }
        )
        _ = state.loadAtStartup()

        // The switch cannot succeed, so nothing may be thrown away for it:
        // prepareForSwitch cancels the recorder, the composer draft, and any
        // pending import, and the user gets none of that back.
        state.switchToProfile(work.id)

        #expect(prepareCount.isEmpty)
        #expect(state.activeProfileID == defaultID)
        #expect(state.errorMessage != nil)
    }

    @MainActor
    @Test
    func deletingAnActiveProfileWithAnUnreadableSuccessorDiscardsNothing() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([safariShortcut()])

        let setup = harness.makeStore()
        guard case let .ready(loaded) = setup.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let defaultID = loaded.activeProfileID
        let work = try setup.createProfile(named: "Work", duplicating: nil)
        // Default is first in list order, so deleting it falls back to Work.
        try harness.writeRaw("[ nope", to: harness.layout.profileDataURL(work.id))

        let store = harness.makeStore()
        let manager = ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: store.makeActiveProfilePersistenceService(),
            appSwitcher: RecordingAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )
        let prepareCount = CallbackRecorder<Bool>()
        let state = ShortcutProfileState(
            store: store,
            shortcutManager: manager,
            prepareForSwitch: {
                prepareCount.record(true)
                return DiscardedProfileSwitchDrafts()
            }
        )
        _ = state.loadAtStartup()

        // The delete throws on the unreadable successor, so the same rule the
        // switch path follows applies: plan first, discard only once the
        // operation can proceed.
        state.deleteProfile(defaultID)

        #expect(prepareCount.isEmpty)
        #expect(state.activeProfileID == defaultID)
        #expect(state.profiles.count == 2)
        #expect(state.errorMessage != nil)
    }

    @MainActor
    @Test
    func aFailedUsageDeletionKeepsItsJournalEntryForTheNextLaunch() async throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        let shared = safariShortcut()
        try harness.writeLegacyShortcuts([shared])

        let setup = harness.makeStore()
        guard case let .ready(loaded) = setup.load() else {
            Issue.record("expected a ready load state")
            return
        }
        _ = try setup.createProfile(named: "Work", duplicating: nil)
        _ = try setup.deleteProfile(loaded.activeProfileID)
        #expect(setup.pendingUsageDeletions() == [shared.id])

        let store = harness.makeStore()
        guard case .ready = store.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let manager = ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: store.makeActiveProfilePersistenceService(),
            appSwitcher: RecordingAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )
        let tracker = FailingDeleteUsageTracker()
        let state = ShortcutProfileState(store: store, shortcutManager: manager, usageTracker: tracker)

        // The database refuses the delete. Clearing the journal here would
        // strand the rows with no record that they were ever owed a deletion.
        state.drainPendingUsageDeletions()
        await state.waitForPendingUsageDrainForTesting()

        #expect(tracker.attempts.values.contains(shared.id))
        #expect(store.pendingUsageDeletions() == [shared.id])
    }

    @MainActor
    @Test
    func importingIntoTheActiveProfileDiscardsStaleDraftsFirst() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([safariShortcut()])
        _ = harness.makeStore().load()
        // An older build rewrites the compat file behind Wink's back.
        try harness.writeLegacyShortcuts([terminalShortcut()])

        let store = harness.makeStore()
        let manager = ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: store.makeActiveProfilePersistenceService(),
            appSwitcher: RecordingAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )
        let prepared = CallbackRecorder<Bool>()
        let state = ShortcutProfileState(
            store: store,
            shortcutManager: manager,
            prepareForSwitch: {
                prepared.record(true)
                return DiscardedProfileSwitchDrafts()
            }
        )
        _ = state.loadAtStartup()
        #expect(state.pendingForeignMirror != nil)

        // The import replaces the runtime set exactly as a switch does, so
        // the same preparation runs, in the same commit-then-prepare order:
        // a recorder, composer draft, or recipe preview computed against the
        // PRE-import bindings must not survive to be saved into the imported
        // profile.
        state.adoptPendingForeignMirror()

        #expect(prepared.count == 1)
        #expect(state.pendingForeignMirror == nil)
        #expect(state.errorMessage == nil)
    }

    @MainActor
    @Test
    func aDissolvedOfferUnmarksTheProfileItsFirstAttemptRepaired() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([safariShortcut()])
        let setup = harness.makeStore()
        guard case let .ready(loaded) = setup.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let defaultID = loaded.activeProfileID
        let work = try setup.createProfile(named: "Work", duplicating: nil)
        _ = try setup.activateProfile(work.id)

        // Crash window of the Work→Default switch: the pointer moves back,
        // the mirror write fails, and the descriptor keeps naming Work — the
        // state that makes a later foreign edit's offer target the INACTIVE
        // profile.
        let mirrorURL = harness.layout.mirrorURL
        let failing = harness.makeStore(
            writeClient: ShortcutProfileStore.WriteClient(
                write: { data, url in
                    struct InjectedWriteFailure: Error {}
                    if url == mirrorURL { throw InjectedWriteFailure() }
                    try data.write(to: url, options: .atomic)
                }
            )
        )
        _ = failing.load()
        _ = try failing.activateProfile(defaultID)

        // An older build rewrites the file, and Work's own data file is
        // unreadable — the state the import offer exists to repair.
        try harness.writeLegacyShortcuts([terminalShortcut()])
        try harness.writeRaw("[ nope", to: harness.layout.profileDataURL(work.id))

        let store = harness.makeStore()
        let manager = ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: store.makeActiveProfilePersistenceService(),
            appSwitcher: RecordingAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )
        let state = ShortcutProfileState(store: store, shortcutManager: manager)
        _ = state.loadAtStartup()
        #expect(state.pendingForeignMirror?.profileID == work.id)
        #expect(state.unreadableProfileIDs.contains(work.id))

        // What a partially failed first attempt leaves on disk: Work's data
        // repaired with the offered bytes, the active profile's bytes
        // restored to the compat file, nothing else updated.
        let foreignBytes = try #require(state.pendingForeignMirror?.rawBytes)
        try foreignBytes.write(to: harness.layout.profileDataURL(work.id))
        let activeBytes = try #require(harness.data(at: harness.layout.profileDataURL(defaultID)))
        try activeBytes.write(to: mirrorURL)

        // The retry: refused for drift, dissolved by reclassification — and
        // the profile the first attempt repaired must come back readable
        // without a relaunch, or every picker keeps disabling it.
        state.adoptPendingForeignMirror()

        #expect(state.pendingForeignMirror == nil)
        #expect(!state.unreadableProfileIDs.contains(work.id))
        // With no banner and no action left, "review it and try again" would
        // be an instruction pointing at nothing: the resolved state is
        // reported as status, not as an error.
        #expect(state.errorMessage == nil)
        #expect(state.statusMessage != nil)
    }
}

    @MainActor
    @Test
    func aSwitchRefusedAtTheCommitDiscardsNothing() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([safariShortcut()])

        let setup = harness.makeStore()
        guard case let .ready(loaded) = setup.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let defaultID = loaded.activeProfileID
        let work = try setup.createProfile(named: "Work", duplicating: nil)

        // The commit fails at the pointer write. Any refusal reachable from
        // `commitActivation` — this one, or the commit-time re-check when the
        // profile changed underneath — arrives AFTER validation, which is
        // exactly where preparation used to have already run.
        let pointerURL = harness.layout.activePointerURL
        let store = harness.makeStore(
            writeClient: ShortcutProfileStore.WriteClient(
                write: { data, url in
                    struct InjectedWriteFailure: Error {}
                    if url == pointerURL { throw InjectedWriteFailure() }
                    try data.write(to: url, options: .atomic)
                }
            )
        )
        let manager = ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: store.makeActiveProfilePersistenceService(),
            appSwitcher: RecordingAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )
        let prepared = CallbackRecorder<Bool>()
        let state = ShortcutProfileState(
            store: store,
            shortcutManager: manager,
            prepareForSwitch: {
                prepared.record(true)
                return DiscardedProfileSwitchDrafts()
            }
        )
        _ = state.loadAtStartup()

        state.switchToProfile(work.id)

        // The recorder, the composer draft, and any pending import are the
        // user's work and cannot be restored, so a switch that refuses must
        // never have touched them.
        #expect(prepared.isEmpty)
        #expect(state.activeProfileID == defaultID)
        #expect(state.errorMessage != nil)
    }

    @MainActor
    @Test
    func importingIntoAnInactiveProfileMarksItReadableAgain() throws {
        let harness = TestProfileHarness()
        defer { harness.cleanup() }
        try harness.writeLegacyShortcuts([safariShortcut()])

        let setup = harness.makeStore()
        guard case let .ready(loaded) = setup.load() else {
            Issue.record("expected a ready load state")
            return
        }
        let defaultID = loaded.activeProfileID
        let work = try setup.createProfile(named: "Work", duplicating: nil)
        _ = try setup.activateProfile(work.id)

        // Default is inactive and unreadable, and the outside edit is exactly
        // what repairs it. A nil return means only "nothing to arm right now".
        try harness.writeRaw("[ nope", to: harness.layout.profileDataURL(defaultID))
        let repaired = try PersistenceService.encodeShortcuts([makeTestShortcut(appName: "Mail")])
        try harness.writeRaw(String(decoding: repaired, as: UTF8.self), to: harness.layout.mirrorURL)
        try harness.writeRaw(
            """
            {"schemaVersion": 1, "profileID": "\(defaultID.uuidString)", "sha256": "\(ShortcutProfileStore.digest(Data("stale".utf8)))"}
            """,
            to: harness.layout.mirrorDescriptorURL
        )

        let store = harness.makeStore()
        let manager = ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: store.makeActiveProfilePersistenceService(),
            appSwitcher: RecordingAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(),
            automaticPermissionPromptingEnabled: false,
            diagnosticClient: .init(log: { _ in })
        )
        let state = ShortcutProfileState(store: store, shortcutManager: manager)
        _ = state.loadAtStartup()
        #expect(state.unreadableProfileIDs.contains(defaultID))
        #expect(state.pendingForeignMirror?.profileID == defaultID)

        state.adoptPendingForeignMirror()

        // Still on Work, but Default is loadable now and every picker must say so.
        #expect(state.activeProfileID == work.id)
        #expect(!state.unreadableProfileIDs.contains(defaultID))
        #expect(state.pendingForeignMirror == nil)
    }

/// Reports every deletion as failed, which is what an unavailable or erroring
/// SQLite connection does.
final class FailingDeleteUsageTracker: UsageTracking, @unchecked Sendable {
    let attempts = CallbackRecorder<UUID>()
    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] { [:] }
    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] { [:] }
    func totalSwitches(days: Int, relativeTo now: Date) async -> Int { 0 }
    func hourlyCounts(days: Int, relativeTo now: Date) async -> [HourlyUsageBucket] { [] }
    func previousPeriodTotal(days: Int, relativeTo now: Date) async -> Int { 0 }
    func streakDays(relativeTo now: Date) async -> Int { 0 }
    func usageTimeZone() async -> TimeZone { .gmt }
    func lastUsedPerShortcut() async -> [UUID: Date] { [:] }
    func appActivationTotals(days: Int, relativeTo now: Date) async -> [(bundleIdentifier: String, count: Int)] { [] }
    func dashboardSnapshot(for request: UsageDashboardRequest) async -> UsageDashboardSnapshot? { nil }
    func deleteUsage(shortcutId: UUID) async -> Bool {
        attempts.record(shortcutId)
        return false
    }
}
