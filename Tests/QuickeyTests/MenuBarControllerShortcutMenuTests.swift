import AppKit
import Testing
@testable import Quickey

@Suite("Menu bar controller shortcut menu")
struct MenuBarControllerShortcutMenuTests {
    @Test @MainActor
    func installMenuForTesting_buildsDynamicRowsAboveStaticSection() {
        let store = ShortcutStore()
        store.replaceAll(with: [
            AppShortcut(
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["control", "option"]
            )
        ])

        let controller = MenuBarController(
            onOpenSettings: {},
            onQuit: {},
            shortcutStore: store,
            runningBundleIdentifiers: { ["com.apple.Safari"] }
        )

        let menu = controller.installMenuForTesting()
        let row = try #require(menu.items[0].view as? MenuBarShortcutRowView)

        #expect(menu.items.count == 7)
        #expect(row.presentation.titleText == "Safari")
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].title == "Settings")
        #expect(menu.items[4].title == "Launch at Login")
        #expect(menu.items[6].title == "Quit")
    }

    @Test @MainActor
    func menuWillOpen_rebuildsCustomShortcutRowsFromInjectedStoreAndRunningBundles() {
        let store = ShortcutStore()
        store.replaceAll(with: [
            AppShortcut(
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["control", "option"]
            ),
            AppShortcut(
                appName: "IINA",
                bundleIdentifier: "com.colliderli.iina",
                keyEquivalent: "i",
                modifierFlags: ["control", "option"],
                isEnabled: false
            )
        ])

        let controller = MenuBarController(
            onOpenSettings: {},
            onQuit: {},
            shortcutStore: store,
            runningBundleIdentifiers: { ["com.apple.Safari"] }
        )
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Settings", action: nil, keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q"))

        controller.menuWillOpen(menu)

        let shortcutRows = menu.items.filter {
            ($0.representedObject as? String) == MenuBarControllerMenuItemMarker.shortcutRow
        }

        #expect(shortcutRows.count == 2)
        #expect(menu.items.count == 8)
        #expect(menu.items[0].view is MenuBarShortcutRowView)
        #expect(menu.items[1].view is MenuBarShortcutRowView)
        #expect(menu.items[2].isSeparatorItem)
        #expect(menu.items[3].title == "Settings")
        #expect(menu.items[4].isSeparatorItem)
        #expect(menu.items[5].title == "Launch at Login")
        #expect(menu.items[6].isSeparatorItem)
        #expect(menu.items[7].title == "Quit")

        let firstRow = try #require(menu.items[0].view as? MenuBarShortcutRowView)
        let secondRow = try #require(menu.items[1].view as? MenuBarShortcutRowView)

        #expect(firstRow.presentation.titleText == "Safari")
        #expect(firstRow.presentation.isRunning == true)
        #expect(firstRow.presentation.statusText == nil)
        #expect(firstRow.presentation.shortcutText == "⌃⌥S")
        #expect(menu.items[0].title == "Safari")
        #expect(secondRow.presentation.titleText == "IINA")
        #expect(secondRow.presentation.isRunning == false)
        #expect(secondRow.presentation.statusText == "disabled")
        #expect(secondRow.presentation.shortcutText == "⌃⌥I")
        #expect(menu.items[1].title == "IINA (disabled)")
    }

    @Test @MainActor
    func rebuildShortcutSection_replacesPreviousDynamicSectionAndPreservesStaticItems() {
        let controller = MenuBarController(onOpenSettings: {}, onQuit: {})
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Settings", action: nil, keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q"))

        let presentations = [
            MenuBarShortcutItemPresentation(
                bundleIdentifier: "com.apple.Safari",
                titleText: "Safari",
                shortcutText: "⌃⌥S",
                statusText: nil,
                isEnabled: true,
                isRunning: true,
                isPlaceholder: false
            )
        ]

        controller.rebuildShortcutSection(in: menu, presentations: presentations)
        controller.rebuildShortcutSection(in: menu, presentations: presentations)

        let shortcutRowMarkers = menu.items.filter {
            ($0.representedObject as? String) == MenuBarControllerMenuItemMarker.shortcutRow
        }
        let shortcutDividerMarkers = menu.items.filter {
            ($0.representedObject as? String) == MenuBarControllerMenuItemMarker.shortcutDivider
        }

        #expect(shortcutRowMarkers.count == 1)
        #expect(shortcutDividerMarkers.count == 1)
        #expect(menu.items.count == 7)
        #expect(menu.items[0].view is MenuBarShortcutRowView)
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].title == "Settings")
        #expect(menu.items[3].isSeparatorItem)
        #expect(menu.items[4].title == "Launch at Login")
        #expect(menu.items[5].isSeparatorItem)
        #expect(menu.items[6].title == "Quit")

        let row = try #require(menu.items[0].view as? MenuBarShortcutRowView)
        #expect(row.presentation.titleText == "Safari")
    }

    @Test @MainActor
    func rebuildShortcutSection_removesExistingDynamicItemsWhenPresentationsAreEmpty() {
        let controller = MenuBarController(onOpenSettings: {}, onQuit: {})
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Safari", action: nil, keyEquivalent: ""))
        menu.items[0].representedObject = MenuBarControllerMenuItemMarker.shortcutRow
        menu.addItem(.separator())
        menu.items[1].representedObject = MenuBarControllerMenuItemMarker.shortcutDivider
        menu.addItem(NSMenuItem(title: "Settings", action: nil, keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q"))

        controller.rebuildShortcutSection(in: menu, presentations: [])

        #expect(menu.items.count == 5)
        #expect(menu.items[0].title == "Settings")
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].title == "Launch at Login")
        #expect(menu.items[3].isSeparatorItem)
        #expect(menu.items[4].title == "Quit")
        #expect(menu.items.allSatisfy { ($0.representedObject as? String) == nil })
    }

    @Test @MainActor
    func shortcutPresentations_reflectInjectedShortcutStoreAndRunningBundleIdentifiers() {
        let store = ShortcutStore()
        store.replaceAll(with: [
            AppShortcut(
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["control", "option"]
            )
        ])

        let controller = MenuBarController(
            onOpenSettings: {},
            onQuit: {},
            shortcutStore: store,
            runningBundleIdentifiers: { ["com.apple.Safari", "com.apple.Terminal"] }
        )

        let presentations = controller.shortcutPresentations()

        #expect(presentations.count == 1)
        #expect(presentations[0].bundleIdentifier == "com.apple.Safari")
        #expect(presentations[0].titleText == "Safari")
        #expect(presentations[0].shortcutText == "⌃⌥S")
        #expect(presentations[0].isRunning == true)
        #expect(presentations[0].isEnabled == true)
    }

    @Test @MainActor
    func menuWillOpen_replacesPreviousDynamicRowsDeterministicallyAcrossRepeatedOpens() {
        let store = ShortcutStore()
        store.replaceAll(with: [
            AppShortcut(
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["control", "option"]
            )
        ])

        var runningBundles: Set<String> = ["com.apple.Safari"]
        let controller = MenuBarController(
            onOpenSettings: {},
            onQuit: {},
            shortcutStore: store,
            runningBundleIdentifiers: { runningBundles }
        )
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Settings", action: nil, keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q"))

        controller.menuWillOpen(menu)

        store.replaceAll(with: [
            AppShortcut(
                appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal",
                keyEquivalent: "t",
                modifierFlags: ["command"]
            )
        ])
        runningBundles = ["com.apple.Terminal"]

        controller.menuWillOpen(menu)

        let shortcutRows = menu.items.filter {
            ($0.representedObject as? String) == MenuBarControllerMenuItemMarker.shortcutRow
        }
        let shortcutDividers = menu.items.filter {
            ($0.representedObject as? String) == MenuBarControllerMenuItemMarker.shortcutDivider
        }
        let row = try #require(menu.items[0].view as? MenuBarShortcutRowView)

        #expect(shortcutRows.count == 1)
        #expect(shortcutDividers.count == 1)
        #expect(menu.items.count == 7)
        #expect(row.presentation.titleText == "Terminal")
        #expect(row.presentation.isRunning == true)
        #expect(row.presentation.shortcutText == "⌘T")
    }

    @Test @MainActor
    func disabledShortcutRow_rendersMutedAppearanceAndSemanticTitle() {
        let controller = MenuBarController(onOpenSettings: {}, onQuit: {})
        let menu = NSMenu()
        let presentation = MenuBarShortcutItemPresentation(
            bundleIdentifier: "com.colliderli.iina",
            titleText: "IINA",
            shortcutText: "⌃⌥I",
            statusText: "disabled",
            isEnabled: false,
            isRunning: false,
            isPlaceholder: false
        )

        controller.rebuildShortcutSection(in: menu, presentations: [presentation])

        let item = menu.items[0]
        let row = try #require(item.view as? MenuBarShortcutRowView)

        #expect(item.title == "IINA (disabled)")
        #expect(row.renderedTitleColor != NSColor.labelColor)
        #expect(row.renderedShortcutColor != NSColor.secondaryLabelColor)
        #expect(row.renderedIconAlpha < 1.0)
    }
}
