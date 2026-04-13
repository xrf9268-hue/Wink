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
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            button.image = NSImage(systemSymbolName: "bolt.square.fill", accessibilityDescription: "Quickey")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 18, height: 18)
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = menuItemState(for: launchAtLoginService.status)
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
        launchAtLoginItem?.state = menuItemState(for: launchAtLoginService.status)
    }

    @objc
    private func quit() {
        onQuit()
    }

    private func menuItemState(for status: LaunchAtLoginStatus) -> NSControl.StateValue {
        switch status {
        case .enabled:
            .on
        case .requiresApproval:
            .mixed
        case .disabled, .notFound:
            .off
        }
    }
}
