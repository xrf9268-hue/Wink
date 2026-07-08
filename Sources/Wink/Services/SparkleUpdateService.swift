import Foundation
import Sparkle

@MainActor
final class SparkleUpdateService: UpdateServicing {
    private let bundle: Bundle
    private let updaterController: SPUStandardUpdaterController?
    private let delegateAdapter: SparkleDelegateAdapter?

    private(set) var updatePhase: UpdatePhase = .idle {
        didSet {
            guard updatePhase != oldValue else { return }
            onUpdateStateChange?()
        }
    }

    private(set) var lastUpdateCheckDate: Date? {
        didSet { onUpdateStateChange?() }
    }

    var onUpdateStateChange: (@MainActor () -> Void)?

    init(bundle: Bundle = .main) {
        self.bundle = bundle

        if Self.hasValidConfiguration(bundle: bundle) {
            // The adapter enables Sparkle's gentle scheduled update reminders:
            // scheduled checks route into Wink-owned surfaces (menu-bar
            // popover row, settings card) instead of a stock alert detached
            // from any Wink window. User-initiated checks still use Sparkle's
            // standard UI.
            let adapter = SparkleDelegateAdapter()
            self.delegateAdapter = adapter
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: adapter,
                userDriverDelegate: adapter
            )
            adapter.service = self
        } else {
            self.delegateAdapter = nil
            self.updaterController = nil
        }
    }

    var isConfigured: Bool {
        updaterController != nil
    }

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }

    var currentVersion: String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            updaterController?.updater.automaticallyChecksForUpdates
                ?? Self.boolValue(forInfoDictionaryKey: "SUEnableAutomaticChecks", bundle: bundle, default: true)
        }
        set {
            updaterController?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            updaterController?.updater.automaticallyDownloadsUpdates
                ?? Self.boolValue(forInfoDictionaryKey: "SUAutomaticallyUpdate", bundle: bundle, default: true)
        }
        set {
            updaterController?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    // MARK: - Delegate glue (called by SparkleDelegateAdapter on the main actor)

    fileprivate func handleFoundUpdate(version: String, stage: UpdatePhase.DeliveryStage) {
        updatePhase = .forFoundUpdate(version: version, stage: stage)
    }

    fileprivate func handleUpdateSkipped() {
        updatePhase = .idle
    }

    fileprivate func handleUpdateCycleFinished(isUserInitiated: Bool, errorMessage: String?) {
        lastUpdateCheckDate = Date()
        if let errorMessage {
            // Sparkle already presents errors for user-initiated checks in
            // its own UI; only scheduled failures need a Wink-owned surface.
            if !isUserInitiated {
                updatePhase = .error(message: errorMessage)
            }
        } else if case .error = updatePhase {
            updatePhase = .idle
        }
    }

    private static func hasValidConfiguration(bundle: Bundle) -> Bool {
        hasNonEmptyString("SUFeedURL", bundle: bundle) &&
        hasNonEmptyString("SUPublicEDKey", bundle: bundle)
    }

    private static func hasNonEmptyString(_ key: String, bundle: Bundle) -> Bool {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
            return false
        }

        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func boolValue(
        forInfoDictionaryKey key: String,
        bundle: Bundle,
        default defaultValue: Bool
    ) -> Bool {
        if let value = bundle.object(forInfoDictionaryKey: key) as? Bool {
            return value
        }

        if let value = bundle.object(forInfoDictionaryKey: key) as? NSNumber {
            return value.boolValue
        }

        return defaultValue
    }
}

/// Bridges Sparkle's delegate callbacks onto `SparkleUpdateService`.
///
/// Sparkle's updater API is main-thread only, so every callback below arrives
/// on the main thread and can assume main-actor isolation. Kept as a separate
/// NSObject because both delegate protocols require NSObjectProtocol and the
/// controller retains its delegates weakly.
private final class SparkleDelegateAdapter: NSObject {
    weak var service: SparkleUpdateService?

    /// Sparkle error codes that are outcomes, not failures: no update found
    /// (1001) and user-canceled installation (4007).
    private static let ignoredErrorCodes: Set<Int> = [1001, 4007]

    private static func deliveryStage(from state: SPUUserUpdateState) -> UpdatePhase.DeliveryStage {
        switch state.stage {
        case .notDownloaded:
            return .notDownloaded
        case .downloaded:
            return .downloaded
        case .installing:
            return .installing
        @unknown default:
            return .notDownloaded
        }
    }

    private func onMain(_ body: @escaping @MainActor (SparkleUpdateService) -> Void) {
        MainActor.assumeIsolated { [weak service] in
            guard let service else { return }
            body(service)
        }
    }
}

extension SparkleDelegateAdapter: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Wink handles scheduled updates gently (popover row + settings
        // card) instead of a stock alert with no dock presence behind it.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        let stage = Self.deliveryStage(from: state)
        onMain { service in
            service.handleFoundUpdate(version: version, stage: stage)
        }
    }
}

extension SparkleDelegateAdapter: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard choice == .skip else { return }
        onMain { service in
            service.handleUpdateSkipped()
        }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        let isUserInitiated = updateCheck == .updates
        let errorMessage: String?
        if let error {
            let nsError = error as NSError
            errorMessage = Self.ignoredErrorCodes.contains(nsError.code) ? nil : nsError.localizedDescription
        } else {
            errorMessage = nil
        }
        onMain { service in
            service.handleUpdateCycleFinished(isUserInitiated: isUserInitiated, errorMessage: errorMessage)
        }
    }
}
