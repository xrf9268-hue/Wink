import AppKit
import Testing
@testable import Quickey

@Suite("Menu bar controller shortcut menu")
struct MenuBarControllerShortcutMenuTests {
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
        #expect(menu.items[0].title == "Safari")
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].title == "Settings")
        #expect(menu.items[3].isSeparatorItem)
        #expect(menu.items[4].title == "Launch at Login")
        #expect(menu.items[5].isSeparatorItem)
        #expect(menu.items[6].title == "Quit")
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
    func rebuildShortcutSection_usesInjectedShortcutStoreDataWhenPresentationsAreBuiltFromIt() {
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
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Settings", action: nil, keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q"))

        let presentations = MenuBarShortcutItemPresentation.build(
            from: store.shortcuts,
            runningBundleIdentifiers: ["com.apple.Safari"]
        )

        controller.rebuildShortcutSection(in: menu, presentations: presentations)

        #expect(menu.items[0].title == "Safari")
        #expect((menu.items[0].representedObject as? String) == MenuBarControllerMenuItemMarker.shortcutRow)
        #expect(menu.items[1].isSeparatorItem)
        #expect((menu.items[1].representedObject as? String) == MenuBarControllerMenuItemMarker.shortcutDivider)
        #expect(menu.items[2].title == "Settings")
        #expect(menu.items[4].title == "Launch at Login")
        #expect(menu.items[6].title == "Quit")
    }
}
