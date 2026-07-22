import Foundation
import ServiceManagement
import Testing
@testable import Wink

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
    #expect(preferences.launchAtLoginMutationFailure == LaunchAtLoginMutationFailure(
        mutation: .register,
        reason: TestError.registerFailed.localizedDescription
    ))
    let presentation = preferences.launchAtLoginPresentation
    #expect(presentation.toggleIsOn == false)
    #expect(presentation.toggleIsEnabled == true)
    #expect(presentation.messageStyle == .error)
    #expect(presentation.message == "Wink couldn't enable Launch at Login: register denied by policy. Try again, or manage it in System Settings › Login Items.")
    #expect(presentation.showsOpenSettingsButton == true)
}

@Test @MainActor
func setLaunchAtLoginSurfacesUnregisterFailureWhenUnregistrationFails() {
    let state = MutableLaunchAtLoginState(status: .enabled)
    state.unregisterError = TestError.unregisterFailed
    let preferences = makePreferences(state: state)

    preferences.setLaunchAtLogin(false)

    #expect(preferences.launchAtLoginStatus == .enabled)
    #expect(preferences.launchAtLoginEnabled == true)
    #expect(preferences.launchAtLoginMutationFailure == LaunchAtLoginMutationFailure(
        mutation: .unregister,
        reason: TestError.unregisterFailed.localizedDescription
    ))
    let presentation = preferences.launchAtLoginPresentation
    #expect(presentation.toggleIsOn == true)
    #expect(presentation.toggleIsEnabled == true)
    #expect(presentation.messageStyle == .error)
    #expect(presentation.message == "Wink couldn't disable Launch at Login: unregister denied by policy. Try again, or manage it in System Settings › Login Items.")
    #expect(presentation.showsOpenSettingsButton == true)
}

@Test @MainActor
func setLaunchAtLoginClearsRegisterFailureAfterSuccessfulRetry() {
    let state = MutableLaunchAtLoginState(status: .notRegistered)
    state.registerError = TestError.registerFailed
    let preferences = makePreferences(state: state)

    preferences.setLaunchAtLogin(true)
    #expect(preferences.launchAtLoginMutationFailure != nil)

    state.registerError = nil
    preferences.setLaunchAtLogin(true)

    #expect(preferences.launchAtLoginMutationFailure == nil)
    #expect(preferences.launchAtLoginStatus == .enabled)
    let presentation = preferences.launchAtLoginPresentation
    #expect(presentation.toggleIsOn == true)
    #expect(presentation.toggleIsEnabled == true)
    #expect(presentation.message == nil)
    #expect(presentation.messageStyle == .none)
    #expect(presentation.showsOpenSettingsButton == false)
}

@Test @MainActor
func setLaunchAtLoginClearsUnregisterFailureAfterSuccessfulRetry() {
    let state = MutableLaunchAtLoginState(status: .enabled)
    state.unregisterError = TestError.unregisterFailed
    let preferences = makePreferences(state: state)

    preferences.setLaunchAtLogin(false)
    #expect(preferences.launchAtLoginMutationFailure != nil)

    state.unregisterError = nil
    preferences.setLaunchAtLogin(false)

    #expect(preferences.launchAtLoginMutationFailure == nil)
    #expect(preferences.launchAtLoginStatus == .disabled)
    let presentation = preferences.launchAtLoginPresentation
    #expect(presentation.toggleIsOn == false)
    #expect(presentation.toggleIsEnabled == true)
    #expect(presentation.message == nil)
    #expect(presentation.messageStyle == .none)
    #expect(presentation.showsOpenSettingsButton == false)
}

