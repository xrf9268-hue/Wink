import Foundation
import ServiceManagement
import Testing
@testable import Wink

@Suite("Launch at login presentation")
struct LaunchAtLoginPresentationTests {
    @Test @MainActor
    func enabledMapsToInteractiveOnToggleWithoutMessage() {
        let preferences = makePreferences(status: .enabled)
        let presentation = preferences.launchAtLoginPresentation

        #expect(presentation.toggleIsOn == true)
        #expect(presentation.toggleIsEnabled == true)
        #expect(presentation.message == nil)
        #expect(presentation.showsOpenSettingsButton == false)
    }

    @Test @MainActor
    func requiresApprovalMapsToInformationalMessageAndOpenSettingsButton() {
        let preferences = makePreferences(status: .requiresApproval)
        let presentation = preferences.launchAtLoginPresentation

        #expect(presentation.toggleIsOn == true)
        #expect(presentation.toggleIsEnabled == true)
        #expect(presentation.messageStyle == .informational)
        #expect(presentation.message == "Wink is registered to launch at login, but macOS still needs your approval in Login Items.")
        #expect(presentation.showsOpenSettingsButton == true)
    }

    @Test @MainActor
    func notFoundOutsideApplicationsMapsToInstallGuidance() {
        let preferences = makePreferences(
            status: .notFound,
            bundleURL: URL(fileURLWithPath: "/tmp/Wink.app")
        )
        let presentation = preferences.launchAtLoginPresentation

        #expect(presentation.toggleIsOn == false)
        #expect(presentation.toggleIsEnabled == false)
        #expect(presentation.messageStyle == .informational)
        #expect(presentation.message == "Launch at Login is only available after installing Wink.app in the Applications folder and reopening it.")
    }

    @Test @MainActor
    func notFoundInApplicationsBeforeAnyAttemptPresentsLikeDisabled() {
        // Apple's DTS guidance: .notFound before any register() call is the
        // normal pre-registration baseline ("the system has never seen your
        // service"), not a defect. A correctly installed copy that the user
        // simply hasn't toggled on yet must not show a scary error.
        let preferences = makePreferences(status: .notFound)
        let presentation = preferences.launchAtLoginPresentation

        #expect(presentation.toggleIsOn == false)
        #expect(presentation.toggleIsEnabled == true)
        #expect(presentation.message == nil)
        #expect(presentation.messageStyle == .none)
    }

    @Test @MainActor
    func notFoundInApplicationsAfterAttemptMapsToConfigurationError() {
        // notFound *persisting after* an explicit register() attempt is the
        // genuine signal something is wrong with this install.
        let preferences = makePreferences(status: .notFound)
        preferences.setLaunchAtLogin(true)
        let presentation = preferences.launchAtLoginPresentation

        #expect(presentation.toggleIsOn == false)
        #expect(presentation.toggleIsEnabled == false)
        #expect(presentation.messageStyle == .error)
        #expect(presentation.message == "Wink couldn't find its login item configuration. This usually points to an installation or packaging problem.")
        #expect(presentation.showsOpenSettingsButton == false)
    }
}

@MainActor
private func makePreferences(
    status: SMAppService.Status,
    bundleURL: URL = URL(fileURLWithPath: "/Applications/Wink.app")
) -> AppPreferences {
    AppPreferences(
        shortcutManager: ShortcutManager(
            shortcutStore: ShortcutStore(),
            persistenceService: TestPersistenceHarness().makePersistenceService(),
            appSwitcher: FakeAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: FakeCaptureProvider(),
                hyperProvider: FakeHyperCaptureProvider()
            ),
            permissionService: FakePermissionService(ax: true, input: true),
            diagnosticClient: .live
        ),
        launchAtLoginService: LaunchAtLoginService(client: .init(
            status: { status },
            register: {},
            unregister: {},
            openSystemSettingsLoginItems: {},
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
            desiredShortcutCount: 0,
            registeredShortcutCount: 0,
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
            desiredShortcutCount: 0,
            registeredShortcutCount: 0,
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
