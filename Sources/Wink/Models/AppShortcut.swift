import Foundation

struct AppShortcut: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var appName: String
    var bundleIdentifier: String
    var keyEquivalent: String
    var modifierFlags: [String]
    var isEnabled: Bool
    /// Per-shortcut override of the global frontmost-target behavior.
    /// `nil` follows the global setting.
    var frontmostBehaviorOverride: FrontmostTargetBehavior?

    init(
        id: UUID = UUID(),
        appName: String,
        bundleIdentifier: String,
        keyEquivalent: String,
        modifierFlags: [String],
        isEnabled: Bool = true,
        frontmostBehaviorOverride: FrontmostTargetBehavior? = nil
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
        self.isEnabled = isEnabled
        self.frontmostBehaviorOverride = frontmostBehaviorOverride
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
    }
}
