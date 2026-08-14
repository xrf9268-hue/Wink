import AppIntents
import Foundation
import WinkFocusShared

@available(macOS 13.0, *)
public struct ShortcutProfileEntity: AppEntity, Identifiable, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Shortcut Profile")
    )
    public static let defaultQuery = ShortcutProfileEntityQuery()

    public let id: UUID
    @Property(title: "Name")
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

@available(macOS 13.0, *)
public struct ShortcutProfileEntityQuery: EntityQuery, Sendable {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [ShortcutProfileEntity] {
        let requested = Set(identifiers)
        return try catalog().profiles
            .filter { requested.contains($0.id) }
            .map(ShortcutProfileEntity.init)
    }

    public func suggestedEntities() async throws -> [ShortcutProfileEntity] {
        try catalog().profiles.map(ShortcutProfileEntity.init)
    }

    private func catalog() throws -> FocusProfileCatalog {
        try FocusFilterSharedStore().loadCatalog()
    }
}

@available(macOS 13.0, *)
public struct SetWinkFocusFilterIntent: SetFocusFilterIntent {
    public static let title: LocalizedStringResource = "Wink Focus Filter"
    public static let description = IntentDescription(
        "Apply a specific Wink shortcut profile and optionally pause all shortcuts while this Focus is active."
    )

    @Parameter(title: "Shortcut Profile")
    public var profile: ShortcutProfileEntity?

    @Parameter(title: "Pause Shortcuts", default: false)
    public var pauseShortcuts: Bool

    public init() {
        profile = nil
        pauseShortcuts = false
    }

    public init(profile: ShortcutProfileEntity?, pauseShortcuts: Bool) {
        self.profile = profile
        self.pauseShortcuts = pauseShortcuts
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Use \(\.$profile), pause: \(\.$pauseShortcuts)")
    }

    public var displayRepresentation: DisplayRepresentation {
        if let profile {
            return DisplayRepresentation(title: "Wink · \(profile.name)")
        }
        return DisplayRepresentation(title: pauseShortcuts ? "Wink · Paused" : "Wink")
    }

    public func perform() async throws -> some IntentResult {
        let store = FocusFilterSharedStore()
        _ = try store.applyFocusSelection(
            profileID: profile?.id,
            pauseShortcuts: pauseShortcuts
        )
        store.postStateChangedNotification()
        return .result()
    }
}

@available(macOS 13.0, *)
private extension ShortcutProfileEntity {
    init(_ record: FocusProfileRecord) {
        self.init(id: record.id, name: record.name)
    }
}
