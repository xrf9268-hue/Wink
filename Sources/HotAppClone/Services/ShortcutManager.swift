import Foundation
import os.log

private let logger = Logger(subsystem: "com.hotappclone", category: "ShortcutManager")

@MainActor
final class ShortcutManager {
    private let shortcutStore: ShortcutStore
    private let persistenceService: PersistenceService
    private let appSwitcher: AppSwitcher
    private let eventTapManager: EventTapManager
    private let permissionService: AccessibilityPermissionService
    private let keyMatcher = KeyMatcher()
    private var triggerIndex: [ShortcutTrigger: AppShortcut] = [:]
    private var permissionTimer: Timer?
    private var lastPermissionState: Bool = false

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
        permissionService.requestIfNeeded(prompt: true)
        startPermissionMonitoring()
        attemptStartIfPermitted()
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
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

    // MARK: - Permission monitoring

    private func startPermissionMonitoring() {
        lastPermissionState = permissionService.isTrusted()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermissionChange()
            }
        }
    }

    private func checkPermissionChange() {
        let granted = permissionService.isTrusted()
        guard granted != lastPermissionState else { return }
        lastPermissionState = granted

        if granted {
            logger.info("Input Monitoring permission granted — starting event tap")
            attemptStartIfPermitted()
        } else {
            logger.warning("Input Monitoring permission revoked — stopping event tap")
            eventTapManager.stop()
        }
    }

    private func attemptStartIfPermitted() {
        guard permissionService.isTrusted() else { return }
        guard !eventTapManager.isRunning else { return }

        rebuildIndex()
        eventTapManager.start { [weak self] keyPress in
            self?.handleKeyPress(keyPress)
        }
    }

    // MARK: - Key handling

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
