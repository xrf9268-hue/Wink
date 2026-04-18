import AppKit
import ApplicationServices

@MainActor
final class AppController {
    static let firstLaunchCompletedDefaultsKey = "com.quickey.firstLaunchCompleted"

    private let shortcutStore = ShortcutStore()
    private let persistenceService = PersistenceService()
    private let usageTracker = UsageTracker()
    private let hyperKeyService = HyperKeyService()
    private let userDefaults: UserDefaults
    private lazy var appSwitcher = AppSwitcher()
    private lazy var shortcutManager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: persistenceService,
        appSwitcher: appSwitcher,
        usageTracker: usageTracker,
        diagnosticClient: .live
    )
    private lazy var menuBarController = MenuBarController(
        onOpenSettings: { [weak self] in self?.openSettings() },
        onQuit: { NSApplication.shared.terminate(nil) }
    )
    private lazy var settingsWindowController = SettingsWindowController(
        shortcutStore: shortcutStore,
        shortcutManager: shortcutManager,
        usageTracker: usageTracker,
        hyperKeyService: hyperKeyService
    )

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func start() {
        DiagnosticLog.rotateIfNeeded()
        DiagnosticLog.log("Quickey starting, version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")

        // Set AX global messaging timeout to 1s (default is 6s).
        // Prevents AX calls from blocking threads for too long when apps are unresponsive.
        // Reference: alt-tab-macos
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        Self.runStartupSequence(
            loadShortcuts: { try persistenceService.load() },
            replaceShortcuts: { shortcutStore.replaceAll(with: $0) },
            reapplyHyperIfNeeded: { hyperKeyService.reapplyIfNeeded() },
            isHyperEnabled: { hyperKeyService.isEnabled },
            setHyperKeyEnabled: { shortcutManager.setHyperKeyEnabled($0) },
            startShortcutManager: { shortcutManager.start() },
            installMenuBar: { menuBarController.install() }
        )

        if Self.consumeFirstLaunchFlag(userDefaults: userDefaults) {
            openSettings()
        }
    }

    func stop() {
        hyperKeyService.clearMappingIfEnabled()
        shortcutManager.stop()
    }

    private func openSettings() {
        settingsWindowController.show()
        NSApp.activate()
    }

    static func runStartupSequence(
        loadShortcuts: @MainActor () throws -> [AppShortcut],
        replaceShortcuts: @MainActor ([AppShortcut]) -> Void,
        reapplyHyperIfNeeded: @MainActor () -> Void,
        isHyperEnabled: @MainActor () -> Bool,
        setHyperKeyEnabled: @MainActor (Bool) -> Void,
        startShortcutManager: @MainActor () -> Void,
        installMenuBar: @MainActor () -> Void
    ) {
        do {
            replaceShortcuts(try loadShortcuts())
        } catch {
            DiagnosticLog.log(
                "Startup skipped shortcut restore because persistence loading failed: \(error.localizedDescription)"
            )
        }
        reapplyHyperIfNeeded()
        setHyperKeyEnabled(isHyperEnabled())
        startShortcutManager()
        installMenuBar()
    }

    /// Returns true exactly once per install: marks the flag synchronously before
    /// returning so a crash in the caller's follow-up work won't cause a re-prompt.
    static func consumeFirstLaunchFlag(userDefaults: UserDefaults) -> Bool {
        guard !userDefaults.bool(forKey: firstLaunchCompletedDefaultsKey) else { return false }
        userDefaults.set(true, forKey: firstLaunchCompletedDefaultsKey)
        return true
    }
}
