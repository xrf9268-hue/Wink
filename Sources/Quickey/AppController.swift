import AppKit

@MainActor
final class AppController {
    private let shortcutStore = ShortcutStore()
    private let persistenceService = PersistenceService()
    private let usageTracker = UsageTracker()
    private lazy var appSwitcher = AppSwitcher()
    private lazy var shortcutManager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: persistenceService,
        appSwitcher: appSwitcher,
        usageTracker: usageTracker
    )
    private lazy var menuBarController = MenuBarController(
        onOpenSettings: { [weak self] in self?.openSettings() },
        onQuit: { NSApplication.shared.terminate(nil) }
    )
    private lazy var settingsWindowController = SettingsWindowController(
        shortcutStore: shortcutStore,
        shortcutManager: shortcutManager,
        usageTracker: usageTracker
    )

    func start() {
        DiagnosticLog.rotateIfNeeded()
        DiagnosticLog.log("Quickey starting, version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        shortcutStore.replaceAll(with: persistenceService.load())
        shortcutManager.start()
        menuBarController.install()
    }

    func stop() {
        shortcutManager.stop()
    }

    private func openSettings() {
        settingsWindowController.show()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
