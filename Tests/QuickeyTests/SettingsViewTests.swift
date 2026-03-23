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
        eventTapActive: false
    ))
    #expect(preferences.launchAtLoginStatus == .disabled)

    permissionState.ax = true
    permissionState.input = true
    launchAtLoginState.statusValue = .requiresApproval

    SettingsViewLifecycleHandler(preferences: preferences).handleAppear()

    #expect(preferences.shortcutCaptureStatus == ShortcutCaptureStatus(
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        eventTapActive: false
    ))
    #expect(preferences.launchAtLoginStatus == .requiresApproval)
}

@Test @MainActor
func handleAppDidBecomeActiveRefreshesOnlyLaunchAtLoginStatus() {
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
        accessibilityGranted: false,
        inputMonitoringGranted: false,
        eventTapActive: false
    ))
    #expect(preferences.launchAtLoginStatus == .enabled)
}

@MainActor
private func makePreferences(
    permissionState: MutablePermissionState,
    launchAtLoginState: MutableLaunchAtLoginState
) -> AppPreferences {
    AppPreferences(
        shortcutManager: makeShortcutManager(
            permissionService: FakePermissionService(state: permissionState),
            eventTapManager: FakeEventTapManager()
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
        ))
    )
}

@MainActor
private func makeShortcutManager(
    permissionService: some PermissionServicing,
    eventTapManager: some EventTapManaging
) -> ShortcutManager {
    ShortcutManager(
        shortcutStore: ShortcutStore(),
        persistenceService: PersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        eventTapManager: eventTapManager,
        permissionService: permissionService
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
    func requestIfNeeded(prompt: Bool) -> Bool {
        isTrusted()
    }
}

@MainActor
private final class FakeEventTapManager: EventTapManaging {
    var isRunning = false

    func start(onKeyPress: @escaping (Quickey.KeyPress) -> Bool) -> EventTapStartResult {
        isRunning = true
        return .started
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
