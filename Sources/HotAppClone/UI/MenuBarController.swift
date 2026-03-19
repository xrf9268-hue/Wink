import AppKit

@MainActor
final class MenuBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private let launchAtLoginService: LaunchAtLoginService
    private var launchAtLoginItem: NSMenuItem?

    init(
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService()
    ) {
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.launchAtLoginService = launchAtLoginService
    }

    func install() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "command.square", accessibilityDescription: "Quickey")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = launchAtLoginService.isEnabled ? .on : .off
        launchAtLoginItem = loginItem
        menu.addItem(loginItem)

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
    private func toggleLaunchAtLogin() {
        let newState = !launchAtLoginService.isEnabled
        launchAtLoginService.setEnabled(newState)
        launchAtLoginItem?.state = launchAtLoginService.isEnabled ? .on : .off
    }

    @objc
    private func quit() {
        onQuit()
    }
}
