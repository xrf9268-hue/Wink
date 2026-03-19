import AppKit

@MainActor
final class MenuBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void

    init(onOpenSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
    }

    func install() {
        if let button = statusItem.button {
            button.title = "HotApp"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc
    private func openSettings() {
        onOpenSettings()
    }

    @objc
    private func quit() {
        onQuit()
    }
}