@Test @MainActor
func refreshLaunchAtLoginStatusClearsStaleRegisterFailureWhenEnabledExternally() {
    let state = MutableLaunchAtLoginState(status: .notRegistered)
    state.registerError = TestError.registerFailed
    let preferences = makePreferences(state: state)

    preferences.setLaunchAtLogin(true)
    #expect(preferences.launchAtLoginMutationFailure != nil)

    // User fixes it in System Settings › Login Items.
    state.status = .enabled
    preferences.refreshLaunchAtLoginStatus()

    #expect(preferences.launchAtLoginMutationFailure == nil)
    #expect(preferences.launchAtLoginStatus == .enabled)
    let presentation = preferences.launchAtLoginPresentation
    #expect(presentation.toggleIsOn == true)
    #expect(presentation.message == nil)
    #expect(presentation.messageStyle == .none)
    #expect(presentation.showsOpenSettingsButton == false)
}

@Test @MainActor
func launchAtLoginMutationFailureDoesNotOverrideRequiresApprovalPresentation() {
    // A failed unregister that leaves the service awaiting approval keeps
    // the failure recorded, but the .requiresApproval branch retains its
    // more specific informational copy.
    let state = MutableLaunchAtLoginState(status: .requiresApproval)
    state.unregisterError = TestError.unregisterFailed
    let preferences = makePreferences(state: state)

    preferences.setLaunchAtLogin(false)

    #expect(preferences.launchAtLoginStatus == .requiresApproval)
    #expect(preferences.launchAtLoginMutationFailure == LaunchAtLoginMutationFailure(
        mutation: .unregister,
        reason: TestError.unregisterFailed.localizedDescription
    ))
    let presentation = preferences.launchAtLoginPresentation
    #expect(presentation.toggleIsOn == true)
    #expect(presentation.toggleIsEnabled == true)
    #expect(presentation.messageStyle == .informational)
    #expect(presentation.message == "Wink is registered to launch at login, but macOS still needs your approval in Login Items.")
    #expect(presentation.showsOpenSettingsButton == true)
}

@Test @MainActor
func launchAtLoginMutationFailureDoesNotOverrideNotFoundPresentations() {
    // In Applications: the post-attempt configuration-error copy wins.
    let missingConfigurationState = MutableLaunchAtLoginState(status: .notFound)
    missingConfigurationState.registerError = TestError.registerFailed
    let inApplications = makePreferences(state: missingConfigurationState)

    inApplications.setLaunchAtLogin(true)

    #expect(inApplications.launchAtLoginMutationFailure != nil)
    let configurationPresentation = inApplications.launchAtLoginPresentation
    #expect(configurationPresentation.toggleIsOn == false)
    #expect(configurationPresentation.toggleIsEnabled == false)
    #expect(configurationPresentation.messageStyle == .error)
    #expect(configurationPresentation.message == "Wink couldn't find its login item configuration. This usually points to an installation or packaging problem.")
    #expect(configurationPresentation.showsOpenSettingsButton == false)

    // Outside Applications: the install guidance copy wins.
    let outsideState = MutableLaunchAtLoginState(status: .notFound)
    outsideState.registerError = TestError.registerFailed
    let outsideApplications = makePreferences(
        state: outsideState,
        bundleURL: URL(fileURLWithPath: "/tmp/Wink.app")
    )

    outsideApplications.setLaunchAtLogin(true)

    #expect(outsideApplications.launchAtLoginMutationFailure != nil)
    let guidancePresentation = outsideApplications.launchAtLoginPresentation
    #expect(guidancePresentation.toggleIsOn == false)
    #expect(guidancePresentation.toggleIsEnabled == false)
    #expect(guidancePresentation.messageStyle == .informational)
    #expect(guidancePresentation.message == "Launch at Login is only available after installing Wink.app in the Applications folder and reopening it.")
    #expect(guidancePresentation.showsOpenSettingsButton == false)
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
func setHyperKeyEnabledRefreshesShortcutCaptureStatusForHyperRoutingChanges() throws {
    let suiteName = "AppPreferencesTests.setHyperKeyEnabledRefreshesShortcutCaptureStatusForHyperRoutingChanges"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let shortcutStore = ShortcutStore()
    shortcutStore.replaceAll(with: [
        AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command", "option", "control", "shift"]
        )
    ])
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: TestPersistenceHarness().makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: makeCaptureCoordinator(),
        permissionService: FakePermissionService(ax: true, input: false),
        diagnosticClient: .live
    )
    try manager.save(shortcuts: shortcutStore.shortcuts)

    let preferences = AppPreferences(
        shortcutManager: manager,
        hyperKeyService: HyperKeyService(runner: { _ in true }, defaults: defaults)
    )

    #expect(preferences.shortcutCaptureStatus.inputMonitoringRequired == false)
    #expect(preferences.shortcutCaptureStatus.hyperShortcutsReady == true)

    preferences.setHyperKeyEnabled(true)

    #expect(preferences.shortcutCaptureStatus.inputMonitoringRequired == true)
    #expect(preferences.shortcutCaptureStatus.hyperShortcutsReady == false)
}

