import Carbon.HIToolbox
import Foundation
import Testing
@testable import Wink

// MARK: - Local fakes (per-file-fakes convention; mirrors the
// SearchPaletteDispatchTests harness shape)

@MainActor
private final class FakeCaptureProvider: ShortcutCaptureProvider {
    var isRunning = false
    var inputMonitoringRequired = false
    private(set) var registeredShortcuts: Set<KeyPress> = []
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
    }

    func emit(_ keyPress: KeyPress) {
        onKeyPress?(keyPress)
    }
}

@MainActor
private final class FakeHyperCaptureProvider: HyperShortcutCaptureProvider {
    var isRunning = false
    private(set) var hyperReleaseDeferralSuppressionCalls: [Bool] = []
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

    func setHyperReleaseDeferralSuppressed(_ suppressed: Bool) {
        hyperReleaseDeferralSuppressionCalls.append(suppressed)
    }
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

    @discardableResult
    func toggleApplication(for shortcut: AppShortcut, bypassCooldown: Bool) -> Bool {
        toggledBundleIdentifiers.append(shortcut.bundleIdentifier)
        return true
    }
}

private func safariShortcut(holdAction: HoldAction? = nil) -> AppShortcut {
    AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"],
        holdAction: holdAction
    )
}

private func safariKeyPress() -> KeyPress {
    KeyPress(keyCode: UInt16(kVK_ANSI_S), modifiers: [.command, .shift])
}

private func paletteTriggerShortcut() -> AppShortcut {
    AppShortcut(
        appName: AppShortcut.searchPaletteTargetStableName,
        bundleIdentifier: AppShortcut.searchPaletteTargetSentinelBundleIdentifier,
        keyEquivalent: "space",
        modifierFlags: ["command", "option"],
        target: .searchPalette
    )
}

private func paletteTriggerKeyPress() -> KeyPress {
    KeyPress(keyCode: UInt16(kVK_Space), modifiers: [.command, .option])
}

@MainActor
private func makeContext(
    shortcuts: [AppShortcut]
) -> (
    manager: ShortcutManager,
    editor: ShortcutEditorState,
    appSwitcher: RecordingAppSwitcher,
    standardProvider: FakeCaptureProvider,
    hyperProvider: FakeHyperCaptureProvider
) {
    let shortcutStore = ShortcutStore()
    shortcutStore.replaceAll(with: shortcuts)
    let standardProvider = FakeCaptureProvider()
    let hyperProvider = FakeHyperCaptureProvider()
    let appSwitcher = RecordingAppSwitcher()
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: TestPersistenceHarness().makePersistenceService(),
        appSwitcher: appSwitcher,
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: standardProvider,
            hyperProvider: hyperProvider
        ),
        permissionService: FakePermissionService(),
        appBundleLocator: TestAppBundleLocator(entries: [
            "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app"),
        ]).locator,
        diagnosticClient: .init(log: { _ in })
    )
    manager.start()
    let editor = ShortcutEditorState(
        shortcutStore: shortcutStore,
        shortcutManager: manager
    )
    return (manager, editor, appSwitcher, standardProvider, hyperProvider)
}

// MARK: - #417/#418 P1: recording sessions gate matched-chord dispatch

@Test @MainActor
func recordingSessionSwallowsAnAlreadyBoundChordInsteadOfTogglingItsTarget() {
    let context = makeContext(shortcuts: [safariShortcut()])

    context.manager.setRecordingSessionActive(true)
    context.standardProvider.emit(safariKeyPress())

    #expect(context.appSwitcher.toggledBundleIdentifiers.isEmpty)
}

@Test @MainActor
func recordingSessionSwallowsTheSearchPaletteTrigger() {
    let context = makeContext(shortcuts: [paletteTriggerShortcut()])
    var firedCount = 0
    context.manager.onSearchPaletteTriggered = {
        firedCount += 1
    }

    context.manager.setRecordingSessionActive(true)
    context.standardProvider.emit(paletteTriggerKeyPress())

    #expect(firedCount == 0)
}

