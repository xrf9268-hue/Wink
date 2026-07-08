import Foundation

struct UpdatePresentation: Equatable {
    let currentVersion: String
    let isConfigured: Bool
    let checkForUpdatesEnabled: Bool
    let automaticChecksEnabled: Bool
    let automaticDownloadsEnabled: Bool
}

@MainActor
protocol UpdateServicing: AnyObject {
    var isConfigured: Bool { get }
    var canCheckForUpdates: Bool { get }
    var currentVersion: String { get }
    /// Live updater values. Setting persists through the updater's own store
    /// (Sparkle writes user defaults that override the Info.plist seeds);
    /// setters are no-ops while the updater is unconfigured.
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }

    func checkForUpdates()
}
