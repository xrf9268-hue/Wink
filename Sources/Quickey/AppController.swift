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

    func start() {
        DiagnosticLog.rotateIfNeeded()
        DiagnosticLog.log("Quickey starting, version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")

        // Set AX global messaging timeout to 1s (default is 6s).
        // Prevents AX calls from blocking threads for too long when apps are unresponsive.
        // Reference: alt-tab-macos
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        Self.runStartupSequence(
            loadShortcuts: { persistenceService.load() },
            replaceShortcuts: { shortcutStore.replaceAll(with: $0) },
            reapplyHyperIfNeeded: { hyperKeyService.reapplyIfNeeded() },
            isHyperEnabled: { hyperKeyService.isEnabled },
            setHyperKeyEnabled: { shortcutManager.setHyperKeyEnabled($0) },
            startShortcutManager: { shortcutManager.start() },
            installMenuBar: { menuBarController.install() }
        )
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
        loadShortcuts: @MainActor () -> [AppShortcut],
        replaceShortcuts: @MainActor ([AppShortcut]) -> Void,
        reapplyHyperIfNeeded: @MainActor () -> Void,
        isHyperEnabled: @MainActor () -> Bool,
        setHyperKeyEnabled: @MainActor (Bool) -> Void,
        startShortcutManager: @MainActor () -> Void,
        installMenuBar: @MainActor () -> Void
    ) {
        replaceShortcuts(loadShortcuts())
        reapplyHyperIfNeeded()
        setHyperKeyEnabled(isHyperEnabled())
        startShortcutManager()
        installMenuBar()
    }
}