@Test @MainActor
func dispatchResumesOnceTheRecordingSessionEnds() {
    let context = makeContext(shortcuts: [safariShortcut()])

    context.manager.setRecordingSessionActive(true)
    context.standardProvider.emit(safariKeyPress())
    #expect(context.appSwitcher.toggledBundleIdentifiers.isEmpty)

    context.manager.setRecordingSessionActive(false)
    context.standardProvider.emit(safariKeyPress())
    #expect(context.appSwitcher.toggledBundleIdentifiers == ["com.apple.Safari"])
}

@Test @MainActor
func recordingSessionNeverTouchesTheHyperReleaseDeferral() {
    // Divergence from the interactive-panel seam is deliberate: recording
    // starts from a mouse click (no chord straddles the boundary), and the
    // recorder needs Caps Lock to keep acting as Hyper so Hyper chords stay
    // recordable. Suppressing the deferral here would change Caps Lock
    // semantics for the whole session.
    let context = makeContext(shortcuts: [safariShortcut()])

    context.manager.setRecordingSessionActive(true)
    context.manager.setRecordingSessionActive(false)

    #expect(context.hyperProvider.hyperReleaseDeferralSuppressionCalls.isEmpty)
}

// MARK: - #419: bound chords reroute to the live recorder

@Test @MainActor
func recordingSessionReroutesTheBoundChordToTheCallbackInsteadOfDropping() {
    let context = makeContext(shortcuts: [safariShortcut()])
    var rerouted: [KeyPress] = []
    context.manager.onRecordingSessionKeyPress = { rerouted.append($0) }

    context.manager.setRecordingSessionActive(true)
    context.standardProvider.emit(safariKeyPress())

    #expect(rerouted == [safariKeyPress()])
    #expect(context.appSwitcher.toggledBundleIdentifiers.isEmpty)
}

@Test @MainActor
func reroutedBoundChordSurfacesThePaletteConflictImmediately() {
    let context = makeContext(shortcuts: [safariShortcut()])
    context.manager.onRecordingSessionKeyPress = { [weak editor = context.editor] in
        editor?.handleRecordingSessionKeyPress($0)
    }

    context.editor.isRecordingSearchPaletteShortcut = true
    context.standardProvider.emit(safariKeyPress())

    #expect(context.editor.searchPaletteConflictMessage != nil)
    #expect(!context.editor.isRecordingSearchPaletteShortcut)
    #expect(context.editor.searchPaletteShortcut == nil)
    #expect(context.appSwitcher.toggledBundleIdentifiers.isEmpty)
}

@Test @MainActor
func reroutedReRecordOfThePalettesOwnTriggerCommitsCleanly() {
    // The one non-conflict reroute: the palette trigger IS a bound chord,
    // so re-recording the same combo arrives via the reroute — the
    // validator excludes the candidate's own id and the commit replaces
    // the binding in place.
    let context = makeContext(shortcuts: [paletteTriggerShortcut()])
    context.manager.onRecordingSessionKeyPress = { [weak editor = context.editor] in
        editor?.handleRecordingSessionKeyPress($0)
    }

    context.editor.isRecordingSearchPaletteShortcut = true
    context.standardProvider.emit(paletteTriggerKeyPress())

    #expect(context.editor.searchPaletteConflictMessage == nil)
    #expect(context.editor.searchPaletteShortcut != nil)
    #expect(!context.editor.isRecordingSearchPaletteShortcut)
}

