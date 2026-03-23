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
    var hyperKeyEnabled: Bool = false

    var launchAtLoginEnabled: Bool {
        launchAtLoginStatus.isEnabled
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
            LaunchAtLoginPresentation(
                toggleIsOn: false,
                toggleIsEnabled: false,
                message: "Quickey couldn't find its login item configuration. This usually points to an installation or packaging problem.",
                messageStyle: .error,
                showsOpenSettingsButton: false
            )
        }
    }

    private let shortcutManager: ShortcutManager
    private let hyperKeyService: HyperKeyService?
    private let launchAtLoginService: LaunchAtLoginService

    init(
        shortcutManager: ShortcutManager,
        hyperKeyService: HyperKeyService? = nil,
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService()
    ) {
        self.shortcutManager = shortcutManager
        self.hyperKeyService = hyperKeyService
        self.launchAtLoginService = launchAtLoginService
        self.shortcutCaptureStatus = shortcutManager.shortcutCaptureStatus()
        self.launchAtLoginStatus = launchAtLoginService.status
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
        launchAtLoginStatus = launchAtLoginService.status
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openSystemSettingsLoginItems()
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
    }
}
