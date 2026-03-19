import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let shortcutStore: ShortcutStore
    private let shortcutManager: ShortcutManager
    private let usageTracker: UsageTracker?
    private var window: NSWindow?

    init(shortcutStore: ShortcutStore, shortcutManager: ShortcutManager, usageTracker: UsageTracker? = nil) {
        self.shortcutStore = shortcutStore
        self.shortcutManager = shortcutManager
        self.usageTracker = usageTracker
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = SettingsViewModel(shortcutStore: shortcutStore, shortcutManager: shortcutManager, usageTracker: usageTracker)
        let insightsViewModel = InsightsViewModel(usageTracker: usageTracker, shortcutStore: shortcutStore)
        let contentView = SettingsView(viewModel: viewModel, insightsViewModel: insightsViewModel)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "HotApp Clone"
        window.setContentSize(NSSize(width: 720, height: 480))
        window.styleMask.insert(.titled)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}
