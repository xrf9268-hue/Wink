import AppKit

enum MenuBarControllerMenuItemMarker {
    static let shortcutRow = "quickey.menu-bar-controller.shortcut-row"
    static let shortcutDivider = "quickey.menu-bar-controller.shortcut-divider"
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
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private let launchAtLoginService: LaunchAtLoginService
    private let shortcutStore: ShortcutStore
    private let runningBundleIdentifiers: @MainActor () -> Set<String>
    private var launchAtLoginItem: NSMenuItem?

    init(
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        shortcutStore: ShortcutStore = ShortcutStore(),
        runningBundleIdentifiers: @escaping @MainActor () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
    ) {
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.launchAtLoginService = launchAtLoginService
        self.shortcutStore = shortcutStore
        self.runningBundleIdentifiers = runningBundleIdentifiers
        super.init()
    }

    func install() {
        if let button = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            button.image = NSImage(systemSymbolName: "bolt.square.fill", accessibilityDescription: "Quickey")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 18, height: 18)
        }

        statusItem.menu = makeInstalledMenu()
    }

    func installMenuForTesting() -> NSMenu {
        let menu = makeInstalledMenu()
        statusItem.menu = menu
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

    func menuWillOpen(_ menu: NSMenu) {
        refreshLaunchAtLoginItem()
        rebuildShortcutSection(in: menu, presentations: shortcutPresentations())
    }

    func rebuildShortcutSection(
        in menu: NSMenu,
        presentations: [MenuBarShortcutItemPresentation]
    ) {
        removeShortcutSection(from: menu)

        guard !presentations.isEmpty else {
            return
        }

        var insertionIndex = 0
        for presentation in presentations {
            menu.insertItem(makeShortcutItem(from: presentation), at: insertionIndex)
            insertionIndex += 1
        }
        menu.insertItem(makeShortcutDivider(), at: insertionIndex)
    }

    func shortcutPresentations() -> [MenuBarShortcutItemPresentation] {
        MenuBarShortcutItemPresentation.build(
            from: shortcutStore.shortcuts,
            runningBundleIdentifiers: runningBundleIdentifiers()
        )
    }

    private func removeShortcutSection(from menu: NSMenu) {
        for item in menu.items.reversed() where isShortcutSectionItem(item) {
            menu.removeItem(item)
        }
    }

    private func isShortcutSectionItem(_ item: NSMenuItem) -> Bool {
        (item.representedObject as? String) == MenuBarControllerMenuItemMarker.shortcutRow
            || (item.representedObject as? String) == MenuBarControllerMenuItemMarker.shortcutDivider
    }

    private func makeShortcutItem(from presentation: MenuBarShortcutItemPresentation) -> NSMenuItem {
        let item = NSMenuItem(title: shortcutItemTitle(for: presentation), action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = MenuBarShortcutRowView(presentation: presentation)
        item.representedObject = MenuBarControllerMenuItemMarker.shortcutRow
        return item
    }

    private func makeShortcutDivider() -> NSMenuItem {
        let item = NSMenuItem.separator()
        item.representedObject = MenuBarControllerMenuItemMarker.shortcutDivider
        return item
    }

    private func makeInstalledMenu() -> NSMenu {
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
        rebuildShortcutSection(in: menu, presentations: shortcutPresentations())
        return menu
    }

    private func shortcutItemTitle(for presentation: MenuBarShortcutItemPresentation) -> String {
        if let statusText = presentation.statusText, !statusText.isEmpty {
            return "\(presentation.titleText) (\(statusText))"
        }
        return presentation.titleText
    }

    private func refreshLaunchAtLoginItem() {
        guard let launchAtLoginItem else { return }

        let presentation = MenuBarLaunchAtLoginPresentation(snapshot: launchAtLoginService.snapshot)
        launchAtLoginItem.title = presentation.title
        launchAtLoginItem.state = presentation.state.controlState
        launchAtLoginItem.isEnabled = presentation.isEnabled
    }
}
