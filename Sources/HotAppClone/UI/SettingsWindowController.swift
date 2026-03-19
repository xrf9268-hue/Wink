import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let shortcutStore: ShortcutStore
    private let shortcutManager: ShortcutManager
    private var window: NSWindow?

    init(shortcutStore: ShortcutStore, shortcutManager: ShortcutManager) {
        self.shortcutStore = shortcutStore
        self.shortcutManager = shortcutManager
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = SettingsViewModel(shortcutStore: shortcutStore, shortcutManager: shortcutManager)
        let contentView = SettingsView(viewModel: viewModel)
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