@Test @MainActor
func frontmostTargetBehaviorDefaultsToTogglePersistsAndDelegatesToShortcutManager() {
    let suiteName = "AppPreferencesTests.frontmostTargetBehavior"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let appSwitcher = RecordingAppSwitcher()
    let manager = ShortcutManager(
        shortcutStore: ShortcutStore(),
        persistenceService: TestPersistenceHarness().makePersistenceService(),
        appSwitcher: appSwitcher,
        captureCoordinator: makeCaptureCoordinator(),
        permissionService: FakePermissionService(ax: true, input: true),
        diagnosticClient: .live
    )

    let preferences = AppPreferences(
        shortcutManager: manager,
        userDefaults: defaults
    )

    #expect(preferences.frontmostTargetBehavior == .toggle)
    #expect(appSwitcher.lastBehavior == .toggle)

    preferences.frontmostTargetBehavior = .focus

    #expect(appSwitcher.lastBehavior == .focus)
    #expect(defaults.string(forKey: AppPreferences.frontmostTargetBehaviorDefaultsKey) == FrontmostTargetBehavior.focus.rawValue)

    let reloaded = AppPreferences(
        shortcutManager: manager,
        userDefaults: defaults
    )

    #expect(reloaded.frontmostTargetBehavior == .focus)
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
    #expect(presentation.message == "Wink is registered to launch at login, but macOS still needs your approval in Login Items.")
    #expect(presentation.showsOpenSettingsButton == true)
}

@Test @MainActor
func LaunchAtLoginPresentation_notFoundBeforeAttemptPresentsLikeDisabled() {
    // .notFound before any register() call is Apple's documented normal
    // pre-registration baseline, not a defect — must not show an error.
    let preferences = makePreferences(
        status: .notFound,
        bundleURL: URL(fileURLWithPath: "/Applications/Wink.app")
    )

    let presentation = preferences.launchAtLoginPresentation
    #expect(presentation.toggleIsOn == false)
    #expect(presentation.toggleIsEnabled == true)
    #expect(presentation.message == nil)
    #expect(presentation.messageStyle == .none)
}

// The after-attempt-still-notFound error path is covered by
// LaunchAtLoginPresentationTests.notFoundInApplicationsAfterAttemptMapsToConfigurationError,
// which uses a fixed-status fake — this file's MutableLaunchAtLoginState
// fake always flips register() to .enabled, so it can't represent "register
// succeeded without throwing but status is still notFound."

