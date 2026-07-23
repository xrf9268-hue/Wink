import Foundation

/// What a shortcut points at. `nil`/`.app` targets the app named by
/// `bundleIdentifier`; `.frontmostApp` resolves the target at press time;
/// `.searchPalette` is the #356 search-to-switch trigger — it names no app
/// at all and is dispatched by `ShortcutManager` through
/// `onSearchPaletteTriggered` instead of `AppSwitcher.toggleApplication`.
enum ShortcutTarget: String, Codable, CaseIterable, Equatable, Sendable {
    case app
    case frontmostApp
    case searchPalette
}

/// What holding a shortcut chord past the hold threshold does. `nil` keeps
/// the pre-existing semantics: the action dispatches on key-down with no
/// release tracking, so non-opted-in shortcuts pay zero added latency.
enum HoldAction: String, Codable, CaseIterable, Equatable, Sendable {
    case windowPicker

    var title: String {
        switch self {
        case .windowPicker:
            return String(localized: "Window Picker", bundle: WinkResourceBundle.bundle)
        }
    }
}

struct AppShortcut: Codable, Identifiable, Hashable, Sendable {
    /// Sentinel `bundleIdentifier` stored by frontmost-app shortcuts. No
    /// such app exists, so builds that predate `target` decode the row as
    /// a normal shortcut and the availability filter silently disables it
    /// instead of misfiring.
    static let frontmostTargetSentinelBundleIdentifier = "wink.target.frontmost-app"

    /// Locale-stable name persisted into `appName` for frontmost-app
    /// pseudo-target shortcuts (new-shortcut creation, recipe import). Never
    /// localize this constant — it is written into shortcuts.json and
    /// exported .winkrecipe files, so it must stay identical across a system
    /// language switch (same locale-stable-persistence principle as #323).
    /// Use `frontmostTargetDisplayName` / `displayAppName` for anything
    /// rendered on screen.
    static let frontmostTargetStableName = "Current App"

    /// Localized label for the frontmost-app pseudo-target. Display-only —
    /// never persist this; see `frontmostTargetStableName`.
    static var frontmostTargetDisplayName: String {
        String(localized: "Current App", bundle: WinkResourceBundle.bundle)
    }

    /// Sentinel `bundleIdentifier` for the #356 search-palette trigger.
    /// Names no installed app, on purpose — same pattern as
    /// `frontmostTargetSentinelBundleIdentifier` — so a build that predates
    /// `target` decodes this row as a normal shortcut that the availability
    /// filter silently disables instead of misdispatching it.
    static let searchPaletteTargetSentinelBundleIdentifier = "wink.target.search-palette"

    /// Locale-stable name persisted into `appName` for the search-palette
    /// trigger shortcut. Never localize this constant; see
    /// `frontmostTargetStableName` for the same principle.
    static let searchPaletteTargetStableName = "Search Palette"

    /// Localized label for the search-palette trigger. Display-only — never
    /// persist this; see `searchPaletteTargetStableName`.
    static var searchPaletteTargetDisplayName: String {
        String(localized: "Search Palette", bundle: WinkResourceBundle.bundle)
    }

    let id: UUID
    var appName: String
    var bundleIdentifier: String
    var keyEquivalent: String
    var modifierFlags: [String]
    var isEnabled: Bool
    /// Per-shortcut override of the global frontmost-target behavior.
    /// `nil` follows the global setting.
    var frontmostBehaviorOverride: FrontmostTargetBehavior?
    /// `nil` means `.app` (the pre-existing semantics).
    var target: ShortcutTarget?
    /// Opt-in hold gesture for this shortcut. `nil` = plain key-down
    /// dispatch (no latency cost). Non-nil moves the shortcut to
    /// key-up-or-deadline dispatch: tap = the usual toggle, hold past the
    /// threshold = this action.
    var holdAction: HoldAction?
    /// A persisted `target` value that did not resolve to a known kind.
    /// Preserved and re-encoded so a save by this build cannot erase the
    /// gating — without it, "invalid value → nil → key omitted on save →
    /// backfilled as a live trigger on the next load" silently arms a row
    /// that was meant to stay unavailable (#404). Unknown strings re-encode
    /// verbatim (a newer build's intent survives round trips); an explicit
    /// null or malformed value re-encodes as null.
    private enum PersistedInvalidTarget: Hashable, Sendable, Codable {
        case unknownString(String)
        case explicitNullOrMalformed
    }
    private var persistedInvalidTarget: PersistedInvalidTarget?

    /// The target a KNOWN sentinel bundle identifier unambiguously implies,
    /// used to backfill files whose `target` field is absent (#404).
    static func impliedTarget(forSentinelBundleIdentifier bundleIdentifier: String) -> ShortcutTarget? {
        switch bundleIdentifier {
        case frontmostTargetSentinelBundleIdentifier:
            return .frontmostApp
        case searchPaletteTargetSentinelBundleIdentifier:
            return .searchPalette
        default:
            return nil
        }
    }