@Test @MainActor
func reroutedBoundChordFillsTheComposerDraft() {
    let context = makeContext(shortcuts: [safariShortcut()])
    context.manager.onRecordingSessionKeyPress = { [weak editor = context.editor] in
        editor?.handleRecordingSessionKeyPress($0)
    }

    context.editor.isRecordingShortcut = true
    context.standardProvider.emit(safariKeyPress())

    #expect(context.editor.recordedShortcut == RecordedShortcut(keyEquivalent: "s", modifierFlags: ["shift", "command"]))
    #expect(!context.editor.isRecordingShortcut)
    #expect(context.appSwitcher.toggledBundleIdentifiers.isEmpty)
}

@Test @MainActor
func unmappableKeyLeavesTheRecordingSessionLive() {
    let context = makeContext(shortcuts: [safariShortcut()])

    context.editor.isRecordingShortcut = true
    context.editor.handleRecordingSessionKeyPress(KeyPress(keyCode: 0xFFFF, modifiers: [.command]))

    #expect(context.editor.recordedShortcut == nil)
    #expect(context.editor.isRecordingShortcut)
}

@Test @MainActor
func phasedDownEdgeReroutesWhileRecordingAndUpEdgeDoesNot() {
    // Phased chords bypass handleKeyPress entirely — the reroute must live
    // on the phased-observer path too, down edge only.
    let context = makeContext(shortcuts: [safariShortcut(holdAction: .windowPicker)])
    var rerouted: [KeyPress] = []
    context.manager.onRecordingSessionKeyPress = { rerouted.append($0) }

    context.manager.setRecordingSessionActive(true)
    context.standardProvider.emitPhased(safariKeyPress(), .down)
    context.standardProvider.emitPhased(safariKeyPress(), .up)

    #expect(rerouted == [safariKeyPress()])
    #expect(context.appSwitcher.toggledBundleIdentifiers.isEmpty)
}

@Test @MainActor
func reroutedBoundEscapeChordCancelsTheSessionLikeTheMonitorPath() {
    // Codex pre-push review (medium): KeyMatcher permits persisted ⌘⎋-style
    // bindings, and the recorder's monitor treats keyCode 53 as cancel
    // BEFORE inspecting modifiers. The reroute must not diverge: a bound
    // modified-Escape cancels, it never becomes a captured chord.
    let escapeShortcut = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "escape",
        modifierFlags: ["command"]
    )
    let context = makeContext(shortcuts: [escapeShortcut])
    context.manager.onRecordingSessionKeyPress = { [weak editor = context.editor] in
        editor?.handleRecordingSessionKeyPress($0)
    }

    context.editor.isRecordingSearchPaletteShortcut = true
    context.standardProvider.emit(KeyPress(keyCode: 53, modifiers: [.command]))

    #expect(!context.editor.isRecordingSearchPaletteShortcut)
    #expect(context.editor.searchPaletteShortcut == nil)
    #expect(context.editor.searchPaletteConflictMessage == nil)

    context.editor.isRecordingShortcut = true
    context.editor.handleRecordingSessionKeyPress(KeyPress(keyCode: 53, modifiers: [.command]))
    #expect(!context.editor.isRecordingShortcut)
    #expect(context.editor.recordedShortcut == nil)
}

@Test @MainActor
func rerouteWithNoLiveRecorderIsANoOp() {
    // A stale gate flag (manager on, both editor flags off) must not let a
    // rerouted press corrupt either draft.
    let context = makeContext(shortcuts: [safariShortcut()])

    context.editor.handleRecordingSessionKeyPress(safariKeyPress())

    #expect(context.editor.recordedShortcut == nil)
    #expect(context.editor.recordedSearchPaletteShortcut == nil)
    #expect(context.editor.searchPaletteConflictMessage == nil)
}

