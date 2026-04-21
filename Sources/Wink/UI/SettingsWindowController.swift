import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let shortcutStore: ShortcutStore
    private let shortcutManager: ShortcutManager
    private let usageTracker: UsageTracker?
    private let hyperKeyService: HyperKeyService?
    private let updateService: UpdateServicing?
    private let shortcutStatusProvider: ShortcutStatusProvider
    private var window: NSWindow?

    init(
        shortcutStore: ShortcutStore,
        shortcutManager: ShortcutManager,
        usageTracker: UsageTracker? = nil,
        hyperKeyService: HyperKeyService? = nil,
        updateService: UpdateServicing? = nil,
        shortcutStatusProvider: ShortcutStatusProvider = ShortcutStatusProvider()
    ) {
        self.shortcutStore = shortcutStore
        self.shortcutManager = shortcutManager
        self.usageTracker = usageTracker
        self.hyperKeyService = hyperKeyService
        self.updateService = updateService
        self.shortcutStatusProvider = shortcutStatusProvider
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let preferences = AppPreferences(
            shortcutManager: shortcutManager,
            hyperKeyService: hyperKeyService,
            updateService: updateService
        )
        let editor = ShortcutEditorState(
            shortcutStore: shortcutStore,
            shortcutManager: shortcutManager,
            usageTracker: usageTracker,
            onShortcutConfigurationChange: {
                preferences.refreshPermissions()
            }
        )
        let insightsViewModel = InsightsViewModel(usageTracker: usageTracker, shortcutStore: shortcutStore)
        let appListProvider = AppListProvider()
        let contentView = SettingsView(
            editor: editor,
            preferences: preferences,
            insightsViewModel: insightsViewModel,
            appListProvider: appListProvider,
            shortcutStatusProvider: shortcutStatusProvider
        )
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Wink"
        window.setContentSize(NSSize(width: 720, height: 560))
        window.styleMask.insert(.titled)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}