    var isFrontmostAppTarget: Bool {
        target == .frontmostApp
    }

    /// True for the #356 search-palette trigger shortcut. Its sentinel
    /// bundle names no app, so every site that resolves a real target
    /// (activation, the app icon cache, the per-app shortcut list) must
    /// check this before treating `bundleIdentifier` as an installed app.
    var isSearchPaletteTarget: Bool {
        target == .searchPalette
    }

    /// `appName` resolved for display: a pseudo-target's persisted stable
    /// name renders as its localized label; every other shortcut's
    /// `appName` is already display-ready (an installed app's real name)
    /// and passes through unchanged. Use this at every UI site that renders
    /// a shortcut's app name — never render `appName` directly where a
    /// pseudo-target might appear.
    var displayAppName: String {
        switch bundleIdentifier {
        case Self.frontmostTargetSentinelBundleIdentifier:
            return Self.frontmostTargetDisplayName
        case Self.searchPaletteTargetSentinelBundleIdentifier:
            return Self.searchPaletteTargetDisplayName
        default:
            return appName
        }
    }

    init(
        id: UUID = UUID(),
        appName: String,
        bundleIdentifier: String,
        keyEquivalent: String,
        modifierFlags: [String],
        isEnabled: Bool = true,
        frontmostBehaviorOverride: FrontmostTargetBehavior? = nil,
        target: ShortcutTarget? = nil,
        holdAction: HoldAction? = nil
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
        self.isEnabled = isEnabled
        self.frontmostBehaviorOverride = frontmostBehaviorOverride
        self.target = target
        self.holdAction = holdAction
        self.persistedInvalidTarget = nil
    }

    /// Explicit so `persistedInvalidTarget` never becomes its own persisted
    /// key — it re-encodes INTO `.target` (see `encode(to:)`).
    private enum CodingKeys: String, CodingKey {
        case id
        case appName
        case bundleIdentifier
        case keyEquivalent
        case modifierFlags
        case isEnabled
        case frontmostBehaviorOverride
        case target
        case holdAction
    }

    // Custom decoding solely for leniency: shortcuts.json is loaded
    // strictly (any decode error quarantines the whole file), so an unknown
    // rawValue written by a newer build must degrade instead of throwing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        appName = try container.decode(String.self, forKey: .appName)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        keyEquivalent = try container.decode(String.self, forKey: .keyEquivalent)
        modifierFlags = try container.decode([String].self, forKey: .modifierFlags)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        frontmostBehaviorOverride = (try? container.decodeIfPresent(String.self, forKey: .frontmostBehaviorOverride))
            .flatMap { FrontmostTargetBehavior(rawValue: $0) }
        if container.contains(.target) {
            // Present: a known string arms the kind. Anything else is a
            // gate that must hold across saves (#404): an unknown string is
            // a newer build's intent and re-encodes verbatim; an explicit
            // null or malformed value re-encodes as null. Either way the
            // key can never silently become absent and get backfilled by a
            // later load.
            if let rawTarget = try? container.decode(String.self, forKey: .target) {
                target = ShortcutTarget(rawValue: rawTarget)
                persistedInvalidTarget = (target == nil) ? .unknownString(rawTarget) : nil
            } else {
                target = nil
                persistedInvalidTarget = .explicitNullOrMalformed
            }
        } else {
            // Absent key: a hand-authored or third-party file that names a
            // KNOWN sentinel bundle and omits "target" means exactly that
            // kind — backfill it instead of shipping a row that renders
            // everywhere and fires nowhere (#404). Unknown future sentinels
            // keep nil = .app and stay unavailable.
            target = Self.impliedTarget(forSentinelBundleIdentifier: bundleIdentifier)
            persistedInvalidTarget = nil
        }
        // Same leniency: an unknown hold action from a newer build degrades
        // to plain key-down dispatch instead of quarantining the file.
        holdAction = (try? container.decodeIfPresent(String.self, forKey: .holdAction))
            .flatMap { HoldAction(rawValue: $0) }
    }

    // Custom encoding mirrors the synthesized shape (nil omits the key,
    // keeping files readable by older builds) with one addition: a
    // preserved invalid target re-encodes under `.target` — unknown strings
    // verbatim, explicit null / malformed values as null.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(appName, forKey: .appName)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(keyEquivalent, forKey: .keyEquivalent)
        try container.encode(modifierFlags, forKey: .modifierFlags)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(frontmostBehaviorOverride, forKey: .frontmostBehaviorOverride)
        if let target {
            try container.encode(target, forKey: .target)
        } else {
            switch persistedInvalidTarget {
            case .unknownString(let raw):
                try container.encode(raw, forKey: .target)
            case .explicitNullOrMalformed:
                try container.encodeNil(forKey: .target)
            case nil:
                break
            }
        }
        try container.encodeIfPresent(holdAction, forKey: .holdAction)
    }
}
