import Testing
@testable import Wink

@Suite("Menu bar shortcut item presentation")
struct MenuBarShortcutItemPresentationTests {
    @Test
    func buildPreservesShortcutOrderAndMapsSharedStatusSemantics() {
        let safari = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
        let ghostty = AppShortcut(
            appName: "Ghostty",
            bundleIdentifier: "com.mitchellh.ghostty",
            keyEquivalent: "g",
            modifierFlags: ["command"],
            isEnabled: false
        )

        let presentations = MenuBarShortcutItemPresentation.build(from: [safari, ghostty]) { shortcut in
            switch shortcut.bundleIdentifier {
            case "com.apple.Safari":
                ShortcutRuntimeStatus(isRunning: true, isUnavailable: false)
            case "com.mitchellh.ghostty":
                ShortcutRuntimeStatus(isRunning: false, isUnavailable: true)
            default:
                .normal
            }
        }

        #expect(presentations.map(\.titleText) == ["Safari", "Ghostty"])
        #expect(presentations.map(\.shortcutText) == ["⌘S", "⌘G"])
        #expect(presentations.map(\.isRunning) == [true, false])
        #expect(presentations.map(\.isUnavailable) == [false, true])
        #expect(presentations[0].statusText == nil)
        #expect(presentations[1].statusText == "Disabled")
        #expect(presentations[1].unavailableStatusText == "App unavailable")
        #expect(
            presentations[1].unavailableHelpText
            == "Couldn't find this app. Rebind it to restore the shortcut."
        )
    }

    @Test
    func buildReturnsPlaceholderWhenNoShortcutsConfigured() {
        let presentations = MenuBarShortcutItemPresentation.build(from: []) { _ in
            .normal
        }

        #expect(presentations == [.placeholder])
    }

    @Test
    func accessibilityTitleIncludesShortcutAndStatusContext() {
        let presentation = MenuBarShortcutItemPresentation(
            shortcut: AppShortcut(
                appName: "Ghostty",
                bundleIdentifier: "com.mitchellh.ghostty",
                keyEquivalent: "g",
                modifierFlags: ["command"],
                isEnabled: false
            ),
            runtimeStatus: ShortcutRuntimeStatus(
                isRunning: false,
                isUnavailable: true
            )
        )

        #expect(
            presentation.accessibilityTitle
            == "Ghostty, ⌘G, Disabled, App unavailable"
        )
    }
}
