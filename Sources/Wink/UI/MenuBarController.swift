import AppKit

enum MenuBarControllerMenuItemMarker: String {
    case shortcutHeader = "menuBar.shortcutHeader"
    case shortcutRow = "menuBar.shortcutRow"
    case shortcutDivider = "menuBar.shortcutDivider"
}

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
    private let shortcutStore: ShortcutStore
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private let launchAtLoginService: LaunchAtLoginService
    private let shortcutStatusProvider: ShortcutStatusProvider
    private var launchAtLoginItem: NSMenuItem?

    init(
        shortcutStore: ShortcutStore = ShortcutStore(),
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        shortcutStatusProvider: ShortcutStatusProvider = ShortcutStatusProvider()
    ) {
        self.shortcutStore = shortcutStore
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.launchAtLoginService = launchAtLoginService
        self.shortcutStatusProvider = shortcutStatusProvider
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

        statusItem.menu = buildMenu()
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        launchAtLoginItem = loginItem
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        rebuildShortcutSection(in: menu)
        refreshLaunchAtLoginItem()

        return menu
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

    @objc
    private func ignoreShortcutRowSelection() {
        // AppKit does not reliably render view-backed menu items when the item
        // itself is disabled. Keep these rows inert via a no-op action instead.
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildShortcutSection(in: menu)
        refreshLaunchAtLoginItem()
    }

    func rebuildShortcutSection(in menu: NSMenu) {
        let shortcuts = shortcutStore.shortcuts
        shortcutStatusProvider.track(shortcuts)

        let presentations = MenuBarShortcutItemPresentation.build(from: shortcuts) { shortcut in
            shortcutStatusProvider.status(for: shortcut)
        }
        rebuildShortcutSection(in: menu, presentations: presentations)
    }

    func rebuildShortcutSection(
        in menu: NSMenu,
        presentations: [MenuBarShortcutItemPresentation]
    ) {
        for item in menu.items.reversed() {
            guard
                let marker = item.representedObject as? String,
                marker == MenuBarControllerMenuItemMarker.shortcutHeader.rawValue ||
                    marker == MenuBarControllerMenuItemMarker.shortcutRow.rawValue ||
                    marker == MenuBarControllerMenuItemMarker.shortcutDivider.rawValue
            else {
                continue
            }

            menu.removeItem(item)
        }

        let headerItem = makeShortcutSectionHeaderItem()
        menu.insertItem(headerItem, at: 0)

        var insertionIndex = 1
        for presentation in presentations {
            menu.insertItem(makeShortcutItem(from: presentation), at: insertionIndex)
            insertionIndex += 1
        }

        let divider = NSMenuItem.separator()
        divider.representedObject = MenuBarControllerMenuItemMarker.shortcutDivider.rawValue
        menu.insertItem(divider, at: insertionIndex)
    }

    private func refreshLaunchAtLoginItem() {
        guard let launchAtLoginItem else { return }

        let presentation = MenuBarLaunchAtLoginPresentation(snapshot: launchAtLoginService.snapshot)
        launchAtLoginItem.title = presentation.title
        launchAtLoginItem.state = presentation.state.controlState
        launchAtLoginItem.isEnabled = presentation.isEnabled
    }

    private func makeShortcutItem(
        from presentation: MenuBarShortcutItemPresentation
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: presentation.accessibilityTitle,
            action: #selector(ignoreShortcutRowSelection),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = true
        item.view = MenuBarShortcutRowView(presentation: presentation)
        item.representedObject = MenuBarControllerMenuItemMarker.shortcutRow.rawValue
        item.toolTip = presentation.unavailableHelpText
        return item
    }

    private func makeShortcutSectionHeaderItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.representedObject = MenuBarControllerMenuItemMarker.shortcutHeader.rawValue
        item.attributedTitle = NSAttributedString(
            string: "SHORTCUTS",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return item
    }
}
