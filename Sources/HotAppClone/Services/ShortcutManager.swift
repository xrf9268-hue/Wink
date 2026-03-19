import Foundation

@MainActor
final class ShortcutManager {
    private let shortcutStore: ShortcutStore
    private let persistenceService: PersistenceService
    private let appSwitcher: AppSwitcher
    private let eventTapManager: EventTapManager
    private let permissionService: AccessibilityPermissionService
    private let keyMatcher = KeyMatcher()
    private var triggerIndex: [ShortcutTrigger: AppShortcut] = [:]

    init(
        shortcutStore: ShortcutStore,
        persistenceService: PersistenceService,
        appSwitcher: AppSwitcher,
        eventTapManager: EventTapManager = EventTapManager(),
        permissionService: AccessibilityPermissionService = AccessibilityPermissionService()
    ) {
        self.shortcutStore = shortcutStore
        self.persistenceService = persistenceService
        self.appSwitcher = appSwitcher
        self.eventTapManager = eventTapManager
        self.permissionService = permissionService
    }

    func start() {
        guard permissionService.requestIfNeeded(prompt: true) else {
            return
        }

        rebuildIndex()

        eventTapManager.start { [weak self] keyPress in
            self?.handleKeyPress(keyPress)
        }
    }

    func stop() {
        eventTapManager.stop()
    }

    func save(shortcuts: [AppShortcut]) {
        shortcutStore.replaceAll(with: shortcuts)
        persistenceService.save(shortcuts)
        rebuildIndex()
    }

    @discardableResult
    func trigger(_ shortcut: AppShortcut) -> Bool {
        appSwitcher.toggleApplication(for: shortcut)
    }

    func hasAccessibilityAccess() -> Bool {
        permissionService.isTrusted()
    }

    private func rebuildIndex() {
        triggerIndex = keyMatcher.buildIndex(for: shortcutStore.shortcuts)
    }

    private func handleKeyPress(_ keyPress: EventTapManager.KeyPress) {
        let key = keyMatcher.trigger(for: keyPress)
        guard let match = triggerIndex[key] else {
            return
        }
        _ = trigger(match)
    }
}
