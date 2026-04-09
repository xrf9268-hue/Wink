import Foundation
import ServiceManagement
import Testing
@testable import Quickey

@Test @MainActor
func initSnapshotsShortcutAndLaunchAtLoginState() {
    let suiteName = "AppPreferencesTests.initSnapshotsShortcutAndLaunchAtLoginState"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "hyperKeyEnabled")

    let preferences = AppPreferences(
        shortcutManager: makeShortcutManager(
            permissionService: FakePermissionService(ax: true, input: false),
            captureCoordinator: makeCaptureCoordinator()
        ),
        hyperKeyService: HyperKeyService(runner: { _ in true }, defaults: defaults),
        launchAtLoginService: makeLaunchAtLoginService(state: MutableLaunchAtLoginState(status: .requiresApproval))
    )

    #expect(preferences.shortcutCaptureStatus == ShortcutCaptureStatus(
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        carbonHotKeysRegistered: false,
        eventTapActive: false,
        standardShortcutsReady: true,
        hyperShortcutsReady: true
    ))
    #expect(preferences.launchAtLoginStatus == .requiresApproval)
    #expect(preferences.launchAtLoginEnabled == false)
    #expect(preferences.hyperKeyEnabled == true)
}

@Test @MainActor
func setLaunchAtLoginDoesNotUpdateStateWhenRegistrationFails() {
    let state = MutableLaunchAtLoginState(status: .notRegistered)
    state.registerError = TestError.registerFailed
    let preferences = AppPreferences(
        shortcutManager: makeShortcutManager(
            permissionService: FakePermissionService(ax: true, input: true),
            captureCoordinator: makeCaptureCoordinator()
        ),
        launchAtLoginService: makeLaunchAtLoginService(state: state)
    )

    preferences.setLaunchAtLogin(true)

    #expect(preferences.launchAtLoginStatus == .disabled)
    #expect(preferences.launchAtLoginEnabled == false)
}

@Test @MainActor
func setHyperKeyEnabledTracksActualServiceStateAfterFailure() {
    let suiteName = "AppPreferencesTests.setHyperKeyEnabledTracksActualServiceStateAfterFailure"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let preferences = AppPreferences(
        shortcutManager: makeShortcutManager(
            permissionService: FakePermissionService(ax: true, input: true),
            captureCoordinator: makeCaptureCoordinator()
        ),
        hyperKeyService: HyperKeyService(runner: { _ in false }, defaults: defaults)
    )

    preferences.setHyperKeyEnabled(true)

    #expect(preferences.hyperKeyEnabled == false)
}

@Test @MainActor
func LaunchAtLoginPresentation_enabledMapsToInteractiveOnToggleWithoutMessage() {
    let preferences = makePreferences(status: .enabled)

    let presentation = preferences.launchAtLoginPresentation
    #expect(presentation.toggleIsOn == true)
    #expect(presentation.toggleIsEnabled == true)
    #expect(presentation.messageStyle == .none)
    #expect(presentation.message == nil)
    #expect(presentation.showsOpenSettingsButton == false)
}

@Test @MainActor
func LaunchAtLoginPresentation_disabledMapsFromNotRegisteredToInteractiveOffToggleWithoutMessage() {
    let preferences = makePreferences(status: .notRegistered)

    #expect(preferences.launchAtLoginStatus == .disabled)
    let presentation = preferences.launchAtLoginPresentation
    #expect(presentation.toggleIsOn == false)
    #expect(presentation.toggleIsEnabled == true)
    #expect(presentation.messageStyle == .none)
    #expect(presentation.message == nil)
    #expect(presentation.showsOpenSettingsButton == false)
}

@Test @MainActor
func LaunchAtLoginPresentation_requiresApprovalMapsToInformationalStateWithOpenSettingsCTA() {
    let preferences = makePreferences(status: .requiresApproval)

    #expect(preferences.launchAtLoginStatus == .requiresApproval)
    #expect(preferences.launchAtLoginEnabled == false)
    let presentation = preferences.launchAtLoginPresentation
    #expect(presentation.toggleIsOn == true)
    #expect(presentation.toggleIsEnabled == true)
    #expect(presentation.messageStyle == .informational)
    #expect(presentation.message == "Quickey is registered to launch at login, but macOS still needs your approval in Login Items.")
    #expect(presentation.showsOpenSettingsButton == true)
}

