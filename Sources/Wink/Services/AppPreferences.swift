import Foundation
import Observation

// Codable: encoded inside AppShortcut/WinkRecipe. Decoding there is
// deliberately lenient (unknown rawValue → nil override), so adding cases
// stays backward-safe; see AppShortcut.init(from:).
enum FrontmostTargetBehavior: String, Codable, CaseIterable, Equatable, Sendable {
    case hide
    case toggle
    case focus
    case cycleWindows

    var title: String {
        switch self {
        case .hide: return String(localized: "Hide", bundle: WinkResourceBundle.bundle)
        case .toggle: return String(localized: "Toggle", bundle: WinkResourceBundle.bundle)
        case .focus: return String(localized: "Focus", bundle: WinkResourceBundle.bundle)
        case .cycleWindows: return String(localized: "Cycle", bundle: WinkResourceBundle.bundle)
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
    static let frontmostExceptionsEnabledDefaultsKey = "frontmostExceptionsEnabled"
    static let frontmostExceptionRulesDefaultsKey = "frontmostExceptionRules"
    static let suggestShortcutsFromUsageDefaultsKey = "suggestShortcutsFromUsage"
    static let hyperCheatSheetEnabledDefaultsKey = "hyperCheatSheetEnabled"

    private(set) var shortcutCaptureStatus: ShortcutCaptureStatus
    private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .disabled
    private(set) var launchAtLoginAvailability: LaunchAtLoginAvailability = .available
    private(set) var launchAtLoginMutationFailure: LaunchAtLoginMutationFailure?
    private(set) var hyperKeyEnabled: Bool = false
    private(set) var shortcutsPaused: Bool = false
    /// Exception rules: shortcut capture auto-pauses while one of these
    /// bundle ids is frontmost. Composes with (never overrides) the
    /// manual pause above.
    private(set) var frontmostExceptionsEnabled: Bool = false
    private(set) var frontmostExceptionRules: [String] = []
    /// Display name of the app currently triggering an auto-pause; nil
    /// when no exception rule is active. Not persisted.
    private(set) var autoPauseTriggerAppName: String?
    /// Set by AppController wiring; called after rules/enabled change.
    var onFrontmostExceptionConfigurationChange: (@MainActor () -> Void)?
    /// Local-only foreground-activation counting that powers the Insights
    /// "Suggested" card. Disabling stops collection AND clears the data.
    private(set) var suggestShortcutsFromUsage: Bool = true
    /// Idle-hold Hyper cheat sheet (display-only overlay).
    private(set) var hyperCheatSheetEnabled: Bool = true
    var onSuggestShortcutsConfigurationChange: (@MainActor (_ enabled: Bool) -> Void)?
    /// Set by AppController wiring; called after the Hyper key toggles.
    var onHyperKeyEnabledChange: (@MainActor (_ enabled: Bool) -> Void)?
    /// Apple's own DTS guidance: `SMAppService.Status.notFound` is the normal
    /// pre-registration baseline ("the system has never seen your service"),
    /// not inherently an error — `.notRegistered` is only reached after a
    /// register()/unregister() cycle. Gate the scary "packaging problem"
    /// copy on an actual register() attempt this session, so a correctly
    /// installed copy that the user simply hasn't toggled on yet doesn't get
    /// misdiagnosed as broken.
    private var hasAttemptedLaunchAtLoginRegistration = false
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
            // The toggle reflects the real post-attempt state; only the
            // banner carries the mutation failure. .requiresApproval and
            // .notFound keep their more specific presentations below.
            if let failure = launchAtLoginMutationFailure {
                LaunchAtLoginPresentation(
                    toggleIsOn: true,
                    toggleIsEnabled: true,
                    message: Self.mutationFailureMessage(failure),
                    messageStyle: .error,
                    showsOpenSettingsButton: true
                )
            } else {
                LaunchAtLoginPresentation(
                    toggleIsOn: true,
                    toggleIsEnabled: true,
                    message: nil,
                    messageStyle: .none,
                    showsOpenSettingsButton: false
                )
            }
        case .disabled:
            if let failure = launchAtLoginMutationFailure {
                LaunchAtLoginPresentation(
                    toggleIsOn: false,
                    toggleIsEnabled: true,
                    message: Self.mutationFailureMessage(failure),
                    messageStyle: .error,
                    showsOpenSettingsButton: true
                )
            } else {
                LaunchAtLoginPresentation(
                    toggleIsOn: false,
                    toggleIsEnabled: true,
                    message: nil,
                    messageStyle: .none,
                    showsOpenSettingsButton: false
                )
            }
        case .requiresApproval:
            LaunchAtLoginPresentation(
                toggleIsOn: true,
                toggleIsEnabled: true,
                message: String(
                    localized: "Wink is registered to launch at login, but macOS still needs your approval in Login Items.",
                    bundle: WinkResourceBundle.bundle
                ),
                messageStyle: .informational,
                showsOpenSettingsButton: true
            )
        case .notFound:
            switch launchAtLoginAvailability {
            case .requiresAppInApplicationsFolder:
                LaunchAtLoginPresentation(
                    toggleIsOn: false,
                    toggleIsEnabled: false,
                    message: String(
                        localized: "Launch at Login is only available after installing Wink.app in the Applications folder and reopening it.",
                        bundle: WinkResourceBundle.bundle
                    ),
                    messageStyle: .informational,
                    showsOpenSettingsButton: false
                )
            case .available, .missingConfiguration:
                if hasAttemptedLaunchAtLoginRegistration {
                    LaunchAtLoginPresentation(
                        toggleIsOn: false,
                        toggleIsEnabled: false,
                        message: String(
                            localized: "Wink couldn't find its login item configuration. This usually points to an installation or packaging problem.",
                            bundle: WinkResourceBundle.bundle
                        ),
                        messageStyle: .error,
                        showsOpenSettingsButton: false
                    )
                } else {
                    // notFound before any register() attempt this session is
                    // Apple's documented normal baseline, not a defect —
                    // present it like .disabled until an actual attempt
                    // proves otherwise.
                    LaunchAtLoginPresentation(
                        toggleIsOn: false,
                        toggleIsEnabled: true,
                        message: nil,
                        messageStyle: .none,
                        showsOpenSettingsButton: false
                    )
                }
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
        let initialExceptionsEnabled = userDefaults.object(forKey: Self.frontmostExceptionsEnabledDefaultsKey) as? Bool ?? false
        let initialExceptionRules = userDefaults.object(forKey: Self.frontmostExceptionRulesDefaultsKey) as? [String]
            ?? FrontmostExceptionMonitor.defaultRuleBundleIdentifiers
        let initialSuggestFromUsage = userDefaults.object(forKey: Self.suggestShortcutsFromUsageDefaultsKey) as? Bool ?? true
        let initialCheatSheetEnabled = userDefaults.object(forKey: Self.hyperCheatSheetEnabledDefaultsKey) as? Bool ?? true
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
        self.frontmostExceptionsEnabled = initialExceptionsEnabled
        self.frontmostExceptionRules = initialExceptionRules
        self.suggestShortcutsFromUsage = initialSuggestFromUsage
        self.hyperCheatSheetEnabled = initialCheatSheetEnabled
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
        if enabled {
            hasAttemptedLaunchAtLoginRegistration = true
        }
        // A successful later attempt clears any stale failure because the
        // result is nil on success.
        launchAtLoginMutationFailure = launchAtLoginService.setEnabled(enabled)
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

    func setFrontmostExceptionsEnabled(_ enabled: Bool) {
        guard enabled != frontmostExceptionsEnabled else { return }
        frontmostExceptionsEnabled = enabled
        userDefaults.set(enabled, forKey: Self.frontmostExceptionsEnabledDefaultsKey)
        onFrontmostExceptionConfigurationChange?()
    }

    func addFrontmostExceptionRule(bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty,
              !frontmostExceptionRules.contains(bundleIdentifier) else { return }
        frontmostExceptionRules.append(bundleIdentifier)
        userDefaults.set(frontmostExceptionRules, forKey: Self.frontmostExceptionRulesDefaultsKey)
        onFrontmostExceptionConfigurationChange?()
    }

    func removeFrontmostExceptionRule(bundleIdentifier: String) {
        guard frontmostExceptionRules.contains(bundleIdentifier) else { return }
        frontmostExceptionRules.removeAll { $0 == bundleIdentifier }
        userDefaults.set(frontmostExceptionRules, forKey: Self.frontmostExceptionRulesDefaultsKey)
        onFrontmostExceptionConfigurationChange?()
    }

    func setHyperCheatSheetEnabled(_ enabled: Bool) {
        guard enabled != hyperCheatSheetEnabled else { return }
        hyperCheatSheetEnabled = enabled
        userDefaults.set(enabled, forKey: Self.hyperCheatSheetEnabledDefaultsKey)
    }

    func setSuggestShortcutsFromUsage(_ enabled: Bool) {
        guard enabled != suggestShortcutsFromUsage else { return }
        suggestShortcutsFromUsage = enabled
        userDefaults.set(enabled, forKey: Self.suggestShortcutsFromUsageDefaultsKey)
        onSuggestShortcutsConfigurationChange?(enabled)
    }

    func setAutoPauseTrigger(appName: String?) {
        guard autoPauseTriggerAppName != appName else { return }
        autoPauseTriggerAppName = appName
    }

    func refreshLaunchAtLoginStatus() {
        let launchAtLoginSnapshot = launchAtLoginService.snapshot
        launchAtLoginStatus = launchAtLoginSnapshot.status
        launchAtLoginAvailability = launchAtLoginSnapshot.availability

        // Clear a stale failure once the observed status shows the failed
        // mutation's intent was achieved externally (e.g. in System Settings).
        // A failed register leaves the status .disabled and a failed
        // unregister leaves it .enabled, so a fresh failure stays visible.
        guard let failure = launchAtLoginMutationFailure else { return }
        let isRegistered = launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
        let intentAchieved = switch failure.mutation {
        case .register: isRegistered
        case .unregister: !isRegistered
        }
        if intentAchieved {
            launchAtLoginMutationFailure = nil
        }
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
        onHyperKeyEnabledChange?(hyperKeyEnabled)
        refreshPermissions()
    }

    private static func mutationFailureMessage(_ failure: LaunchAtLoginMutationFailure) -> String {
        switch failure.mutation {
        case .register:
            String(
                localized: "Wink couldn't enable Launch at Login: \(failure.reason). Try again, or manage it in System Settings › Login Items.",
                bundle: WinkResourceBundle.bundle
            )
        case .unregister:
            String(
                localized: "Wink couldn't disable Launch at Login: \(failure.reason). Try again, or manage it in System Settings › Login Items.",
                bundle: WinkResourceBundle.bundle
            )
        }
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
