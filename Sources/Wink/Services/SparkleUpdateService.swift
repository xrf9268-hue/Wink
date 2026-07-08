import AppKit
import Foundation
import Sparkle

/// Sparkle 2 wrapper built on a raw `SPUUpdater` with a **custom**
/// `SPUUserDriver` (Issue #298, Stage 2): every update-session state renders
/// in Wink-owned UI instead of Sparkle's stock windows. The class itself is
/// the user driver (the protocol is `NS_SWIFT_UI_ACTOR`, so every callback
/// arrives on the main actor); it translates callbacks into `UpdatePhase`
/// and holds Sparkle's action callbacks so the panel only calls semantic
/// methods.
///
/// Session semantics for an LSUIElement app:
/// - User-initiated checks present the update panel with focus.
/// - Scheduled checks stay gentle: found/ready updates hold their reply and
///   surface only through `updatePhase` (popover notice row, settings card);
///   scheduled up-to-date/error outcomes are acknowledged immediately so the
///   session never leaks (an unconsumed acknowledgement leaves Sparkle's
///   `sessionInProgress` stuck and silently kills all later checks).
@MainActor
final class SparkleUpdateService: NSObject, UpdateServicing {
    private let bundle: Bundle
    private var updater: SPUUpdater?
    private let updaterDelegate: SparkleUpdaterDelegate

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

    /// Panel host hooks, injected by AppController. `activate` distinguishes
    /// user-initiated presentations (panel takes focus) from session resumes.
    var presentUpdatePanel: (@MainActor (_ activate: Bool) -> Void)?
    var dismissUpdatePanel: (@MainActor () -> Void)?

    // MARK: - In-flight Sparkle callbacks (one-shot; see Optional.take())

    private var checkCancellation: (() -> Void)?
    private var downloadCancellation: (() -> Void)?
    private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var pendingAcknowledgement: (() -> Void)?

    private var sessionIsUserInitiated = false
    private var downloadVersion = ""
    private var downloadReceived: UInt64 = 0
    private var downloadExpected: UInt64 = 0
    /// URLSession reports every chunk; publishing each one re-renders SwiftUI
    /// per chunk. Throttle to ~10Hz — the extracting phase that follows
    /// covers any missed final chunk.
    private var lastDownloadPublish: Date = .distantPast

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        self.updaterDelegate = SparkleUpdaterDelegate()
        super.init()

        guard Self.hasValidConfiguration(bundle: bundle) else { return }

