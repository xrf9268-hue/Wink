import Foundation

struct WinkRecipe: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var shortcuts: [WinkRecipeShortcut]

    init(
        schemaVersion: Int = WinkRecipe.currentSchemaVersion,
        shortcuts: [WinkRecipeShortcut]
    ) {
        self.schemaVersion = schemaVersion
        self.shortcuts = shortcuts
    }

    init(shortcuts: [AppShortcut]) {
        self.init(shortcuts: shortcuts.map(WinkRecipeShortcut.init))
    }
}

struct WinkRecipeShortcut: Codable, Equatable, Sendable {
    var appName: String
    var bundleIdentifier: String
    var keyEquivalent: String
    var modifierFlags: [String]
    var isEnabled: Bool

    init(
        appName: String,
        bundleIdentifier: String,
        keyEquivalent: String,
        modifierFlags: [String],
        isEnabled: Bool
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
        self.isEnabled = isEnabled
    }

    init(_ shortcut: AppShortcut) {
        self.init(
            appName: shortcut.appName,
            bundleIdentifier: shortcut.bundleIdentifier,
            keyEquivalent: shortcut.keyEquivalent,
            modifierFlags: shortcut.modifierFlags,
            isEnabled: shortcut.isEnabled
        )
    }
}
