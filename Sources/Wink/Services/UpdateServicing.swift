import Foundation

struct UpdatePresentation: Equatable {
    let currentVersion: String
    let isConfigured: Bool
    let checkForUpdatesEnabled: Bool
    let automaticChecksEnabled: Bool
    let automaticDownloadsEnabled: Bool
}

/// User-visible update-session state, deliberately free of Sparkle types so
/// SwiftUI and tests never import Sparkle (per docs/architecture.md the
/// update seam keeps Sparkle out of the view layer).
enum UpdatePhase: Equatable {
    case idle
    /// A check found an update that is not downloaded yet.
    case available(version: String)
    /// The update is downloaded or staged; it installs on quit or relaunch.
    case ready(version: String)
    /// A scheduled background check failed (feed unreachable, bad signature).
    /// Cleared by the next check that completes without error.
    case error(message: String)

    /// Delivery progress of a found update, mirrored from the updater.
    enum DeliveryStage: Equatable {
        case notDownloaded
        case downloaded
        case installing
    }

    /// Pure mapping used by the Sparkle delegate glue; unit-testable without
    /// Sparkle types.
    static func forFoundUpdate(version: String, stage: DeliveryStage) -> UpdatePhase {
        switch stage {
        case .notDownloaded:
            return .available(version: version)
        case .downloaded, .installing:
            return .ready(version: version)
        }
    }
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
    /// Current update-session phase. Changes are announced through
    /// `onUpdateStateChange`.
    var updatePhase: UpdatePhase { get }
    /// When the updater last finished a check cycle (any outcome).
    var lastUpdateCheckDate: Date? { get }
    /// Single observer, invoked on the main actor after `updatePhase` or
    /// `lastUpdateCheckDate` changes. AppPreferences mirrors the values into
    /// observable stored state for SwiftUI.
    var onUpdateStateChange: (@MainActor () -> Void)? { get set }

    func checkForUpdates()
}
