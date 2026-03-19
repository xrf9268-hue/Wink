import Foundation

@MainActor
final class ShortcutManager {
    private let shortcutStore: ShortcutStore
    private let persistenceService: PersistenceService
    private let appSwitcher: AppSwitcher

    init(shortcutStore: ShortcutStore, persistenceService: PersistenceService, appSwitcher: AppSwitcher) {
        self.shortcutStore = shortcutStore
        self.persistenceService = persistenceService
        self.appSwitcher = appSwitcher
    }

    func start() {
        // Placeholder for global shortcut registration and event tap startup.
    }

    func stop() {
        // Placeholder for teardown.
    }

    func save(shortcuts: [AppShortcut]) {
        shortcutStore.replaceAll(with: shortcuts)
        persistenceService.save(shortcuts)
    }

    @discardableResult
    func trigger(_ shortcut: AppShortcut) -> Bool {
        appSwitcher.toggleApplication(for: shortcut)
    }
}
