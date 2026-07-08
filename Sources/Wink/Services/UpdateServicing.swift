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
    /// A user-initiated check is in flight.
    case checking
    /// A check found an update that is not downloaded yet.
    case available(version: String)
    /// The update archive is downloading. `expected == 0` until the content
    /// length is known.
    case downloading(version: String, received: UInt64, expected: UInt64)
    /// The downloaded archive is being extracted. Progress is 0...1.
    case extracting(progress: Double)
    /// The update is downloaded or staged; it installs on quit or relaunch.
    case ready(version: String)
    /// Sparkle is installing (the app is about to relaunch).
    case installing
    /// A user-initiated check finished with no newer version.
    case upToDate(checkedAt: Date)
    /// A check failed (feed unreachable, bad signature). Cleared by the next
    /// check that completes without error.
    case error(message: String)

    /// True while a session holds a Sparkle reply or is doing work — the
    /// states the update panel should stay open for.
    var isActiveSession: Bool {
        switch self {
        case .idle, .upToDate, .error:
            return false
        case .checking, .available, .downloading, .extracting, .ready, .installing:
            return true
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

    // MARK: - Session actions (driven by the update panel / popover)

    /// available → install the found update; ready → install and relaunch.
    func installUpdateNow()
    /// available/ready → dismiss for now (remind on the next check).
    func remindUpdateLater()
    /// available → skip this version entirely.
    func skipUpdateVersion()
    /// checking/downloading → cancel the in-flight operation.
    func cancelUpdateOperation()
    /// upToDate/error → acknowledge the terminal state and return to idle.
    func acknowledgeUpdateResult()
}
