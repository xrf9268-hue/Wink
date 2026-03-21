import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    private(set) var accessibilityGranted: Bool = false
    private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .disabled
    var hyperKeyEnabled: Bool = false

    var launchAtLoginEnabled: Bool {
        launchAtLoginStatus.isEnabled
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
        self.accessibilityGranted = shortcutManager.hasAccessibilityAccess()
        self.launchAtLoginStatus = launchAtLoginService.status
        self.hyperKeyEnabled = hyperKeyService?.isEnabled ?? false
    }

    func refreshPermissions() {
        let current = shortcutManager.hasAccessibilityAccess()
        if current != accessibilityGranted {
            accessibilityGranted = current
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
