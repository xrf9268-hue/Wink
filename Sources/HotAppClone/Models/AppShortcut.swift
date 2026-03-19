import Foundation

struct AppShortcut: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var appName: String
    var bundleIdentifier: String
    var keyEquivalent: String
    var modifierFlags: [String]

    init(
        id: UUID = UUID(),
        appName: String,
        bundleIdentifier: String,
        keyEquivalent: String,
        modifierFlags: [String]
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
    }
}
