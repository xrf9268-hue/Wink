import AppKit
import ApplicationServices

@MainActor
final class AppController {
    private let shortcutStore = ShortcutStore()
    private let persistenceService = PersistenceService()
    private let usageTracker = UsageTracker()
    private let hyperKeyService = HyperKeyService()
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
        usageTracker: usageTracker,
        hyperKeyService: hyperKeyService
    )

    func start() {
        DiagnosticLog.rotateIfNeeded()
        DiagnosticLog.log("Quickey starting, version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")

        // Set AX global messaging timeout to 1s (default is 6s).
        // Prevents AX calls from blocking threads for too long when apps are unresponsive.
        // Reference: alt-tab-macos
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        shortcutStore.replaceAll(with: persistenceService.load())
        hyperKeyService.reapplyIfNeeded()
        shortcutManager.start()
        shortcutManager.setHyperKeyEnabled(hyperKeyService.isEnabled)
        menuBarController.install()
    }

    func stop() {
        hyperKeyService.clearMappingIfEnabled()
        shortcutManager.stop()
    }

    private func openSettings() {
        settingsWindowController.show()
        NSApp.activate()
    }
}
