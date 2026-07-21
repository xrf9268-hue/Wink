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
    static let lastSeenVersionDefaultsKey = "com.wink.lastSeenVersion"

    private let shortcutStore = ShortcutStore()
    private let persistenceService = PersistenceService()
    private let usageTracker = UsageTracker()
    private let hyperKeyService = HyperKeyService()
    private let appBundleLocator = AppBundleLocator()
    private let userDefaults: UserDefaults
    private lazy var updateService = SparkleUpdateService()
    private let whatsNewPresenter = WhatsNewPresenter()
    private let updatePanelPresenter = UpdatePanelPresenter()
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
    private lazy var frontmostExceptionMonitor = FrontmostExceptionMonitor(
        onAutoPauseChange: { [weak self] paused, appName in
            self?.shortcutManager.setAutoPausedByException(paused)
            self?.appPreferences.setAutoPauseTrigger(appName: paused ? appName : nil)
            // Keep the observable capture status truthful under auto-pause.
            self?.appPreferences.refreshPermissions()
        }
    )
    private lazy var cheatSheetHUD = CheatSheetHUDController(
        rowsProvider: { [weak self] in
            guard let self else { return [] }
            return self.shortcutStore.shortcuts
                .filter(\.isEnabled)
                .map { shortcut in
                    CheatSheetRow(
                        id: shortcut.id,
                        appName: shortcut.appName,
                        bundleIdentifier: shortcut.bundleIdentifier,
                        keyDisplay: ModifierFormatting.displayText(
                            modifierFlags: shortcut.modifierFlags,
                            keyEquivalent: shortcut.keyEquivalent
                        )
                    )
                }
        },
        isEnabled: { [weak self] in
            guard let self else { return false }
            return self.appPreferences.hyperCheatSheetEnabled
                && self.appPreferences.hyperKeyEnabled
        }
    )
    private lazy var appActivationRecorder = AppActivationRecorder(
        onActivation: { [weak self] bundleIdentifier in
            self?.recordAppActivation(bundleIdentifier)
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

    /// FIFO chain over activation writes and the opt-out purge: unstructured
    /// tasks have no mutual ordering, so a queued write could otherwise land
    /// AFTER the purge (retaining data while disabled) or a queued purge
    /// could erase rows recorded after a quick re-enable.
    private var activationWriteChain: Task<Void, Never>?

    private func recordAppActivation(_ bundleIdentifier: String) {
        let tracker = usageTracker
        activationWriteChain = Task { [previous = activationWriteChain] in
            await previous?.value
            await tracker.recordAppActivation(bundleIdentifier: bundleIdentifier)
        }
    }

    private func purgeAppActivations() {
        let tracker = usageTracker
        activationWriteChain = Task { [previous = activationWriteChain] in
            await previous?.value
            await tracker.deleteAllAppActivations()
        }
    }

    func start() {
        DiagnosticLog.rotateIfNeeded()
        DiagnosticLog.log("Wink starting, version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")

        // Set AX global messaging timeout to 1s (default is 6s).
        // Prevents AX calls from blocking threads for too long when apps are unresponsive.
        // Reference: alt-tab-macos
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        // Wire the update panel before the updater starts so a launch-time
        // resumed session can present immediately.
        updateService.presentUpdatePanel = { [weak self] activate in
            guard let self else { return }
            self.updatePanelPresenter.present(preferences: self.appPreferences, activate: activate)
        }
        updateService.dismissUpdatePanel = { [weak self] in
            self?.updatePanelPresenter.dismiss()
        }

        // Exception rules: configure from persisted preferences, follow
        // future edits, and start following frontmost changes.
        appPreferences.onFrontmostExceptionConfigurationChange = { [weak self] in
            guard let self else { return }
            self.frontmostExceptionMonitor.configure(
                enabled: self.appPreferences.frontmostExceptionsEnabled,
                ruleBundleIdentifiers: self.appPreferences.frontmostExceptionRules
            )
        }
        frontmostExceptionMonitor.configure(
            enabled: appPreferences.frontmostExceptionsEnabled,
            ruleBundleIdentifiers: appPreferences.frontmostExceptionRules
        )
        frontmostExceptionMonitor.startObservingWorkspaceNotifications()

        appPreferences.onSuggestShortcutsConfigurationChange = { [weak self] enabled in
            // Recorder disables synchronously before the purge enqueues, so
            // the FIFO chain guarantees "stop AND clear": prior writes land
            // first, no later writes exist, and post-re-enable writes queue
            // after the purge.
            self?.appActivationRecorder.setEnabled(enabled)
            if !enabled {
                self?.purgeAppActivations()
            }
        }
        appActivationRecorder.setEnabled(appPreferences.suggestShortcutsFromUsage)
        appActivationRecorder.startObservingWorkspaceNotifications()
        if !appPreferences.suggestShortcutsFromUsage {
            // Quitting before the async opt-out purge ran leaves rows on
            // disk with the preference off; sweep them on every disabled
            // startup so re-enabling never resurfaces pre-opt-out counts.
            purgeAppActivations()
        }

        // Configured BEFORE the startup sequence so launching while an
        // exception app is frontmost never lets capture (or permission
        // prompts) fire ahead of the auto-pause.
        shortcutManager.onCaptureStatusChange = { [weak self] in
            self?.appPreferences.refreshPermissions()
        }

        // Hold events arrive on the tap thread; hop once to the main actor
        // where the cheat-sheet controller lives.
        let cheatSheet = cheatSheetHUD
        shortcutManager.setHyperHoldObserver { event in
            Task { @MainActor in
                cheatSheet.handle(event)
            }
        }

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

        // Read the onboarded state before consumeFirstLaunchFlag marks it, so
        // the What's New gate can tell a fresh install from an upgrade.
        let hasLaunchedBefore = userDefaults.bool(forKey: Self.firstLaunchCompletedDefaultsKey)

        if Self.consumeFirstLaunchFlag(
            userDefaults: userDefaults,
            hasExistingShortcuts: !shortcutStore.shortcuts.isEmpty
        ) {
            openSettings()
        }

        let currentVersion = Self.currentVersionString()
        let notes = WhatsNewCatalog.notes(for: currentVersion)
        if Self.consumeWhatsNewGate(
            userDefaults: userDefaults,
            currentVersion: currentVersion,
            hasLaunchedBefore: hasLaunchedBefore,
            hasNotes: !notes.isEmpty
        ) {
            // Slight delay so the panel appears after launch settles; it is
            // non-activating and never steals focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.whatsNewPresenter.present(version: currentVersion, notes: notes)
            }
        }
    }

    func stop() {
        hyperKeyService.clearMappingIfEnabled()
        shortcutManager.stop()
    }

    /// wink:// URL scheme entry. Toggle reuses the full activation
    /// pipeline via a synthetic shortcut but goes straight to the switcher
    /// — automation presses never record usage (Insights stays a picture
    /// of the user's own keystrokes). Pause/resume mirror the menu bar
    /// toggle, capsule state included.
    func handleURLs(_ urls: [URL]) {
        for url in urls {
            guard let command = WinkURLCommand.parse(url) else {
                DiagnosticLog.log("URL: ignored unrecognized \(url.absoluteString)")
                continue
            }
            switch command {
            case .toggle(let bundleIdentifier):
                guard appBundleLocator.applicationURL(for: bundleIdentifier) != nil else {
                    DiagnosticLog.log("URL: toggle ignored, no installed app for \(bundleIdentifier)")
                    continue
                }
                let name = appBundleLocator.applicationURL(for: bundleIdentifier)?
                    .deletingPathExtension().lastPathComponent ?? bundleIdentifier
                DiagnosticLog.log("URL: toggle \(bundleIdentifier)")
                _ = appSwitcher.toggleApplication(for: AppShortcut(
                    appName: name,
                    bundleIdentifier: bundleIdentifier,
                    keyEquivalent: "",
                    modifierFlags: []
                ))
            case .pause:
                DiagnosticLog.log("URL: pause")
                appPreferences.setShortcutsPaused(true)
            case .resume:
                DiagnosticLog.log("URL: resume")
                appPreferences.setShortcutsPaused(false)
            }
        }
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

    /// Returns true exactly once per version change on an already-onboarded
    /// install (fresh installs only record the version). Always writes back
    /// `lastSeenVersion` synchronously, mirroring `consumeFirstLaunchFlag`'s
    /// crash-safe consume-then-act shape. The decision itself is
    /// `LaunchGates.shouldShowWhatsNew` (pure, unit-tested).
    static func consumeWhatsNewGate(
        userDefaults: UserDefaults,
        currentVersion: String,
        hasLaunchedBefore: Bool,
        hasNotes: Bool
    ) -> Bool {
        let lastSeenVersion = userDefaults.string(forKey: lastSeenVersionDefaultsKey)
        userDefaults.set(currentVersion, forKey: lastSeenVersionDefaultsKey)
        return LaunchGates.shouldShowWhatsNew(
            currentVersion: currentVersion,
            hasLaunchedBefore: hasLaunchedBefore,
            lastSeenVersion: lastSeenVersion,
            hasNotes: hasNotes
        )
    }

    private static func currentVersionString(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
