import Carbon.HIToolbox
import Testing
@testable import Wink

@Suite("Pause all shortcuts")
struct PauseAllShortcutsTests {
    @Test @MainActor
    func pausingStopsStandardAndHyperCaptureAndMarksStatusPaused() {
        let standardProvider = FakeCaptureProvider()
        let hyperProvider = FakeHyperCaptureProvider()
        let coordinator = ShortcutCaptureCoordinator(
            standardProvider: standardProvider,
            hyperProvider: hyperProvider
        )
        let manager = ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: TestPersistenceHarness().makePersistenceService(),
            appSwitcher: FakeAppSwitcher(),
            captureCoordinator: coordinator,
            permissionService: FakePermissionService(ax: true, input: true),
            appBundleLocator: pauseAllShortcutsAppBundleLocator(),
            diagnosticClient: .live
        )
        let shortcuts = [standardShortcut(), hyperShortcut()]

        manager.save(shortcuts: shortcuts)
        manager.setHyperKeyEnabled(true)
        manager.start()
        manager.setShortcutsPaused(true)

        let status = manager.shortcutCaptureStatus()

        #expect(status.shortcutsPaused == true)
        #expect(status.standardShortcutsReady == false)
        #expect(status.hyperShortcutsReady == false)
        #expect(status.anyShortcutsReady == false)
        #expect(standardProvider.stopCallCount >= 1)
        #expect(hyperProvider.stopCallCount >= 1)
    }

    @Test @MainActor
    func unpausingRestartsConfiguredCaptureWithoutRewritingShortcuts() async {
        let standardProvider = FakeCaptureProvider()
        let hyperProvider = FakeHyperCaptureProvider()
        let coordinator = ShortcutCaptureCoordinator(
            standardProvider: standardProvider,
            hyperProvider: hyperProvider
        )
        let manager = ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: TestPersistenceHarness().makePersistenceService(),
            appSwitcher: FakeAppSwitcher(),
            captureCoordinator: coordinator,
            permissionService: FakePermissionService(ax: true, input: true),
            appBundleLocator: pauseAllShortcutsAppBundleLocator(),
            diagnosticClient: .live
        )
        let shortcuts = [standardShortcut(), hyperShortcut()]

        manager.save(shortcuts: shortcuts)
        manager.setHyperKeyEnabled(true)
        manager.start()
        manager.setShortcutsPaused(true)
        let startCallsBeforeResume = (standardProvider.startCallCount, hyperProvider.startCallCount)

        manager.setShortcutsPaused(false)
        await waitUntil("shortcut capture resumes after unpausing") {
            standardProvider.isRunning
                && hyperProvider.isRunning
                && standardProvider.startCallCount > startCallsBeforeResume.0
                && hyperProvider.startCallCount > startCallsBeforeResume.1
        }

        let status = manager.shortcutCaptureStatus()

        #expect(status.shortcutsPaused == false)
        #expect(status.standardShortcutsReady == true)
        #expect(status.hyperShortcutsReady == true)
        #expect(standardProvider.isRunning == true)
        #expect(hyperProvider.isRunning == true)
        #expect(standardProvider.startCallCount > startCallsBeforeResume.0)
        #expect(hyperProvider.startCallCount > startCallsBeforeResume.1)
    }
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
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var registeredShortcuts: Set<KeyPress> = []

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: registeredShortcuts.count,
            registeredShortcutCount: isRunning ? registeredShortcuts.count : 0,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        startCallCount += 1
        isRunning = !registeredShortcuts.isEmpty
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {
        registeredShortcuts = keyPresses
        if keyPresses.isEmpty {
            isRunning = false
        }
    }
}

@MainActor
private final class FakeHyperCaptureProvider: HyperShortcutCaptureProvider {
    var isRunning = false
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var registeredShortcuts: Set<KeyPress> = []

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: registeredShortcuts.count,
            registeredShortcutCount: isRunning ? registeredShortcuts.count : 0,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        startCallCount += 1
        isRunning = !registeredShortcuts.isEmpty
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {
        registeredShortcuts = keyPresses
        if keyPresses.isEmpty {
            isRunning = false
        }
    }

    func setHyperKeyEnabled(_ enabled: Bool) {}
}

@MainActor
private struct FakeAppSwitcher: AppSwitching {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        true
    }
}

private func standardShortcut() -> AppShortcut {
    AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )
}

private func hyperShortcut() -> AppShortcut {
    AppShortcut(
        appName: "IINA",
        bundleIdentifier: "com.colliderli.iina",
        keyEquivalent: "i",
        modifierFlags: ["command", "option", "control", "shift"]
    )
}

private func pauseAllShortcutsAppBundleLocator() -> AppBundleLocator {
    TestAppBundleLocator(entries: [
        "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app"),
        "com.colliderli.iina": URL(fileURLWithPath: "/Applications/IINA.app")
    ]).locator
}

@MainActor
private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(20),
    condition: @escaping @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline {
            Issue.record("Timed out waiting for: \(description)")
            return
        }
        try? await Task.sleep(for: pollInterval)
    }
}
