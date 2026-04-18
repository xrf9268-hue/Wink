import Foundation

struct UpdatePresentation: Equatable {
    let currentVersion: String
    let checkForUpdatesEnabled: Bool
    let automaticChecksEnabledByDefault: Bool
    let automaticDownloadsEnabledByDefault: Bool
}

@MainActor
protocol UpdateServicing: AnyObject {
    var canCheckForUpdates: Bool { get }
    var currentVersion: String { get }
    var automaticallyChecksForUpdates: Bool { get }
    var automaticallyDownloadsUpdates: Bool { get }

    func checkForUpdates()
}
