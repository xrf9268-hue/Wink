import Foundation

/// What a shortcut points at. `nil`/`.app` targets the app named by
/// `bundleIdentifier`; `.frontmostApp` resolves the target at press time.
enum ShortcutTarget: String, Codable, CaseIterable, Equatable, Sendable {
    case app
    case frontmostApp
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

    var isFrontmostAppTarget: Bool {
        target == .frontmostApp
    }

    /// `appName` resolved for display: the frontmost-app pseudo-target's
    /// persisted stable name renders as its localized label; every other
    /// shortcut's `appName` is already display-ready (an installed app's
    /// real name) and passes through unchanged. Use this at every UI site
    /// that renders a shortcut's app name — never render `appName` directly
    /// where a pseudo-target might appear.
    var displayAppName: String {
        bundleIdentifier == Self.frontmostTargetSentinelBundleIdentifier
            ? Self.frontmostTargetDisplayName
            : appName
    }

    init(
        id: UUID = UUID(),
        appName: String,
        bundleIdentifier: String,
        keyEquivalent: String,
        modifierFlags: [String],
        isEnabled: Bool = true,
        frontmostBehaviorOverride: FrontmostTargetBehavior? = nil,
        target: ShortcutTarget? = nil
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
        self.isEnabled = isEnabled
        self.frontmostBehaviorOverride = frontmostBehaviorOverride
        self.target = target
    }

    // Custom decoding solely for the override's leniency: shortcuts.json is
    // loaded strictly (any decode error quarantines the whole file), so an
    // unknown behavior rawValue written by a newer build must degrade to
    // "follow global" instead of throwing. Encoding stays synthesized
    // (nil omits the key, keeping files readable by older builds).
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
        // Unknown target values (from a newer build) decode to nil = .app;
        // the sentinel bundle then keeps the row harmlessly unavailable
        // rather than misfiring or failing the file.
        target = (try? container.decodeIfPresent(String.self, forKey: .target))
            .flatMap { ShortcutTarget(rawValue: $0) }
    }
}