@Test @MainActor
func LaunchAtLoginPresentation_notFoundMapsToDisabledErrorStateWithoutOpenSettingsCTA() {
    let preferences = makePreferences(
        status: .notFound,
        bundleURL: URL(fileURLWithPath: "/Applications/Quickey.app")
    )

    let presentation = preferences.launchAtLoginPresentation
    #expect(presentation.toggleIsOn == false)
    #expect(presentation.toggleIsEnabled == false)
    #expect(presentation.messageStyle == .error)
    #expect(presentation.message == "Quickey couldn't find its login item configuration. This usually points to an installation or packaging problem.")
    #expect(presentation.showsOpenSettingsButton == false)
}

@Test @MainActor
func LaunchAtLoginPresentation_notFoundOutsideApplicationsShowsInstallGuidance() {
    let preferences = makePreferences(
        status: .notFound,
        bundleURL: URL(fileURLWithPath: "/Users/yvan/developer/Quickey/build/Quickey.app")
    )

    let presentation = preferences.launchAtLoginPresentation
    #expect(presentation.toggleIsOn == false)
    #expect(presentation.toggleIsEnabled == false)
    #expect(presentation.messageStyle == .informational)
    #expect(presentation.message == "Launch at Login is only available after installing Quickey.app in the Applications folder and reopening it.")
    #expect(presentation.showsOpenSettingsButton == false)
}

@Test @MainActor
func LaunchAtLoginPresentation_openLoginItemsSettingsDelegatesToService() {
    let recorder = OpenSettingsRecorder()
    let preferences = makePreferences(
        status: .enabled,
        openSystemSettingsLoginItems: { recorder.didOpenSettings = true }
    )

    preferences.openLoginItemsSettings()

    #expect(recorder.didOpenSettings == true)
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
    func requestIfNeeded(prompt: Bool) -> Bool {
        isTrusted()
    }
}

@MainActor
private final class FakeCaptureProvider: ShortcutCaptureProvider {
    var isRunning = false

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

@MainActor
private func makeShortcutManager(
    permissionService: some PermissionServicing,
    captureCoordinator: ShortcutCaptureCoordinator
) -> ShortcutManager {
    ShortcutManager(
        shortcutStore: ShortcutStore(),
        persistenceService: PersistenceService(),
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

private enum TestError: Error {
    case registerFailed
    case unregisterFailed
}

private final class OpenSettingsRecorder: @unchecked Sendable {
    var didOpenSettings = false
}

private final class MutableLaunchAtLoginState: @unchecked Sendable {
    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?

    init(status: SMAppService.Status) {
        self.status = status
    }
}

private func makeLaunchAtLoginService(state: MutableLaunchAtLoginState) -> LaunchAtLoginService {
    LaunchAtLoginService(client: .init(
        status: { state.statusValue },
        register: {
            if let registerError = state.registerError {
                throw registerError
            }
            state.statusValue = .enabled
        },
        unregister: {
            if let unregisterError = state.unregisterError {
                throw unregisterError
            }
            state.statusValue = .notRegistered
        },
        openSystemSettingsLoginItems: {},
        bundleURL: { URL(fileURLWithPath: "/Applications/Quickey.app") },
        applicationDirectories: {
            [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true),
            ]
        }
    ))
}

@MainActor
private func makePreferences(
    status: SMAppService.Status = .notRegistered,
    state: MutableLaunchAtLoginState? = nil,
    openSystemSettingsLoginItems: @escaping @Sendable () -> Void = {},
    bundleURL: URL = URL(fileURLWithPath: "/Applications/Quickey.app")
) -> AppPreferences {
    let launchAtLoginState = state ?? MutableLaunchAtLoginState(status: status)
    return AppPreferences(
        shortcutManager: makeShortcutManager(
            permissionService: FakePermissionService(ax: true, input: true),
            captureCoordinator: makeCaptureCoordinator()
        ),
        launchAtLoginService: LaunchAtLoginService(client: .init(
            status: { launchAtLoginState.statusValue },
            register: {
                if let registerError = launchAtLoginState.registerError {
                    throw registerError
                }
                launchAtLoginState.statusValue = .enabled
            },
            unregister: {
                if let unregisterError = launchAtLoginState.unregisterError {
                    throw unregisterError
                }
                launchAtLoginState.statusValue = .notRegistered
            },
            openSystemSettingsLoginItems: openSystemSettingsLoginItems,
            bundleURL: { bundleURL },
            applicationDirectories: {
                [
                    URL(fileURLWithPath: "/Applications", isDirectory: true),
                    URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true),
                ]
            }
        ))
    )
}

private extension MutableLaunchAtLoginState {
    var statusValue: SMAppService.Status {
        get { status }
        set { status = newValue }
    }
}
