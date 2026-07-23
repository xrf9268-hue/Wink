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
    /// True when the source carried a `target` key whose value was null or
    /// malformed (non-string). The gate must survive re-encoding as an
    /// explicit null so `shortcutTarget`'s absent-key backfill can never
    /// arm it (#404) — mirroring AppShortcut's persistedInvalidTarget.
    private var targetKeyPresentButInvalid: Bool

    private enum CodingKeys: String, CodingKey {
        case appName
        case bundleIdentifier
        case keyEquivalent
        case modifierFlags
        case isEnabled
        case frontmostBehaviorOverride
        case target
        case holdAction
    }

    init(
        appName: String,
        bundleIdentifier: String,
        keyEquivalent: String,
        modifierFlags: [String],
        isEnabled: Bool,
        frontmostBehaviorOverride: String? = nil,
        target: String? = nil,
        holdAction: String? = nil,
        targetKeyPresentButInvalid: Bool = false
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
        self.isEnabled = isEnabled
        self.frontmostBehaviorOverride = frontmostBehaviorOverride
        self.target = target
        self.holdAction = holdAction
        self.targetKeyPresentButInvalid = targetKeyPresentButInvalid
    }

    /// Custom decoding so the optional raw-string fields are fully lenient:
    /// a wrong-TYPE value (e.g. `"holdAction": 42` from a hand-edited or
    /// future-schema file) degrades that field to nil instead of rejecting
    /// the entire recipe — matching shortcuts.json's leniency contract.
    /// Required fields stay strict. Target-key PRESENCE is tracked so a
    /// null/malformed value stays distinguishable from a genuinely absent
    /// key (only the latter may backfill a sentinel kind, #404).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appName = try container.decode(String.self, forKey: .appName)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        keyEquivalent = try container.decode(String.self, forKey: .keyEquivalent)
        modifierFlags = try container.decode([String].self, forKey: .modifierFlags)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        frontmostBehaviorOverride = try? container.decodeIfPresent(String.self, forKey: .frontmostBehaviorOverride)
        if container.contains(.target) {
            target = try? container.decode(String.self, forKey: .target)
            targetKeyPresentButInvalid = (target == nil)
        } else {
            target = nil
            targetKeyPresentButInvalid = false
        }
        holdAction = try? container.decodeIfPresent(String.self, forKey: .holdAction)
    }

    /// Custom encoding mirrors the synthesized omit-nil shape, except a
    /// present-but-invalid target re-encodes as explicit null (#404).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appName, forKey: .appName)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(keyEquivalent, forKey: .keyEquivalent)
        try container.encode(modifierFlags, forKey: .modifierFlags)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(frontmostBehaviorOverride, forKey: .frontmostBehaviorOverride)
        if let target {
            try container.encode(target, forKey: .target)
        } else if targetKeyPresentButInvalid {
            try container.encodeNil(forKey: .target)
        }
        try container.encodeIfPresent(holdAction, forKey: .holdAction)
    }

    init(_ shortcut: AppShortcut) {
        // A locally gated invalid target must keep its gate in the export:
        // unknown strings travel verbatim; explicit null/malformed travels
        // as the invalid marker — otherwise importing the recipe elsewhere
        // would backfill and arm the row (#404).
        self.init(
            appName: shortcut.appName,
            bundleIdentifier: shortcut.bundleIdentifier,
            keyEquivalent: shortcut.keyEquivalent,
            modifierFlags: shortcut.modifierFlags,
            isEnabled: shortcut.isEnabled,
            frontmostBehaviorOverride: shortcut.frontmostBehaviorOverride?.rawValue,
            target: shortcut.target?.rawValue ?? shortcut.exportedInvalidTargetRawValue,
            holdAction: shortcut.holdAction?.rawValue,
            targetKeyPresentButInvalid: shortcut.hasPersistedInvalidTarget
                && shortcut.exportedInvalidTargetRawValue == nil
        )
    }

    /// Lenient enum mapping: absent or unknown raw values mean "follow
    /// the global setting".
    var behaviorOverride: FrontmostTargetBehavior? {
        frontmostBehaviorOverride.flatMap(FrontmostTargetBehavior.init(rawValue:))
    }

    /// Lenient enum mapping with the same absent-key backfill as
    /// `AppShortcut.init(from:)`: a GENUINELY ABSENT target on a KNOWN
    /// sentinel bundle means exactly that kind (#404) — which also keeps
    /// the import planner's search-palette exclusion airtight for
    /// hand-authored recipes that name the sentinel without the field.
    /// Unknown VALUES and present-but-invalid (null/malformed) values
    /// still mean `.app` (unavailable), never a guess.
    var shortcutTarget: ShortcutTarget? {
        guard let target else {
            if targetKeyPresentButInvalid {
                return nil
            }
            return AppShortcut.impliedTarget(forSentinelBundleIdentifier: bundleIdentifier)
        }
        return ShortcutTarget(rawValue: target)
    }

    /// Lenient enum mapping: absent or unknown raw values mean no hold action.
    var holdActionValue: HoldAction? {
        holdAction.flatMap(HoldAction.init(rawValue:))
    }

    /// The invalid-target gate this recipe row carries, in AppShortcut's
    /// own representation, so an accepted import persists the gate instead
    /// of an absent key the next load would backfill and arm (#404).
    var invalidTargetGate: AppShortcut.PersistedInvalidTarget? {
        if let target, ShortcutTarget(rawValue: target) == nil {
            return .unknownString(target)
        }
        if targetKeyPresentButInvalid {
            return .explicitNullOrMalformed
        }
        return nil
    }
}