        let updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: self,
            delegate: updaterDelegate
        )
        do {
            try updater.start()
            self.updater = updater
            updaterDelegate.service = self
        } catch {
            // Non-bundle runs (swift run) or broken configuration: updates
            // are unavailable; the rest of the app is unaffected.
            DiagnosticLog.log("Updater unavailable: \(error.localizedDescription)")
        }
    }

    var isConfigured: Bool {
        updater != nil
    }

    var canCheckForUpdates: Bool {
        updater?.canCheckForUpdates ?? false
    }

    var currentVersion: String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            updater?.automaticallyChecksForUpdates
                ?? Self.boolValue(forInfoDictionaryKey: "SUEnableAutomaticChecks", bundle: bundle, default: true)
        }
        set {
            updater?.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            updater?.automaticallyDownloadsUpdates
                ?? Self.boolValue(forInfoDictionaryKey: "SUAutomaticallyUpdate", bundle: bundle, default: true)
        }
        set {
            updater?.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Deliberately not gated on `canCheckForUpdates`: with a session already
    /// in flight Sparkle dispatches to `showUpdateInFocus`, re-presenting the
    /// current phase — gating would turn the button into a dead key.
    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    // MARK: - Session actions (UpdateServicing)

    /// Only ever send **one** reply: with background auto-download, the
    /// found-reply (`showUpdateFound(.downloaded)`) and the ready-reply
    /// (`showReady`) can both be in hand; double-replying corrupts Sparkle's
    /// state machine. The ready reply is newer and wins.
    func installUpdateNow() {
        if let reply = readyReply.take() {
            updateReply = nil
            reply(.install)
        } else if let reply = updateReply.take() {
            reply(.install)
        }
    }

    func remindUpdateLater() {
        if let reply = readyReply.take() {
            updateReply = nil
            reply(.dismiss)
        } else if let reply = updateReply.take() {
            reply(.dismiss)
        }
        closeAndIdle()
    }

    func skipUpdateVersion() {
        updateReply.take()?(.skip)
        closeAndIdle()
    }

    func cancelUpdateOperation() {
        checkCancellation.take()?()
        downloadCancellation.take()?()
        closeAndIdle()
    }

    func acknowledgeUpdateResult() {
        pendingAcknowledgement.take()?()
        closeAndIdle()
    }

    private func closeAndIdle() {
        // Consume any pending acknowledgement on every close path — Sparkle's
        // UI-based update driver only aborts the session inside that
        // callback. Leaving it unconsumed wedges the session for the rest of
        // the run. (No-op when nothing is pending; dismissUpdateInstallation
        // nils it first, preserving its discard-without-calling semantics.)
        pendingAcknowledgement.take()?()
        updatePhase = .idle
        dismissUpdatePanel?()
    }

    private func present(_ newPhase: UpdatePhase, activatePanel: Bool) {
        updatePhase = newPhase
        presentUpdatePanel?(activatePanel)
    }

    // MARK: - Delegate glue

    fileprivate func handleUpdateCycleFinished() {
        lastUpdateCheckDate = Date()
    }

    // MARK: - Configuration helpers

    private static func hasValidConfiguration(bundle: Bundle) -> Bool {
        if SparkleUpdaterDelegate.feedURLOverride(from: .standard) != nil {
            return hasNonEmptyString("SUPublicEDKey", bundle: bundle)
        }
        return hasNonEmptyString("SUFeedURL", bundle: bundle) &&
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

// MARK: - SPUUserDriver (NS_SWIFT_UI_ACTOR — every callback is main-actor)

extension SparkleUpdateService: SPUUserDriver {
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // Info.plist sets SUEnableAutomaticChecks explicitly, so Sparkle
        // should never ask; answer with the current preference as a fallback.
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: automaticallyChecksForUpdates,
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        checkCancellation = cancellation
        sessionIsUserInitiated = true
        present(.checking, activatePanel: true)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        presentUpdateFound(
            version: appcastItem.displayVersionString,
            userInitiated: state.userInitiated,
            reply: reply
        )
    }

    /// Pure-value seam for `showUpdateFound` — `SPUUserUpdateState` has no
    /// public initializer, so tests drive this method directly.
    func presentUpdateFound(
        version: String,
        userInitiated: Bool,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        checkCancellation = nil
        updateReply = reply
        downloadVersion = version
        sessionIsUserInitiated = userInitiated
        if userInitiated {
            present(.available(version: version), activatePanel: true)
        } else {
            // Gentle: hold the reply, no panel. The popover notice row and
            // settings card surface the phase; clicking them runs a user
            // check, which resumes this session via showUpdateInFocus.
            updatePhase = .available(version: version)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The panel shows the version and defers full notes to the releases
        // page; no inline HTML rendering.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        checkCancellation = nil
        if sessionIsUserInitiated {
            pendingAcknowledgement = acknowledgement
            present(.upToDate(checkedAt: Date()), activatePanel: true)
        } else {
            // Scheduled: acknowledge immediately so the session closes.
            acknowledgement()
            updatePhase = .idle
        }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        checkCancellation = nil
        downloadCancellation = nil
        DiagnosticLog.log("Updater error: \(error.localizedDescription)")
        if sessionIsUserInitiated {
            pendingAcknowledgement = acknowledgement
            present(.error(message: error.localizedDescription), activatePanel: true)
        } else {
            acknowledgement()
            updatePhase = .error(message: error.localizedDescription)
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloadCancellation = cancellation
        downloadReceived = 0
        downloadExpected = 0
        lastDownloadPublish = .distantPast
        publishDownloadProgress(force: true)
        if sessionIsUserInitiated {
            presentUpdatePanel?(true)
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        downloadExpected = expectedContentLength
        publishDownloadProgress(force: true)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        downloadReceived += length
        publishDownloadProgress(force: false)
    }

    private func publishDownloadProgress(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastDownloadPublish) >= 0.1 else { return }
        lastDownloadPublish = now
        updatePhase = .downloading(
            version: downloadVersion,
            received: downloadReceived,
            expected: downloadExpected
        )
    }

    func showDownloadDidStartExtractingUpdate() {
        downloadCancellation = nil
        updatePhase = .extracting(progress: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        updatePhase = .extracting(progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyReply = reply
        if sessionIsUserInitiated {
            present(.ready(version: downloadVersion), activatePanel: true)
        } else {
            updatePhase = .ready(version: downloadVersion)
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        updatePhase = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        pendingAcknowledgement = acknowledgement
        acknowledgeUpdateResult()
    }

    /// Sparkle re-focuses an in-flight session (a repeat "Check for
    /// Updates…" click) — re-present whatever phase is current.
    func showUpdateInFocus() {
        sessionIsUserInitiated = true
        presentUpdatePanel?(true)
    }

    /// Sparkle's terminal teardown. Unconsumed replies are **discarded
    /// without being called** — Sparkle is already aborting/finishing and no
    /// longer expects answers; replying here can corrupt its state machine.
    func dismissUpdateInstallation() {
        checkCancellation = nil
        downloadCancellation = nil
        updateReply = nil
        readyReply = nil
        pendingAcknowledgement = nil
        sessionIsUserInitiated = false
        closeAndIdle()
    }

    #if DEBUG
    // Test probes for reply/acknowledgement holding state.
    var debugHasPendingAcknowledgement: Bool { pendingAcknowledgement != nil }
    var debugHasReadyReply: Bool { readyReply != nil }
    var debugHasUpdateReply: Bool { updateReply != nil }
    #endif
}

/// `SPUUpdaterDelegate` adapter. Sparkle does not guarantee main-actor
/// delivery for updater-delegate callbacks, so this stays a small
/// nonisolated object that only touches thread-safe state (UserDefaults) or
/// hops to the main actor explicitly.
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    @MainActor weak var service: SparkleUpdateService?

    static let feedURLOverrideDefaultsKey = "updateFeedURLOverride"

    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedURLOverride(from: .standard)
    }

    /// Feed override for self-hosted or local validation feeds. Only https
    /// is accepted, plus loopback http (`http://localhost`, `http://127.0.0.1`)
    /// for local end-to-end testing — EdDSA signatures remain the authenticity
    /// bedrock, but a `defaults write` should not be able to point the feed
    /// at an arbitrary insecure scheme.
    static func feedURLOverride(from defaults: UserDefaults) -> String? {
        sanitizedOverride(defaults.string(forKey: feedURLOverrideDefaultsKey))
    }

    static func sanitizedOverride(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw) else { return nil }
        switch url.scheme?.lowercased() {
        case "https":
            return raw
        case "http":
            let host = url.host()?.lowercased()
            return (host == "localhost" || host == "127.0.0.1") ? raw : nil
        default:
            return nil
        }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            self?.service?.handleUpdateCycleFinished()
        }
    }
}

/// One-shot consumption for optional callbacks: take the value and nil the
/// storage in one step, so a reply can never be sent twice.
private extension Optional {
    mutating func take() -> Wrapped? {
        defer { self = nil }
        return self
    }
}
