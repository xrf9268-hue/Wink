import AppKit

enum MenuBarLaunchAtLoginToggleState: Equatable {
    case on
    case off
    case mixed

    var controlState: NSControl.StateValue {
        switch self {
        case .on:
            .on
        case .off:
            .off
        case .mixed:
            .mixed
        }
    }
}

enum MenuBarLaunchAtLoginAction: Equatable {
    case enable
    case disable
    case openLoginItemsSettings
    case unavailable
}

struct MenuBarLaunchAtLoginPresentation: Equatable {
    let title: String
    let state: MenuBarLaunchAtLoginToggleState
    let isEnabled: Bool
    let action: MenuBarLaunchAtLoginAction

    init(snapshot: LaunchAtLoginSnapshot) {
        switch snapshot.status {
        case .enabled:
            title = "Launch at Login"
            state = .on
            isEnabled = true
            action = .disable
        case .disabled:
            title = "Launch at Login"
            state = .off
            isEnabled = true
            action = .enable
        case .requiresApproval:
            title = "Approve Launch at Login..."
            state = .mixed
            isEnabled = true
            action = .openLoginItemsSettings
        case .notFound:
            switch snapshot.availability {
            case .requiresAppInApplicationsFolder:
                title = "Launch at Login (Move App to Applications)"
            case .available, .missingConfiguration:
                title = "Launch at Login (Configuration Missing)"
            }
            state = .off
            isEnabled = false
            action = .unavailable
        }
    }
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
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
        super.init()
    }

    func install() {
        if let button = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            button.image = NSImage(systemSymbolName: "bolt.square.fill", accessibilityDescription: "Wink")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 18, height: 18)
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem = loginItem
        menu.addItem(loginItem)
        refreshLaunchAtLoginItem()

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
        let presentation = MenuBarLaunchAtLoginPresentation(snapshot: launchAtLoginService.snapshot)

        switch presentation.action {
        case .enable:
            launchAtLoginService.setEnabled(true)
        case .disable:
            launchAtLoginService.setEnabled(false)
        case .openLoginItemsSettings:
            launchAtLoginService.openSystemSettingsLoginItems()
        case .unavailable:
            break
        }

        refreshLaunchAtLoginItem()
    }

    @objc
    private func quit() {
        onQuit()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLaunchAtLoginItem()
    }

    private func refreshLaunchAtLoginItem() {
        guard let launchAtLoginItem else { return }

        let presentation = MenuBarLaunchAtLoginPresentation(snapshot: launchAtLoginService.snapshot)
        launchAtLoginItem.title = presentation.title
        launchAtLoginItem.state = presentation.state.controlState
        launchAtLoginItem.isEnabled = presentation.isEnabled
    }
}
