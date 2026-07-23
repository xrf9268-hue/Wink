import Foundation

struct WinkRecipe: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    /// Version written when a recipe contains features older builds must
    /// reject cleanly (frontmost-app targets): those builds' strict
    /// version check fails with unsupportedSchemaVersion instead of
    /// importing rows they would render as dead sentinels.
    static let frontmostTargetSchemaVersion = 2
    static let supportedSchemaVersions = 1...2

    var schemaVersion: Int
    var shortcuts: [WinkRecipeShortcut]

    init(
        schemaVersion: Int? = nil,
        shortcuts: [WinkRecipeShortcut]
    ) {
        // Content-driven default: plain recipes stay v1 for maximum
        // compatibility; only recipes carrying frontmost-app targets pay
        // the v2 rejection on older builds.
        self.schemaVersion = schemaVersion ?? (
            shortcuts.contains { $0.shortcutTarget == .frontmostApp }
                ? WinkRecipe.frontmostTargetSchemaVersion
                : WinkRecipe.currentSchemaVersion
        )
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
    /// Raw string for the same leniency reasons; `.frontmostApp` content
    /// additionally bumps the recipe's schema version so pre-target builds
    /// reject the file cleanly.
    var target: String?
    /// Raw string, same leniency pattern: absent/unknown means no hold
    /// action, and older builds ignore the extra optional key (schema v1).
    var holdAction: String?

    init(
        appName: String,
        bundleIdentifier: String,
        keyEquivalent: String,
        modifierFlags: [String],
        isEnabled: Bool,
        frontmostBehaviorOverride: String? = nil,
        target: String? = nil,
        holdAction: String? = nil
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
        self.isEnabled = isEnabled
        self.frontmostBehaviorOverride = frontmostBehaviorOverride
        self.target = target
        self.holdAction = holdAction
    }

    /// Custom decoding so the optional raw-string fields are fully lenient:
    /// a wrong-TYPE value (e.g. `"holdAction": 42` from a hand-edited or
    /// future-schema file) degrades that field to nil instead of rejecting
    /// the entire recipe — matching shortcuts.json's leniency contract.
    /// Required fields stay strict.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appName = try container.decode(String.self, forKey: .appName)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        keyEquivalent = try container.decode(String.self, forKey: .keyEquivalent)
        modifierFlags = try container.decode([String].self, forKey: .modifierFlags)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        frontmostBehaviorOverride = try? container.decodeIfPresent(String.self, forKey: .frontmostBehaviorOverride)
        target = try? container.decodeIfPresent(String.self, forKey: .target)
        holdAction = try? container.decodeIfPresent(String.self, forKey: .holdAction)
    }

    init(_ shortcut: AppShortcut) {
        self.init(
            appName: shortcut.appName,
            bundleIdentifier: shortcut.bundleIdentifier,
            keyEquivalent: shortcut.keyEquivalent,
            modifierFlags: shortcut.modifierFlags,
            isEnabled: shortcut.isEnabled,
            frontmostBehaviorOverride: shortcut.frontmostBehaviorOverride?.rawValue,
            target: shortcut.target?.rawValue,
            holdAction: shortcut.holdAction?.rawValue
        )
    }

    /// Lenient enum mapping: absent or unknown raw values mean "follow
    /// the global setting".
    var behaviorOverride: FrontmostTargetBehavior? {
        frontmostBehaviorOverride.flatMap(FrontmostTargetBehavior.init(rawValue:))
    }

    /// Lenient enum mapping with the same absent-key backfill as
    /// `AppShortcut.init(from:)`: an ABSENT target on a KNOWN sentinel
    /// bundle means exactly that kind (#404) — which also keeps the import
    /// planner's search-palette exclusion airtight for hand-authored
    /// recipes that name the sentinel without the field. Unknown VALUES
    /// still mean `.app` (unavailable), never a guess.
    var shortcutTarget: ShortcutTarget? {
        guard let target else {
            return AppShortcut.impliedTarget(forSentinelBundleIdentifier: bundleIdentifier)
        }
        return ShortcutTarget(rawValue: target)
    }

    /// Lenient enum mapping: absent or unknown raw values mean no hold action.
    var holdActionValue: HoldAction? {
        holdAction.flatMap(HoldAction.init(rawValue:))
    }
}
