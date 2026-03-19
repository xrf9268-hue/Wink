import AppKit

@MainActor
final class AppController {
    private let shortcutStore = ShortcutStore()
    private let persistenceService = PersistenceService()
    private lazy var appSwitcher = AppSwitcher()
    private lazy var shortcutManager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: persistenceService,
        appSwitcher: appSwitcher
    )
    private lazy var menuBarController = MenuBarController(
        onOpenSettings: { [weak self] in self?.openSettings() },
        onQuit: { NSApplication.shared.terminate(nil) }
    )
    private lazy var settingsWindowController = SettingsWindowController(
        shortcutStore: shortcutStore,
        shortcutManager: shortcutManager
    )

    func start() {
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
