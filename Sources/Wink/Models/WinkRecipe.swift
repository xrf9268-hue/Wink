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
    /// Raw string on purpose (schema stays v1): decoding never fails on a
    /// behavior value this build doesn't know, and older builds simply
    /// ignore the extra optional key. Mapped to the enum at import time.
    var frontmostBehaviorOverride: String?

    init(
        appName: String,
        bundleIdentifier: String,
        keyEquivalent: String,
        modifierFlags: [String],
        isEnabled: Bool,
        frontmostBehaviorOverride: String? = nil
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
        self.isEnabled = isEnabled
        self.frontmostBehaviorOverride = frontmostBehaviorOverride
    }

    init(_ shortcut: AppShortcut) {
        self.init(
            appName: shortcut.appName,
            bundleIdentifier: shortcut.bundleIdentifier,
            keyEquivalent: shortcut.keyEquivalent,
            modifierFlags: shortcut.modifierFlags,
            isEnabled: shortcut.isEnabled,
            frontmostBehaviorOverride: shortcut.frontmostBehaviorOverride?.rawValue
        )
    }

    /// Lenient enum mapping: absent or unknown raw values mean "follow
    /// the global setting".
    var behaviorOverride: FrontmostTargetBehavior? {
        frontmostBehaviorOverride.flatMap(FrontmostTargetBehavior.init(rawValue:))
    }
}
