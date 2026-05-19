import AppKit
import ApplicationServices

@MainActor
final class AppController {
    struct SettingsSceneServices {
        let editor: ShortcutEditorState
        let preferences: AppPreferences
        let insightsViewModel: InsightsViewModel
        let appListProvider: AppListProvider
        let shortcutStatusProvider: ShortcutStatusProvider
        let settingsLauncher: SettingsLauncher
    }

    struct MenuBarSceneServices {
        let shortcutStore: ShortcutStore
        let preferences: AppPreferences
        let shortcutStatusProvider: ShortcutStatusProvider
        let usageTracker: any UsageTracking
        let openSettings: @MainActor (SettingsTab?) -> Void
        let quit: @MainActor () -> Void
    }

    static let firstLaunchCompletedDefaultsKey = "com.wink.firstLaunchCompleted"

    private let shortcutStore = ShortcutStore()
    private let persistenceService = PersistenceService()
    private let usageTracker = UsageTracker()
    private let hyperKeyService = HyperKeyService()
    private let appBundleLocator = AppBundleLocator()
    private let userDefaults: UserDefaults
    private lazy var updateService = SparkleUpdateService()
    private lazy var appSwitcher = AppSwitcher()
    private lazy var settingsLauncher = SettingsLauncher(userDefaults: userDefaults)
    private lazy var settingsShortcutStatusProvider = ShortcutStatusProvider()
    private lazy var shortcutManager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: persistenceService,
        appSwitcher: appSwitcher,
        usageTracker: usageTracker,
        appBundleLocator: appBundleLocator,
        automaticPermissionPromptingEnabled: ShortcutManager.defaultAutomaticPermissionPromptingEnabled(),
        diagnosticClient: .live
    )
    private lazy var appPreferences = AppPreferences(
        shortcutManager: shortcutManager,
        hyperKeyService: hyperKeyService,
        updateService: updateService,
        userDefaults: userDefaults
    )
    private lazy var shortcutEditor = ShortcutEditorState(
        shortcutStore: shortcutStore,
        shortcutManager: shortcutManager,
        usageTracker: usageTracker,
        onShortcutConfigurationChange: { [weak self] in
            self?.appPreferences.refreshPermissions()
        }
    )
    private lazy var insightsViewModel = InsightsViewModel(
        usageTracker: usageTracker,
        shortcutStore: shortcutStore
    )
    private lazy var appListProvider = AppListProvider()
    private lazy var settingsSceneServicesStorage = SettingsSceneServices(
        editor: shortcutEditor,
        preferences: appPreferences,
        insightsViewModel: insightsViewModel,
        appListProvider: appListProvider,
        shortcutStatusProvider: settingsShortcutStatusProvider,
        settingsLauncher: settingsLauncher
    )
    private lazy var menuBarSceneServicesStorage = MenuBarSceneServices(
        shortcutStore: shortcutStore,
        preferences: appPreferences,
        shortcutStatusProvider: settingsShortcutStatusProvider,
        usageTracker: usageTracker,
        openSettings: { [weak self] tab in
            self?.openSettings(tab: tab)
        },
        quit: {
            NSApplication.shared.terminate(nil)
        }
    )

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var settingsSceneServices: SettingsSceneServices {
        settingsSceneServicesStorage
    }

    var settingsLauncherService: SettingsLauncher {
        settingsLauncher
    }

    var menuBarSceneServices: MenuBarSceneServices {
        menuBarSceneServicesStorage
    }

    func start() {
        DiagnosticLog.rotateIfNeeded()
        DiagnosticLog.log("Wink starting, version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")

        // Set AX global messaging timeout to 1s (default is 6s).
        // Prevents AX calls from blocking threads for too long when apps are unresponsive.
        // Reference: alt-tab-macos
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        Self.runStartupSequence(
            startUpdateService: { _ = updateService },
            loadShortcuts: { try persistenceService.load() },
            replaceShortcuts: { shortcutStore.replaceAll(with: $0) },
            reapplyHyperIfNeeded: { hyperKeyService.reapplyIfNeeded() },
            isHyperEnabled: { hyperKeyService.isEnabled },
            setHyperKeyEnabled: { shortcutManager.setHyperKeyEnabled($0) },
            preparePreferences: { _ = appPreferences },
            startShortcutManager: { shortcutManager.start() }
        )

        if Self.consumeFirstLaunchFlag(
            userDefaults: userDefaults,
            hasExistingShortcuts: !shortcutStore.shortcuts.isEmpty
        ) {
            openSettings()
        }
    }

    func stop() {
        hyperKeyService.clearMappingIfEnabled()
        shortcutManager.stop()
    }

    func openPrimarySettingsWindow() {
        openSettings()
    }

    private func openSettings(tab: SettingsTab? = nil) {
        settingsLauncher.open(tab: tab)
        NSApp.activate()
    }

    static func runStartupSequence(
        startUpdateService: @MainActor () -> Void,
        loadShortcuts: @MainActor () throws -> [AppShortcut],
        replaceShortcuts: @MainActor ([AppShortcut]) -> Void,
        reapplyHyperIfNeeded: @MainActor () -> Bool,
        isHyperEnabled: @MainActor () -> Bool,
        setHyperKeyEnabled: @MainActor (Bool) -> Void,
        preparePreferences: @MainActor () -> Void = {},
        startShortcutManager: @MainActor () -> Void
    ) {
        startUpdateService()
        do {
            replaceShortcuts(try loadShortcuts())
        } catch {
            DiagnosticLog.log(
                "Startup skipped shortcut restore because persistence loading failed: \(error.localizedDescription)"
            )
        }
        let isHyperEnabled = isHyperEnabled()
        let isHyperMappingApplied = reapplyHyperIfNeeded()
        setHyperKeyEnabled(isHyperEnabled && isHyperMappingApplied)
        preparePreferences()
        startShortcutManager()
    }

    /// Returns true exactly once per install, and only when no shortcuts exist yet.
    /// Marks the flag synchronously so a crash in the caller's follow-up work won't
    /// cause a re-prompt. Existing users upgrading from a pre-flag build (who already
    /// have shortcuts) get silently marked as onboarded without seeing the prompt.
    static func consumeFirstLaunchFlag(
        userDefaults: UserDefaults,
        hasExistingShortcuts: Bool
    ) -> Bool {
        guard !userDefaults.bool(forKey: firstLaunchCompletedDefaultsKey) else { return false }
        userDefaults.set(true, forKey: firstLaunchCompletedDefaultsKey)
        return !hasExistingShortcuts
    }
}
