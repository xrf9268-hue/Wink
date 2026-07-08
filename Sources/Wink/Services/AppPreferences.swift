import Foundation
import Observation

enum FrontmostTargetBehavior: String, CaseIterable, Equatable, Sendable {
    case hide
    case toggle
    case focus

    var title: String {
        switch self {
        case .hide: return "Hide"
        case .toggle: return "Toggle"
        case .focus: return "Focus"
        }
    }
}

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
    static let frontmostTargetBehaviorDefaultsKey = "frontmostTargetBehavior"
    static let menuBarIconVisibleDefaultsKey = "menuBarIconVisible"
    static let shortcutsPausedDefaultsKey = "shortcutsPaused"

    private(set) var shortcutCaptureStatus: ShortcutCaptureStatus
    private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .disabled
    private(set) var launchAtLoginAvailability: LaunchAtLoginAvailability = .available
    var hyperKeyEnabled: Bool = false
    private(set) var shortcutsPaused: Bool = false
    var frontmostTargetBehavior: FrontmostTargetBehavior {
        didSet {
            guard frontmostTargetBehavior != oldValue else { return }
            userDefaults.set(frontmostTargetBehavior.rawValue, forKey: Self.frontmostTargetBehaviorDefaultsKey)
            shortcutManager.setFrontmostTargetBehavior(frontmostTargetBehavior)
        }
    }

    var launchAtLoginEnabled: Bool {
        launchAtLoginStatus.isEnabled
    }

    var updatePresentation: UpdatePresentation {
        UpdatePresentation(
            currentVersion: updateService?.currentVersion ?? Self.currentVersionString(),
            isConfigured: updateService?.isConfigured ?? false,
            // Keyed on configuration, not the transient canCheckForUpdates
            // snapshot: repeat clicks while a session is in flight re-focus
            // Sparkle's existing session, which is the desired recovery path.
            checkForUpdatesEnabled: updateService?.isConfigured ?? false,
            automaticChecksEnabled: updateService?.automaticallyChecksForUpdates
                ?? Self.boolValue(forInfoDictionaryKey: "SUEnableAutomaticChecks", default: true),
            automaticDownloadsEnabled: updateService?.automaticallyDownloadsUpdates
                ?? Self.boolValue(forInfoDictionaryKey: "SUAutomaticallyUpdate", default: true)
        )
    }

    /// Master switch mirrored from the live updater values so SwiftUI can
    /// observe flips (`updatePresentation` is computed off non-observable
    /// service state). ON means scheduled checks plus background downloads;
    /// mixed states (only reachable via `defaults write`) read as OFF and
    /// normalize on the next toggle.
    private(set) var automaticUpdatesEnabled: Bool = false

    /// Mirrors of the update service's session state, stored so SwiftUI can
    /// observe changes (the service itself is not @Observable).
    private(set) var updatePhase: UpdatePhase = .idle
    private(set) var lastUpdateCheckDate: Date?

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
                message: "Wink is registered to launch at login, but macOS still needs your approval in Login Items.",
                messageStyle: .informational,
                showsOpenSettingsButton: true
            )
        case .notFound:
            switch launchAtLoginAvailability {
            case .requiresAppInApplicationsFolder:
                LaunchAtLoginPresentation(
                    toggleIsOn: false,
                    toggleIsEnabled: false,
                    message: "Launch at Login is only available after installing Wink.app in the Applications folder and reopening it.",
                    messageStyle: .informational,
                    showsOpenSettingsButton: false
                )
            case .available, .missingConfiguration:
                LaunchAtLoginPresentation(
                    toggleIsOn: false,
                    toggleIsEnabled: false,
                    message: "Wink couldn't find its login item configuration. This usually points to an installation or packaging problem.",
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
    private let userDefaults: UserDefaults

    init(
        shortcutManager: ShortcutManager,
        hyperKeyService: HyperKeyService? = nil,
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        updateService: UpdateServicing? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        let initialHyperKeyEnabled = hyperKeyService?.isEnabled ?? false
        let initialShortcutsPaused = userDefaults.object(forKey: Self.shortcutsPausedDefaultsKey) as? Bool ?? false
        let initialFrontmostTargetBehavior: FrontmostTargetBehavior
        if let rawValue = userDefaults.string(forKey: Self.frontmostTargetBehaviorDefaultsKey),
           let storedBehavior = FrontmostTargetBehavior(rawValue: rawValue) {
            initialFrontmostTargetBehavior = storedBehavior
        } else {
            initialFrontmostTargetBehavior = .toggle
        }

        self.shortcutManager = shortcutManager
        self.hyperKeyService = hyperKeyService
        self.launchAtLoginService = launchAtLoginService
        self.updateService = updateService
        self.userDefaults = userDefaults
        self.automaticUpdatesEnabled = Self.resolveAutomaticUpdatesEnabled(from: updateService)
        self.updatePhase = updateService?.updatePhase ?? .idle
        self.lastUpdateCheckDate = updateService?.lastUpdateCheckDate
        self.hyperKeyEnabled = initialHyperKeyEnabled
        self.shortcutsPaused = initialShortcutsPaused
        self.frontmostTargetBehavior = initialFrontmostTargetBehavior

        shortcutManager.setFrontmostTargetBehavior(initialFrontmostTargetBehavior)
        shortcutManager.setShortcutsPaused(initialShortcutsPaused)
        self.shortcutCaptureStatus = shortcutManager.shortcutCaptureStatus()

        let launchAtLoginSnapshot = launchAtLoginService.snapshot
        self.launchAtLoginStatus = launchAtLoginSnapshot.status
        self.launchAtLoginAvailability = launchAtLoginSnapshot.availability

        updateService?.onUpdateStateChange = { [weak self] in
            self?.refreshUpdateState()
        }
    }

    func refreshPermissions() {
        let current = shortcutManager.shortcutCaptureStatus()
        if current != shortcutCaptureStatus {
            shortcutCaptureStatus = current
        }
    }

    func requestShortcutPermissions() {
        shortcutManager.requestPermissions()
        refreshPermissions()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginService.setEnabled(enabled)
        refreshLaunchAtLoginStatus()
    }

    func setShortcutsPaused(_ paused: Bool) {
        guard paused != shortcutsPaused else {
            return
        }

        shortcutManager.setShortcutsPaused(paused)
        userDefaults.set(paused, forKey: Self.shortcutsPausedDefaultsKey)
        shortcutsPaused = paused
        refreshPermissions()
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

    private func refreshUpdateState() {
        guard let updateService else { return }
        if updatePhase != updateService.updatePhase {
            updatePhase = updateService.updatePhase
        }
        if lastUpdateCheckDate != updateService.lastUpdateCheckDate {
            lastUpdateCheckDate = updateService.lastUpdateCheckDate
        }
    }

    // MARK: - Update session actions (update panel / popover)

    func installUpdateNow() {
        updateService?.installUpdateNow()
    }

    func remindUpdateLater() {
        updateService?.remindUpdateLater()
    }

    func skipUpdateVersion() {
        updateService?.skipUpdateVersion()
    }

    func cancelUpdateOperation() {
        updateService?.cancelUpdateOperation()
    }

    func acknowledgeUpdateResult() {
        updateService?.acknowledgeUpdateResult()
    }

    /// Routes the update panel's close button to the session action that
    /// matches the current phase, so closing the window never leaks a held
    /// Sparkle reply or acknowledgement.
    func handleUpdatePanelCloseRequest() {
        switch updatePhase {
        case .checking, .downloading:
            cancelUpdateOperation()
        case .available, .ready, .extracting, .installing:
            remindUpdateLater()
        case .upToDate, .error:
            acknowledgeUpdateResult()
        case .idle:
            break
        }
    }

    /// Drives both Sparkle flags (scheduled checks + background downloads)
    /// as one user-facing switch. The mirrored state is read back from the
    /// service after the write so it only reflects what actually persisted.
    ///
    /// Order matters: without an `SUAllowsAutomaticUpdates` Info.plist key,
    /// Sparkle derives `allowsAutomaticUpdates` from the checks flag and
    /// silently drops writes to `automaticallyDownloadsUpdates` while checks
    /// are off (SPUUpdaterSettings.setAutomaticallyDownloadsUpdates). Write
    /// the downloads flag while checks are still on so both flags persist.
    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        guard let updateService else { return }
        if enabled {
            updateService.automaticallyChecksForUpdates = true
            updateService.automaticallyDownloadsUpdates = true
        } else {
            updateService.automaticallyDownloadsUpdates = false
            updateService.automaticallyChecksForUpdates = false
        }
        automaticUpdatesEnabled = Self.resolveAutomaticUpdatesEnabled(from: updateService)
    }

    private static func resolveAutomaticUpdatesEnabled(from updateService: UpdateServicing?) -> Bool {
        let checks = updateService?.automaticallyChecksForUpdates
            ?? boolValue(forInfoDictionaryKey: "SUEnableAutomaticChecks", default: true)
        let downloads = updateService?.automaticallyDownloadsUpdates
            ?? boolValue(forInfoDictionaryKey: "SUAutomaticallyUpdate", default: true)
        return checks && downloads
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

    private static func boolValue(
        forInfoDictionaryKey key: String,
        bundle: Bundle = .main,
        default defaultValue: Bool
    ) -> Bool {
        if let value = bundle.object(forInfoDictionaryKey: key) as? Bool {
            return value
        }

        if let value = bundle.object(forInfoDictionaryKey: key) as? NSNumber {
            return value.boolValue
        }

        return defaultValue
    }
}