@Test @MainActor
func phasedUpEdgeAfterTheDownEdgeEndedTheSessionIsHarmless() {
    // The real wiring ends the session on the rerouted down edge, so the
    // matching up edge arrives with the gate already off and flows to the
    // arbiter as an unmatched release — no dispatch, no crash.
    let context = makeContext(shortcuts: [safariShortcut(holdAction: .windowPicker)])
    context.manager.onRecordingSessionKeyPress = { [weak editor = context.editor] in
        editor?.handleRecordingSessionKeyPress($0)
    }

    context.editor.isRecordingShortcut = true
    context.standardProvider.emitPhased(safariKeyPress(), .down)
    #expect(!context.editor.isRecordingShortcut)

    context.standardProvider.emitPhased(safariKeyPress(), .up)

    #expect(context.editor.recordedShortcut == RecordedShortcut(keyEquivalent: "s", modifierFlags: ["shift", "command"]))
    #expect(context.appSwitcher.toggledBundleIdentifiers.isEmpty)
}

// MARK: - KeyPress → RecordedShortcut conversion

@Test @MainActor
func keyPressConversionPreservesHyperIdentityAndRecorderModifierOrder() {
    let recorded = RecordedShortcut(keyPress: KeyPress(
        keyCode: UInt16(kVK_ANSI_F),
        modifiers: [.command, .shift, .option, .control]
    ))

    #expect(recorded == RecordedShortcut(keyEquivalent: "f", modifierFlags: ["control", "option", "shift", "command"]))
    #expect(recorded?.isHyper == true)
}

@Test @MainActor
func keyPressConversionRejectsUnmappableAndModifierlessPresses() {
    #expect(RecordedShortcut(keyPress: KeyPress(keyCode: 0xFFFF, modifiers: [.command])) == nil)
    #expect(RecordedShortcut(keyPress: KeyPress(keyCode: UInt16(kVK_ANSI_F), modifiers: [])) == nil)
}

@Test @MainActor
func keyPressConversionCarriesTheFunctionModifierForFnFRowChords() {
    let recorded = RecordedShortcut(keyPress: KeyPress(keyCode: UInt16(kVK_F5), modifiers: [.function]))

    #expect(recorded?.modifierFlags == ["function"])
}

// MARK: - Editor wiring: the recording flags drive the gate

@Test @MainActor
func editorComposerRecordingFlagDrivesTheDispatchGate() {
    let context = makeContext(shortcuts: [safariShortcut()])

    context.editor.isRecordingShortcut = true
    context.standardProvider.emit(safariKeyPress())
    #expect(context.appSwitcher.toggledBundleIdentifiers.isEmpty)

    context.editor.isRecordingShortcut = false
    context.standardProvider.emit(safariKeyPress())
    #expect(context.appSwitcher.toggledBundleIdentifiers == ["com.apple.Safari"])
}

@Test @MainActor
func editorPaletteRecordingFlagDrivesTheDispatchGate() {
    let context = makeContext(shortcuts: [safariShortcut()])

    context.editor.isRecordingSearchPaletteShortcut = true
    context.standardProvider.emit(safariKeyPress())
    #expect(context.appSwitcher.toggledBundleIdentifiers.isEmpty)

    context.editor.isRecordingSearchPaletteShortcut = false
    context.standardProvider.emit(safariKeyPress())
    #expect(context.appSwitcher.toggledBundleIdentifiers == ["com.apple.Safari"])
}

@Test @MainActor
func gateHoldsUntilBothRecordersHaveEnded() {
    // Both recorders live at once cannot happen through the UI, but the OR
    // in syncRecordingSessionGate must still hold: ending one session while
    // the other is live may not unlatch the gate.
    let context = makeContext(shortcuts: [safariShortcut()])

    context.editor.isRecordingShortcut = true
    context.editor.isRecordingSearchPaletteShortcut = true
    context.editor.isRecordingShortcut = false

    context.standardProvider.emit(safariKeyPress())
    #expect(context.appSwitcher.toggledBundleIdentifiers.isEmpty)

    context.editor.isRecordingSearchPaletteShortcut = false
    context.standardProvider.emit(safariKeyPress())
    #expect(context.appSwitcher.toggledBundleIdentifiers == ["com.apple.Safari"])
}
