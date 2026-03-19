import Testing
@testable import HotAppClone

@Test
func appShortcutStoresBundleIdentifier() {
    let shortcut = AppShortcut(
        appName: "Slack",
        bundleIdentifier: "com.tinyspeck.slackmacgap",
        keyEquivalent: "s",
        modifierFlags: ["command", "option", "control", "shift"]
    )

    #expect(shortcut.bundleIdentifier == "com.tinyspeck.slackmacgap")
}