@Test @MainActor
func LaunchAtLoginPresentation_notFoundOutsideApplicationsShowsInstallGuidance() {
    let preferences = makePreferences(
        status: .notFound,
        bundleURL: URL(fileURLWithPath: "/tmp/Wink.app")
    )

    let presentation = preferences.launchAtLoginPresentation
    #expect(presentation.toggleIsOn == false)
    #expect(presentation.toggleIsEnabled == false)
    #expect(presentation.messageStyle == .informational)
    #expect(presentation.message == "Launch at Login is only available after installing Wink.app in the Applications folder and reopening it.")
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

@Test @MainActor
func updatePresentation_exposesVersionAndEnablesManualChecksWhenServiceIsAvailable() {
    let service = FakeUpdateService(
        isConfigured: true,
        canCheckForUpdates: true,
        currentVersion: "0.3.0",
        automaticallyChecksForUpdates: true,
        automaticallyDownloadsUpdates: true
    )
    let preferences = makePreferences(updateService: service)

    let presentation = preferences.updatePresentation

    #expect(presentation.currentVersion == "0.3.0")
    #expect(presentation.isConfigured == true)
    #expect(presentation.checkForUpdatesEnabled == true)
    #expect(presentation.automaticChecksEnabled == true)
    #expect(presentation.automaticDownloadsEnabled == true)
}

@Test @MainActor
func updatePresentation_defaultsToDisabledChecksWithoutService() {
    let preferences = makePreferences()

    let presentation = preferences.updatePresentation

    #expect(presentation.isConfigured == false)
    #expect(presentation.checkForUpdatesEnabled == false)
    #expect(presentation.automaticChecksEnabled == true)
    #expect(presentation.automaticDownloadsEnabled == true)
}

@Test @MainActor
func setAutomaticUpdatesEnabled_writesBothUpdaterFlagsAndMirrorsState() {
    let service = FakeUpdateService(
        isConfigured: true,
        canCheckForUpdates: true,
        currentVersion: "0.3.0",
        automaticallyChecksForUpdates: true,
        automaticallyDownloadsUpdates: true
    )
    let preferences = makePreferences(updateService: service)
    #expect(preferences.automaticUpdatesEnabled == true)

    preferences.setAutomaticUpdatesEnabled(false)

    #expect(service.automaticallyChecksForUpdates == false)
    #expect(service.automaticallyDownloadsUpdates == false)
    #expect(preferences.automaticUpdatesEnabled == false)
    #expect(preferences.updatePresentation.automaticChecksEnabled == false)
    #expect(preferences.updatePresentation.automaticDownloadsEnabled == false)

    preferences.setAutomaticUpdatesEnabled(true)

    #expect(service.automaticallyChecksForUpdates == true)
    #expect(service.automaticallyDownloadsUpdates == true)
    #expect(preferences.automaticUpdatesEnabled == true)
}

@Test @MainActor
func automaticUpdatesEnabled_readsMixedExternalStateAsOffAndNormalizesOnToggle() {
    let service = FakeUpdateService(
        isConfigured: true,
        canCheckForUpdates: true,
        currentVersion: "0.3.0",
        automaticallyChecksForUpdates: true,
        automaticallyDownloadsUpdates: false
    )
    let preferences = makePreferences(updateService: service)

    #expect(preferences.automaticUpdatesEnabled == false)

    preferences.setAutomaticUpdatesEnabled(true)

    #expect(service.automaticallyChecksForUpdates == true)
    #expect(service.automaticallyDownloadsUpdates == true)
    #expect(preferences.automaticUpdatesEnabled == true)
}

@Test @MainActor
func setAutomaticUpdatesEnabled_isNoOpWithoutService() {
    let preferences = makePreferences()
    let initial = preferences.automaticUpdatesEnabled

    preferences.setAutomaticUpdatesEnabled(!initial)

    #expect(preferences.automaticUpdatesEnabled == initial)
}

@Test @MainActor
func updatePhase_mirrorsServiceStateChangesIntoObservableStorage() {
    let service = FakeUpdateService(
        isConfigured: true,
        canCheckForUpdates: true,
        currentVersion: "0.5.0",
        automaticallyChecksForUpdates: true,
        automaticallyDownloadsUpdates: true
    )
    let preferences = makePreferences(updateService: service)
    #expect(preferences.updatePhase == .idle)
    #expect(preferences.lastUpdateCheckDate == nil)

    let checkedAt = Date(timeIntervalSince1970: 1_750_000_000)
    service.simulateUpdateState(phase: .available(version: "0.6.0"), lastCheck: checkedAt)

    #expect(preferences.updatePhase == .available(version: "0.6.0"))
    #expect(preferences.lastUpdateCheckDate == checkedAt)

    service.simulateUpdateState(phase: .ready(version: "0.6.0"))
    #expect(preferences.updatePhase == .ready(version: "0.6.0"))

    service.simulateUpdateState(phase: .idle)
    #expect(preferences.updatePhase == .idle)
}

@Test @MainActor
func updatePresentation_checkForUpdatesEnabledFollowsConfigurationNotCanCheckSnapshot() {
    let service = FakeUpdateService(
        isConfigured: true,
        canCheckForUpdates: false,
        currentVersion: "0.5.0",
        automaticallyChecksForUpdates: true,
        automaticallyDownloadsUpdates: true
    )
    let preferences = makePreferences(updateService: service)

    // A session in flight makes canCheckForUpdates false, but the button
    // must stay enabled so a repeat click re-focuses the session.
    #expect(preferences.updatePresentation.checkForUpdatesEnabled == true)
}

@Test
func updatePhase_isActiveSessionCoversWorkingAndHeldStates() {
    #expect(UpdatePhase.checking.isActiveSession)
    #expect(UpdatePhase.available(version: "1.2").isActiveSession)
    #expect(UpdatePhase.downloading(version: "1.2", received: 1, expected: 2).isActiveSession)
    #expect(UpdatePhase.extracting(progress: 0.5).isActiveSession)
    #expect(UpdatePhase.ready(version: "1.2").isActiveSession)
    #expect(UpdatePhase.installing.isActiveSession)
    #expect(!UpdatePhase.idle.isActiveSession)
    #expect(!UpdatePhase.upToDate(checkedAt: Date(timeIntervalSince1970: 0)).isActiveSession)
    #expect(!UpdatePhase.error(message: "x").isActiveSession)
}

@Test @MainActor
func handleUpdatePanelCloseRequest_routesToPhaseAppropriateAction() {
    let service = FakeUpdateService(
        isConfigured: true,
        canCheckForUpdates: true,
        currentVersion: "0.5.0",
        automaticallyChecksForUpdates: true,
        automaticallyDownloadsUpdates: true
    )
    let preferences = makePreferences(updateService: service)

    service.simulateUpdateState(phase: .checking)
    preferences.handleUpdatePanelCloseRequest()
    #expect(service.recordedActions == ["cancel"])

    service.simulateUpdateState(phase: .available(version: "9.9"))
    preferences.handleUpdatePanelCloseRequest()
    #expect(service.recordedActions == ["cancel", "later"])

    service.simulateUpdateState(phase: .error(message: "offline"))
    preferences.handleUpdatePanelCloseRequest()
    #expect(service.recordedActions == ["cancel", "later", "acknowledge"])

    service.simulateUpdateState(phase: .idle)
    preferences.handleUpdatePanelCloseRequest()
    #expect(service.recordedActions == ["cancel", "later", "acknowledge"])
}

@Test @MainActor
func initRestoresPausedShortcutPreferenceIntoRuntimeStatus() throws {
    let suiteName = "AppPreferencesTests.initRestoresPausedShortcutPreferenceIntoRuntimeStatus"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: AppPreferences.shortcutsPausedDefaultsKey)

    let shortcutStore = ShortcutStore()
    shortcutStore.replaceAll(with: [
        AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command", "shift"]
        )
    ])
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: TestPersistenceHarness().makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: makeCaptureCoordinator(),
        permissionService: FakePermissionService(ax: true, input: true),
        diagnosticClient: .live
    )
    try manager.save(shortcuts: shortcutStore.shortcuts)

    let preferences = AppPreferences(
        shortcutManager: manager,
        userDefaults: defaults
    )

    #expect(preferences.shortcutsPaused == true)
    #expect(preferences.shortcutCaptureStatus.shortcutsPaused == true)
    #expect(preferences.shortcutCaptureStatus.anyShortcutsReady == false)
}

