import AppKit
import Foundation
import Testing
@testable import Wink

@Suite("Menu bar controller shortcut menu")
struct MenuBarControllerShortcutMenuTests {
    @Test @MainActor
    func buildMenuPlacesDynamicRowsAboveStaticItems() throws {
        ensureAppKitApplication()
        let store = ShortcutStore()
        store.replaceAll(with: [
            AppShortcut(
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["command"]
            )
        ])
        let statusState = ShortcutStatusProviderState(
            applicationURLs: [
                "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app")
            ],
            runningBundleIdentifiers: ["com.apple.Safari"]
        )
        let controller = MenuBarController(
            shortcutStore: store,
            onOpenSettings: {},
            onQuit: {},
            launchAtLoginService: makeLaunchAtLoginService(),
            shortcutStatusProvider: makeShortcutStatusProvider(state: statusState)
        )

        let menu = controller.buildMenu()
        let row = try #require(menu.items[1].view as? MenuBarShortcutRowView)

        #expect(menu.items.count == 8)
        #expect(menu.items[0].title == "SHORTCUTS")
        #expect(menu.items[0].isEnabled == false)
        #expect(row.presentation.titleText == "Safari")
        #expect(row.presentation.isRunning == true)
        #expect(menu.items[1].title == "Safari, ⌘S, Running")
        #expect(menu.items[1].isEnabled == true)
        #expect(menu.items[2].isSeparatorItem)
        #expect(menu.items[3].title == "Settings")
        #expect(menu.items[4].isSeparatorItem)
        #expect(menu.items[5].title == "Launch at Login")
        #expect(menu.items[6].isSeparatorItem)
        #expect(menu.items[7].title == "Quit")
    }

    @Test @MainActor
    func menuWillOpenRebuildsShortcutSectionWithoutDuplicatingRows() throws {
        ensureAppKitApplication()
        let store = ShortcutStore()
        store.replaceAll(with: [
            AppShortcut(
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["command"]
            )
        ])
        let statusState = ShortcutStatusProviderState(
            applicationURLs: [
                "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app")
            ],
            runningBundleIdentifiers: ["com.apple.Safari"]
        )
        let controller = MenuBarController(
            shortcutStore: store,
            onOpenSettings: {},
            onQuit: {},
            launchAtLoginService: makeLaunchAtLoginService(),
            shortcutStatusProvider: makeShortcutStatusProvider(state: statusState)
        )
        let menu = controller.buildMenu()

        store.replaceAll(with: [
            AppShortcut(
                appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal",
                keyEquivalent: "t",
                modifierFlags: ["command", "shift"]
            )
        ])
        statusState.applicationURLs = [
            "com.apple.Terminal": URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")
        ]
        statusState.runningBundleIdentifiers = ["com.apple.Terminal"]

        controller.menuWillOpen(menu)

        let shortcutRows = menu.items.filter {
            ($0.representedObject as? String) == MenuBarControllerMenuItemMarker.shortcutRow.rawValue
        }
        let shortcutHeaders = menu.items.filter {
            ($0.representedObject as? String) == MenuBarControllerMenuItemMarker.shortcutHeader.rawValue
        }
        let shortcutDividers = menu.items.filter {
            ($0.representedObject as? String) == MenuBarControllerMenuItemMarker.shortcutDivider.rawValue
        }
        let row = try #require(menu.items[1].view as? MenuBarShortcutRowView)

        #expect(shortcutRows.count == 1)
        #expect(shortcutHeaders.count == 1)
        #expect(shortcutDividers.count == 1)
        #expect(menu.items.count == 8)
        #expect(menu.items[0].title == "SHORTCUTS")
        #expect(row.presentation.titleText == "Terminal")
        #expect(row.presentation.shortcutText == "⌘⇧T")
        #expect(row.presentation.isRunning == true)
        #expect(menu.items[1].title == "Terminal, ⌘⇧T, Running")
        #expect(menu.items[3].title == "Settings")
        #expect(menu.items[5].title == "Launch at Login")
        #expect(menu.items[7].title == "Quit")
    }

    @Test @MainActor
    func unavailableDisabledRowShowsWarningIconAndMutedContent() throws {
        ensureAppKitApplication()
        let controller = MenuBarController(
            onOpenSettings: {},
            onQuit: {},
            launchAtLoginService: makeLaunchAtLoginService()
        )
        let menu = NSMenu()
        let presentation = MenuBarShortcutItemPresentation(
            bundleIdentifier: "com.mitchellh.ghostty",
            titleText: "Ghostty",
            shortcutText: "⌘G",
            statusText: "Disabled",
            unavailableStatusText: "App unavailable",
            unavailableHelpText: "Couldn't find this app. Rebind it to restore the shortcut.",
            isEnabled: false,
            isRunning: false,
            isUnavailable: true,
            isPlaceholder: false
        )

        controller.rebuildShortcutSection(in: menu, presentations: [presentation])

        #expect(menu.items[0].title == "SHORTCUTS")

        let item = menu.items[1]
        let row = try #require(item.view as? MenuBarShortcutRowView)

        #expect(item.title == "Ghostty, ⌘G, Disabled, App unavailable")
        #expect(row.isWarningHidden == false)
        #expect(row.isRunningDotHidden == true)
        #expect(row.isStatusLabelHidden == false)
        #expect(row.renderedStatusText == "Disabled")
        #expect(
            row.renderedToolTip
            == "Couldn't find this app. Rebind it to restore the shortcut."
        )
        #expect(row.renderedTitleColor != NSColor.labelColor)
        #expect(row.renderedShortcutColor != NSColor.secondaryLabelColor)
    }

    @Test @MainActor
    func emptyShortcutStoreUsesPlaceholderRow() throws {
        ensureAppKitApplication()
        let controller = MenuBarController(
            onOpenSettings: {},
            onQuit: {},
            launchAtLoginService: makeLaunchAtLoginService()
        )

        let menu = controller.buildMenu()
        let row = try #require(menu.items[1].view as? MenuBarShortcutRowView)

        #expect(menu.items.count == 8)
        #expect(menu.items[0].title == "SHORTCUTS")
        #expect(row.presentation.isPlaceholder == true)
        #expect(menu.items[1].title == "No shortcuts configured")
        #expect(row.isRunningDotHidden == true)
        #expect(row.isWarningHidden == true)
        #expect(row.isStatusLabelHidden == true)
    }
}

private func makeLaunchAtLoginService() -> LaunchAtLoginService {
    LaunchAtLoginService(
        client: .init(
            status: { .notRegistered },
            register: {},
            unregister: {},
            openSystemSettingsLoginItems: {}
        )
    )
}

@MainActor
private func ensureAppKitApplication() {
    _ = NSApplication.shared
}

@MainActor
private func makeShortcutStatusProvider(
    state: ShortcutStatusProviderState
) -> ShortcutStatusProvider {
    ShortcutStatusProvider(
        client: .init(
            applicationURL: { bundleIdentifier in
                state.applicationURLs[bundleIdentifier]
            },
            runningBundleIdentifiers: {
                state.runningBundleIdentifiers
            }
        ),
        workspaceNotificationCenter: NotificationCenter(),
        appNotificationCenter: NotificationCenter()
    )
}

@MainActor
private final class ShortcutStatusProviderState {
    var applicationURLs: [String: URL]
    var runningBundleIdentifiers: Set<String>

    init(
        applicationURLs: [String: URL] = [:],
        runningBundleIdentifiers: Set<String> = []
    ) {
        self.applicationURLs = applicationURLs
        self.runningBundleIdentifiers = runningBundleIdentifiers
    }
}
