import Testing
@testable import Quickey

@Test @MainActor
func savingShortcutChangesInvokesConfigurationChangeHandler() {
    let shortcutStore = ShortcutStore()
    let shortcut = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "option", "control", "shift"]
    )
    shortcutStore.replaceAll(with: [shortcut])

    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: TestPersistenceHarness().makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: FakeCaptureProvider(),
            hyperProvider: FakeHyperCaptureProvider()
        ),
        permissionService: FakePermissionService(ax: true, input: false),
        diagnosticClient: .live
    )
    var callbackCount = 0
    let editor = ShortcutEditorState(
        shortcutStore: shortcutStore,
        shortcutManager: manager,
        onShortcutConfigurationChange: {
            callbackCount += 1
        }
    )

    editor.toggleShortcutEnabled(id: shortcut.id)
    editor.setAllEnabled(true)

    #expect(callbackCount == 2)
}

@Test @MainActor
func movingShortcutPersistsOrderAndInvokesConfigurationChangeHandler() throws {
    let shortcutStore = ShortcutStore()
    let safari = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )
    let terminal = AppShortcut(
        appName: "Terminal",
        bundleIdentifier: "com.apple.Terminal",
        keyEquivalent: "t",
        modifierFlags: ["command", "shift"]
    )
    let notes = AppShortcut(
        appName: "Notes",
        bundleIdentifier: "com.apple.Notes",
        keyEquivalent: "n",
        modifierFlags: ["command", "shift"]
    )
    shortcutStore.replaceAll(with: [safari, terminal, notes])

    let persistenceHarness = TestPersistenceHarness()
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: persistenceHarness.makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: FakeCaptureProvider(),
            hyperProvider: FakeHyperCaptureProvider()
        ),
        permissionService: FakePermissionService(ax: true, input: false),
        diagnosticClient: .live
    )
    var callbackCount = 0
    let editor = ShortcutEditorState(
        shortcutStore: shortcutStore,
        shortcutManager: manager,
        onShortcutConfigurationChange: {
            callbackCount += 1
        }
    )

    editor.moveShortcut(from: IndexSet(integer: 2), to: 0)

    #expect(editor.shortcuts.map(\.id) == [notes.id, safari.id, terminal.id])
    #expect(callbackCount == 1)

    let persisted = try persistenceHarness.makePersistenceService().load()
    #expect(persisted.map(\.id) == [notes.id, safari.id, terminal.id])
}

private struct FakePermissionService: PermissionServicing {
    let ax: Bool
    let input: Bool

    func isTrusted() -> Bool {
        ax && input
    }

    func isAccessibilityTrusted() -> Bool {
        ax
    }

    func isInputMonitoringTrusted() -> Bool {
        input
    }

    @discardableResult
    func requestIfNeeded(prompt: Bool, inputMonitoringRequired: Bool) -> Bool {
        ax && (!inputMonitoringRequired || input)
    }
}

@MainActor
private final class FakeCaptureProvider: ShortcutCaptureProvider {
    var isRunning = false

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: isRunning ? 1 : 0,
            registeredShortcutCount: isRunning ? 1 : 0,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {}
}

@MainActor
private final class FakeHyperCaptureProvider: HyperShortcutCaptureProvider {
    var isRunning = false

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: isRunning ? 1 : 0,
            registeredShortcutCount: isRunning ? 1 : 0,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {}

    func setHyperKeyEnabled(_ enabled: Bool) {}
}

@MainActor
private struct FakeAppSwitcher: AppSwitching {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        true
    }
}