@Test @MainActor
func setShortcutsPausedPersistsPreferenceAfterRuntimeUpdate() throws {
    let suiteName = "AppPreferencesTests.setShortcutsPausedPersistsPreferenceAfterRuntimeUpdate"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)

    let shortcutStore = ShortcutStore()
    shortcutStore.replaceAll(with: [
        AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command", "shift"]
        )
    ])
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: TestPersistenceHarness().makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: makeCaptureCoordinator(),
        permissionService: FakePermissionService(ax: true, input: true),
        diagnosticClient: .live
    )
    try manager.save(shortcuts: shortcutStore.shortcuts)

    let preferences = AppPreferences(
        shortcutManager: manager,
        userDefaults: defaults
    )

    preferences.setShortcutsPaused(true)

    #expect(preferences.shortcutsPaused == true)
    #expect(preferences.shortcutCaptureStatus.shortcutsPaused == true)
    #expect(defaults.bool(forKey: AppPreferences.shortcutsPausedDefaultsKey) == true)
}

@Test @MainActor
func updatePresentation_checkForUpdatesDelegatesToService() {
    let service = FakeUpdateService(
        isConfigured: true,
        canCheckForUpdates: true,
        currentVersion: "0.3.0",
        automaticallyChecksForUpdates: true,
        automaticallyDownloadsUpdates: true
    )
    let preferences = makePreferences(updateService: service)

    preferences.checkForUpdates()

    #expect(service.didRequestManualCheck == true)
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
    func toggleApplication(for shortcut: AppShortcut, bypassCooldown: Bool) -> Bool {
        true
    }
}

