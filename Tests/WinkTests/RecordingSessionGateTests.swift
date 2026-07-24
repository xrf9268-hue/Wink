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

private func safariShortcut() -> AppShortcut {
    AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
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
