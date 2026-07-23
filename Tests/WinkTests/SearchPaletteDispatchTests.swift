import Carbon.HIToolbox
import Foundation
import Testing
@testable import Wink

// MARK: - Local fakes (mirrors the ShortcutManagerStatusTests harness shape,
// kept file-local per this suite's established per-file-fakes convention)

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
    /// Records every `setHyperReleaseDeferralSuppressed` call in order, so
    /// tests can assert both the values and the transition sequence.
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

/// Records every `toggleApplication` call so dispatch tests can assert the
/// search-palette match never reaches `AppSwitcher` (it has no real app to
/// toggle — see `ShortcutManager.handleKeyPress`).
@MainActor
private final class RecordingAppSwitcher: AppSwitching {
    private(set) var toggledBundleIdentifiers: [String] = []
    private(set) var bypassCooldownFlags: [Bool] = []

    @discardableResult
    func toggleApplication(for shortcut: AppShortcut, bypassCooldown: Bool) -> Bool {
        toggledBundleIdentifiers.append(shortcut.bundleIdentifier)
        bypassCooldownFlags.append(bypassCooldown)
        return true
    }
}

private func searchPaletteTriggerShortcut() -> AppShortcut {
    AppShortcut(
        appName: AppShortcut.searchPaletteTargetStableName,
        bundleIdentifier: AppShortcut.searchPaletteTargetSentinelBundleIdentifier,
        keyEquivalent: "space",
        modifierFlags: ["command", "option"],
        target: .searchPalette
    )
}

private func searchPaletteTriggerKeyPress() -> KeyPress {
    KeyPress(keyCode: UInt16(kVK_Space), modifiers: [.command, .option])
}

private func realAppShortcut() -> AppShortcut {
    AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )
}

private func realAppShortcutKeyPress() -> KeyPress {
    KeyPress(keyCode: UInt16(kVK_ANSI_S), modifiers: [.command, .shift])
}

@MainActor
private func makeContext(
    shortcuts: [AppShortcut]
) -> (
    manager: ShortcutManager,
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
    return (manager, appSwitcher, standardProvider, hyperProvider)
}

// MARK: - Dispatch branch

@Test @MainActor
func searchPaletteTriggerFiresTheDedicatedCallbackInsteadOfTogglingAnApp() throws {
    let context = makeContext(shortcuts: [searchPaletteTriggerShortcut()])
    var firedCount = 0
    context.manager.onSearchPaletteTriggered = {
        firedCount += 1
    }

    context.standardProvider.emit(searchPaletteTriggerKeyPress())

    #expect(firedCount == 1)
    #expect(context.appSwitcher.toggledBundleIdentifiers.isEmpty)
}

@Test @MainActor
func realAppShortcutsStillDispatchThroughAppSwitcherAndNeverFireThePaletteCallback() throws {
    let context = makeContext(shortcuts: [realAppShortcut()])
    var firedCount = 0
    context.manager.onSearchPaletteTriggered = {
        firedCount += 1
    }

    context.standardProvider.emit(realAppShortcutKeyPress())

    #expect(firedCount == 0)
    #expect(context.appSwitcher.toggledBundleIdentifiers == ["com.apple.Safari"])
}

@Test @MainActor
func searchPaletteTriggerRegistersWithoutAnInstalledAppLikeTheFrontmostPseudoTarget() throws {
    let context = makeContext(shortcuts: [searchPaletteTriggerShortcut()])
    #expect(context.standardProvider.registeredShortcuts == [searchPaletteTriggerKeyPress()])
}

// MARK: - Session-gate interplay (#352's shared interactivePanelSessionActive)

@Test @MainActor
func searchPaletteTriggerIsSwallowedWhileAnInteractivePanelSessionIsActive() throws {
    let context = makeContext(shortcuts: [searchPaletteTriggerShortcut()])
    var firedCount = 0
    context.manager.onSearchPaletteTriggered = {
        firedCount += 1
    }

    // Simulates the window picker being open (#352's gate — AppController
    // wires WindowPickerHUDController's onSessionStateChange the same way).
    context.manager.setInteractivePanelSessionActive(true)
    context.standardProvider.emit(searchPaletteTriggerKeyPress())

    #expect(firedCount == 0)
    #expect(context.appSwitcher.toggledBundleIdentifiers.isEmpty)
}

@Test @MainActor
func regularShortcutDispatchIsSwallowedWhileTheSearchPaletteItselfIsTheActiveSession() throws {
    let context = makeContext(shortcuts: [realAppShortcut()])

    // Simulates AppController's searchPaletteHUD.onSessionStateChange firing
    // true while the palette is key — proves the mutual exclusion holds in
    // both directions through the one shared flag.
    context.manager.setInteractivePanelSessionActive(true)
    context.standardProvider.emit(realAppShortcutKeyPress())

    #expect(context.appSwitcher.toggledBundleIdentifiers.isEmpty)
}

@Test @MainActor
func dispatchResumesOnceTheInteractivePanelSessionEnds() throws {
    let context = makeContext(shortcuts: [searchPaletteTriggerShortcut()])
    var firedCount = 0
    context.manager.onSearchPaletteTriggered = {
        firedCount += 1
    }

    context.manager.setInteractivePanelSessionActive(true)
    context.standardProvider.emit(searchPaletteTriggerKeyPress())
    #expect(firedCount == 0)

    context.manager.setInteractivePanelSessionActive(false)
    context.standardProvider.emit(searchPaletteTriggerKeyPress())
    #expect(firedCount == 1)
}

// MARK: - #385: session-scoped Hyper release-deferral suppression dispatch

@Test @MainActor
func openingTheInteractivePanelSessionSuppressesTheHyperProvidersReleaseDeferral() throws {
    let context = makeContext(shortcuts: [searchPaletteTriggerShortcut()])

    // Proves the dispatch path from ShortcutManager through
    // ShortcutCaptureCoordinator reaches the hyper provider's
    // setHyperReleaseDeferralSuppressed(true) through the protocol type
    // (dynamic dispatch via `any HyperShortcutCaptureProvider`), not a
    // concrete EventTapCaptureProvider/EventTapManager reference.
    context.manager.setInteractivePanelSessionActive(true)

    #expect(context.hyperProvider.hyperReleaseDeferralSuppressionCalls == [true])
}

@Test @MainActor
func closingTheInteractivePanelSessionLiftsTheHyperProvidersReleaseDeferralSuppression() throws {
    let context = makeContext(shortcuts: [searchPaletteTriggerShortcut()])

    // Unlike a one-shot clear, suppression must be lifted on close too —
    // otherwise every session after the first would permanently disable the
    // toggle-quirk deferral. Both transitions reach the provider, in order.
    context.manager.setInteractivePanelSessionActive(true)
    context.manager.setInteractivePanelSessionActive(false)

    #expect(context.hyperProvider.hyperReleaseDeferralSuppressionCalls == [true, false])
}
