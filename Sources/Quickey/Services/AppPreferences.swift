import Foundation
import Observation

enum LaunchAtLoginPresentationStyle: Equatable {
    case none
    case informational
    case error
}

struct LaunchAtLoginPresentation: Equatable {
    let toggleIsOn: Bool
    let toggleIsEnabled: Bool
    let message: String?
    let messageStyle: LaunchAtLoginPresentationStyle
    let showsOpenSettingsButton: Bool
}

@MainActor
@Observable
final class AppPreferences {
    private(set) var shortcutCaptureStatus: ShortcutCaptureStatus
    private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .disabled
    private(set) var launchAtLoginAvailability: LaunchAtLoginAvailability = .available
    var hyperKeyEnabled: Bool = false

    var launchAtLoginEnabled: Bool {
        launchAtLoginStatus.isEnabled
    }

    var updatePresentation: UpdatePresentation {
        UpdatePresentation(
            currentVersion: updateService?.currentVersion ?? Self.currentVersionString(),
            checkForUpdatesEnabled: updateService?.canCheckForUpdates ?? false,
            automaticChecksEnabledByDefault: updateService?.automaticallyChecksForUpdates ?? true,
            automaticDownloadsEnabledByDefault: updateService?.automaticallyDownloadsUpdates ?? true
        )
    }

    var launchAtLoginPresentation: LaunchAtLoginPresentation {
        switch launchAtLoginStatus {
        case .enabled:
            LaunchAtLoginPresentation(
                toggleIsOn: true,
                toggleIsEnabled: true,
                message: nil,
                messageStyle: .none,
                showsOpenSettingsButton: false
            )
        case .disabled:
            LaunchAtLoginPresentation(
                toggleIsOn: false,
                toggleIsEnabled: true,
                message: nil,
                messageStyle: .none,
                showsOpenSettingsButton: false
            )
        case .requiresApproval:
            LaunchAtLoginPresentation(
                toggleIsOn: true,
                toggleIsEnabled: true,
                message: "Quickey is registered to launch at login, but macOS still needs your approval in Login Items.",
                messageStyle: .informational,
                showsOpenSettingsButton: true
            )
        case .notFound:
            switch launchAtLoginAvailability {
            case .requiresAppInApplicationsFolder:
                LaunchAtLoginPresentation(
                    toggleIsOn: false,
                    toggleIsEnabled: false,
                    message: "Launch at Login is only available after installing Quickey.app in the Applications folder and reopening it.",
                    messageStyle: .informational,
                    showsOpenSettingsButton: false
                )
            case .available, .missingConfiguration:
                LaunchAtLoginPresentation(
                    toggleIsOn: false,
                    toggleIsEnabled: false,
                    message: "Quickey couldn't find its login item configuration. This usually points to an installation or packaging problem.",
                    messageStyle: .error,
                    showsOpenSettingsButton: false
                )
            }
        }
    }

    private let shortcutManager: ShortcutManager
    private let hyperKeyService: HyperKeyService?
    private let launchAtLoginService: LaunchAtLoginService
    private let updateService: UpdateServicing?

    init(
        shortcutManager: ShortcutManager,
        hyperKeyService: HyperKeyService? = nil,
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        updateService: UpdateServicing? = nil
    ) {
        self.shortcutManager = shortcutManager
        self.hyperKeyService = hyperKeyService
        self.launchAtLoginService = launchAtLoginService
        self.updateService = updateService
        self.shortcutCaptureStatus = shortcutManager.shortcutCaptureStatus()
        let launchAtLoginSnapshot = launchAtLoginService.snapshot
        self.launchAtLoginStatus = launchAtLoginSnapshot.status
        self.launchAtLoginAvailability = launchAtLoginSnapshot.availability
        self.hyperKeyEnabled = hyperKeyService?.isEnabled ?? false
    }

    func refreshPermissions() {
        let current = shortcutManager.shortcutCaptureStatus()
        if current != shortcutCaptureStatus {
            shortcutCaptureStatus = current
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginService.setEnabled(enabled)
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        let launchAtLoginSnapshot = launchAtLoginService.snapshot
        launchAtLoginStatus = launchAtLoginSnapshot.status
        launchAtLoginAvailability = launchAtLoginSnapshot.availability
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openSystemSettingsLoginItems()
    }

    func checkForUpdates() {
        updateService?.checkForUpdates()
    }

    func setHyperKeyEnabled(_ enabled: Bool) {
        guard let hyperKeyService else { return }
        if enabled {
            hyperKeyService.enable()
        } else {
            hyperKeyService.disable()
        }
        hyperKeyEnabled = hyperKeyService.isEnabled
        shortcutManager.setHyperKeyEnabled(hyperKeyEnabled)
        refreshPermissions()
    }

    private static func currentVersionString(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
