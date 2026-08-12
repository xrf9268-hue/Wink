import Foundation

/// One named set of shortcut bindings.
///
/// Identity is the UUID, never the name: renaming must not orphan the active
/// pointer or any future automation reference. Names are user data — they are
/// never used to build persistence keys, notification identifiers, or any
/// other durable identity (the locale-stable-identity rule from #323).
struct ShortcutProfile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }
}

/// Rules for profile names. Uniqueness is required because menus — and, later,
/// Focus Filter configuration — address a profile by the name the user reads;
/// two profiles a user cannot tell apart make both unusable.
enum ShortcutProfileNameRules {
    static let maximumLength = 64

    enum Violation: Equatable, Sendable {
        case empty
        case tooLong(limit: Int)
        case duplicate(existingProfileID: UUID)
    }

    static func trimmed(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Comparison key for uniqueness. Canonical composition first, so "é"
    /// typed as one scalar and as "e" + combining accent collide as the user
    /// expects, then a locale-independent lowercasing (`lowercased()`, unlike
    /// `lowercased(with:)`, does not consult the current locale — a Turkish
    /// system must not change whether two profile names collide).
    ///
    /// This key is computed for comparison only and is never persisted, so it
    /// is not bound by the locale-stable-persistence rule.
    static func comparisonKey(_ name: String) -> String {
        trimmed(name).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Returns the first violated rule, or nil when `raw` is an acceptable
    /// name. `excluding` is the profile being renamed, which must not collide
    /// with itself.
    static func violation(
        for raw: String,
        excluding excludedProfileID: UUID? = nil,
        in profiles: [ShortcutProfile]
    ) -> Violation? {
        let name = trimmed(raw)
        guard !name.isEmpty else {
            return .empty
        }
        guard name.count <= maximumLength else {
            return .tooLong(limit: maximumLength)
        }

        let key = comparisonKey(name)
        if let collision = profiles.first(where: {
            $0.id != excludedProfileID && comparisonKey($0.name) == key
        }) {
            return .duplicate(existingProfileID: collision.id)
        }

        return nil
    }

    /// `base`, `base copy`, `base copy 2`, … — the first spelling that does
    /// not collide. Falls back to appending the profile's UUID if every
    /// candidate up to the profile cap is taken, so this can never loop.
    static func duplicateName(
        basedOn base: String,
        in profiles: [ShortcutProfile],
        fallbackSuffix: UUID
    ) -> String {
        let trimmedBase = trimmed(base)

        // Bounded by the profile cap plus one: with at most that many
        // profiles in existence, one of these spellings is guaranteed free,
        // so the loop cannot run long. The fallback below exists only so the
        // function is total even if the cap is ever raised without revisiting
        // this code.
        for attempt in 1...(ShortcutProfileManifest.maximumProfileCount + 1) {
            // Truncate the BASE, never the finished candidate: clamping the
            // whole string would throw the suffix away first, so a
            // maximum-length source name would produce its own name back and
            // every candidate would collide with it.
            let candidate = clampedCandidate(base: trimmedBase, attempt: attempt)
            if violation(for: candidate, in: profiles) == nil {
                return candidate
            }
        }

        let suffix = " \(fallbackSuffix.uuidString)"
        let base = String(trimmedBase.prefix(max(0, maximumLength - suffix.count)))
        return String((base + suffix).suffix(maximumLength))
    }

    /// Builds one candidate, shrinking the base until the whole name fits.
    private static func clampedCandidate(base: String, attempt: Int) -> String {
        var base = base
        while true {
            let candidate = attempt == 1
                ? String(localized: "\(base) copy", bundle: WinkResourceBundle.bundle)
                : String(localized: "\(base) copy \(attempt)", bundle: WinkResourceBundle.bundle)
            if candidate.count <= maximumLength || base.isEmpty {
                return String(candidate.prefix(maximumLength))
            }
            base = String(base.dropLast(candidate.count - maximumLength))
        }
    }
}

/// The profile list. Rewritten only by CRUD, never by a switch — the active
/// pointer lives in its own file so a crash while switching cannot damage the
/// list of profiles.
struct ShortcutProfileManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumProfileCount = 32

    var schemaVersion: Int
    /// User-visible list order. Preserved on every write.
    var profiles: [ShortcutProfile]
    /// Shortcut ids whose usage rows a completed profile deletion still owes.
    /// Written in the same commit as the removal so a crash between the two
    /// cannot strand them — by the time the profile is gone, the inventory
    /// needed to recompute exclusivity is gone with it. Optional so a manifest
    /// without it stays valid.
    var pendingUsageDeletions: [UUID]?
    /// Set when first-run migration could not read the legacy
    /// `shortcuts.json`. Carried in the manifest because the failure would
    /// otherwise exist only in the returned load state: migration never runs
    /// again once a manifest exists, so a relaunch would replace the
    /// dedicated lost-shortcuts notice with, at most, a generic mirror
    /// caveat while the user's configuration is still unrecovered. Cleared
    /// when the user dismisses the notice. Optional so a manifest without it
    /// stays valid.
    var legacyMigrationFailure: LegacyMigrationFailureRecord?

    struct LegacyMigrationFailureRecord: Codable, Equatable, Sendable {
        var preservedCopyPath: String?
    }

    init(
        schemaVersion: Int = ShortcutProfileManifest.currentSchemaVersion,
        profiles: [ShortcutProfile],
        pendingUsageDeletions: [UUID]? = nil,
        legacyMigrationFailure: LegacyMigrationFailureRecord? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.pendingUsageDeletions = pendingUsageDeletions
        self.legacyMigrationFailure = legacyMigrationFailure
    }

    func profile(id: UUID) -> ShortcutProfile? {
        profiles.first { $0.id == id }
    }
}

/// The active-profile pointer. Its write is the single commit point of a
/// profile switch, and it happens before any in-memory state changes so a
/// crash lands on a disk state that leads (never lags) what was applied.
struct ShortcutProfileActivePointer: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var activeProfileID: UUID

    init(schemaVersion: Int = ShortcutProfileActivePointer.currentSchemaVersion, activeProfileID: UUID) {
        self.schemaVersion = schemaVersion
        self.activeProfileID = activeProfileID
    }
}

/// Describes `shortcuts.json` as Wink last wrote it. The digest is what
/// separates a mirror this build left stale (crash between the pointer commit
/// and the mirror write) from one an older build rewrote: a stale mirror still
/// matches its recorded digest, a foreign edit does not.
struct ShortcutProfileMirrorDescriptor: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var profileID: UUID
    var sha256: String

    init(
        schemaVersion: Int = ShortcutProfileMirrorDescriptor.currentSchemaVersion,
        profileID: UUID,
        sha256: String
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.sha256 = sha256
    }
}
