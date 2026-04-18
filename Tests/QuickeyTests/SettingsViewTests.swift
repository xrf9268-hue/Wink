import Foundation
import ServiceManagement
import Testing
@testable import Quickey

@Test @MainActor
func handleAppearRefreshesPermissionsAndLaunchAtLoginStatusFromLiveServiceState() {
    let permissionState = MutablePermissionState(ax: false, input: false)
    let launchAtLoginState = MutableLaunchAtLoginState(status: .notRegistered)
    let preferences = makePreferences(
        permissionState: permissionState,
        launchAtLoginState: launchAtLoginState
    )

    #expect(preferences.shortcutCaptureStatus == ShortcutCaptureStatus(
        accessibilityGranted: false,
        inputMonitoringGranted: false,
        carbonHotKeysRegistered: false,
        eventTapActive: false,
        standardShortcutsReady: false,
        hyperShortcutsReady: false
    ))
    #expect(preferences.launchAtLoginStatus == .disabled)

    permissionState.ax = true
    permissionState.input = true
    launchAtLoginState.statusValue = .requiresApproval

    SettingsViewLifecycleHandler(preferences: preferences).handleAppear()

    #expect(preferences.shortcutCaptureStatus == ShortcutCaptureStatus(
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        carbonHotKeysRegistered: false,
        eventTapActive: false,
        standardShortcutsReady: true,
        hyperShortcutsReady: true
    ))
    #expect(preferences.launchAtLoginStatus == .requiresApproval)
}

@Test @MainActor
func handleAppDidBecomeActiveRefreshesShortcutCaptureAndLaunchAtLoginStatus() {
    let permissionState = MutablePermissionState(ax: false, input: false)
    let launchAtLoginState = MutableLaunchAtLoginState(status: .requiresApproval)
    let preferences = makePreferences(
        permissionState: permissionState,
        launchAtLoginState: launchAtLoginState
    )

    permissionState.ax = true
    permissionState.input = true
    launchAtLoginState.statusValue = .enabled

    SettingsViewLifecycleHandler(preferences: preferences).handleAppDidBecomeActive()

    #expect(preferences.shortcutCaptureStatus == ShortcutCaptureStatus(
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        carbonHotKeysRegistered: false,
        eventTapActive: false,
        standardShortcutsReady: true,
        hyperShortcutsReady: true
    ))
    #expect(preferences.launchAtLoginStatus == .enabled)
}

@Test @MainActor
func settingsLifecycleLeavesUpdatePresentationAvailable() {
    let permissionState = MutablePermissionState(ax: true, input: true)
    let launchAtLoginState = MutableLaunchAtLoginState(status: .enabled)
    let updateService = FakeUpdateService(
        canCheckForUpdates: true,
        currentVersion: "0.3.0",
        automaticallyChecksForUpdates: true,
        automaticallyDownloadsUpdates: true
    )
    let preferences = makePreferences(
        permissionState: permissionState,
        launchAtLoginState: launchAtLoginState,
        updateService: updateService
    )

    SettingsViewLifecycleHandler(preferences: preferences).handleAppear()

    let presentation = preferences.updatePresentation
    #expect(presentation.currentVersion == "0.3.0")
    #expect(presentation.checkForUpdatesEnabled == true)
}

@MainActor
private func makePreferences(
    permissionState: MutablePermissionState,
    launchAtLoginState: MutableLaunchAtLoginState,
    updateService: UpdateServicing? = nil
) -> AppPreferences {
    AppPreferences(
        shortcutManager: makeShortcutManager(
            permissionService: FakePermissionService(state: permissionState),
            captureCoordinator: makeCaptureCoordinator()
        ),
        launchAtLoginService: LaunchAtLoginService(client: .init(
            status: { launchAtLoginState.statusValue },
            register: {
                launchAtLoginState.statusValue = .enabled
            },
            unregister: {
                launchAtLoginState.statusValue = .notRegistered
            },
            openSystemSettingsLoginItems: {}
        )),
        updateService: updateService
    )
}

@MainActor
private func makeShortcutManager(
    permissionService: some PermissionServicing,
    captureCoordinator: ShortcutCaptureCoordinator,
    persistenceService: PersistenceService = TestPersistenceHarness().makePersistenceService()
) -> ShortcutManager {
    ShortcutManager(
        shortcutStore: ShortcutStore(),
        persistenceService: persistenceService,
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: captureCoordinator,
        permissionService: permissionService,
        diagnosticClient: .live
    )
}

@MainActor
private func makeCaptureCoordinator() -> ShortcutCaptureCoordinator {
    ShortcutCaptureCoordinator(
        standardProvider: FakeCaptureProvider(),
        hyperProvider: FakeHyperCaptureProvider()
    )
}

private final class MutablePermissionState: @unchecked Sendable {
    var ax: Bool
    var input: Bool

    init(ax: Bool, input: Bool) {
        self.ax = ax
        self.input = input
    }
}

private struct FakePermissionService: PermissionServicing {
    let state: MutablePermissionState

    func isTrusted() -> Bool {
        state.ax && state.input
    }

    func isAccessibilityTrusted() -> Bool {
        state.ax
    }

    func isInputMonitoringTrusted() -> Bool {
        state.input
    }

    @discardableResult
    func requestIfNeeded(prompt: Bool, inputMonitoringRequired: Bool) -> Bool {
        state.ax && (!inputMonitoringRequired || state.input)
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

    func start(onKeyPress: @escaping @MainActor @Sendable (Quickey.KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<Quickey.KeyPress>) {}
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

    func start(onKeyPress: @escaping @MainActor @Sendable (Quickey.KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<Quickey.KeyPress>) {}

    func setHyperKeyEnabled(_ enabled: Bool) {}
}

@MainActor
private struct FakeAppSwitcher: AppSwitching {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        true
    }
}

@MainActor
private final class FakeUpdateService: UpdateServicing {
    var canCheckForUpdates: Bool
    var currentVersion: String
    var automaticallyChecksForUpdates: Bool
    var automaticallyDownloadsUpdates: Bool

    init(
        canCheckForUpdates: Bool,
        currentVersion: String,
        automaticallyChecksForUpdates: Bool,
        automaticallyDownloadsUpdates: Bool
    ) {
        self.canCheckForUpdates = canCheckForUpdates
        self.currentVersion = currentVersion
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
    }

    func checkForUpdates() {}
}

private final class MutableLaunchAtLoginState: @unchecked Sendable {
    var status: SMAppService.Status

    init(status: SMAppService.Status) {
        self.status = status
    }
}

private extension MutableLaunchAtLoginState {
    var statusValue: SMAppService.Status {
        get { status }
        set { status = newValue }
    }
}