@MainActor
private final class RecordingAppSwitcher: AppSwitching {
    private(set) var lastBehavior: FrontmostTargetBehavior?

    @discardableResult
    func toggleApplication(for shortcut: AppShortcut, bypassCooldown: Bool) -> Bool {
        true
    }

    func setFrontmostTargetBehavior(_ behavior: FrontmostTargetBehavior) {
        lastBehavior = behavior
    }
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

private enum TestError: LocalizedError {
    case registerFailed
    case unregisterFailed

    var errorDescription: String? {
        switch self {
        case .registerFailed: "register denied by policy"
        case .unregisterFailed: "unregister denied by policy"
        }
    }
}

private final class OpenSettingsRecorder: @unchecked Sendable {
    var didOpenSettings = false
}

@MainActor
private final class FakeUpdateService: UpdateServicing {
    let isConfigured: Bool
    let canCheckForUpdates: Bool
    let currentVersion: String
    var automaticallyChecksForUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
    private(set) var didRequestManualCheck = false
    private(set) var updatePhase: UpdatePhase = .idle
    private(set) var lastUpdateCheckDate: Date?
    var onUpdateStateChange: (@MainActor () -> Void)?

    init(
        isConfigured: Bool,
        canCheckForUpdates: Bool,
        currentVersion: String,
        automaticallyChecksForUpdates: Bool,
        automaticallyDownloadsUpdates: Bool
    ) {
        self.isConfigured = isConfigured
        self.canCheckForUpdates = canCheckForUpdates
        self.currentVersion = currentVersion
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
    }

    func checkForUpdates() {
        didRequestManualCheck = true
    }

    func simulateUpdateState(phase: UpdatePhase, lastCheck: Date? = nil) {
        updatePhase = phase
        if let lastCheck {
            lastUpdateCheckDate = lastCheck
        }
        onUpdateStateChange?()
    }

    private(set) var recordedActions: [String] = []

    func installUpdateNow() { recordedActions.append("install") }
    func remindUpdateLater() { recordedActions.append("later") }
    func skipUpdateVersion() { recordedActions.append("skip") }
    func cancelUpdateOperation() { recordedActions.append("cancel") }
    func acknowledgeUpdateResult() { recordedActions.append("acknowledge") }
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
        bundleURL: { URL(fileURLWithPath: "/Applications/Wink.app") },
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
    bundleURL: URL = URL(fileURLWithPath: "/Applications/Wink.app"),
    updateService: UpdateServicing? = nil
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
        )),
        updateService: updateService
    )
}

private extension MutableLaunchAtLoginState {
    var statusValue: SMAppService.Status {
        get { status }
        set { status = newValue }
    }
}
