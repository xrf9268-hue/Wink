import Foundation
import Observation

enum FirstShortcutOnboardingRoute: String, Equatable, Sendable {
    case standard
    case standardFunction
    case hyper

    var requiresInputMonitoring: Bool {
        self != .standard
    }
}

struct FirstShortcutOnboardingReadiness: Equatable, Sendable {
    let route: FirstShortcutOnboardingRoute
    let shortcutAvailable: Bool
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let routeReady: Bool
    let shortcutsPaused: Bool
    let secureInputActive: Bool
}

@MainActor
@Observable
final class FirstShortcutOnboardingState {
    enum Phase: Equatable {
        case hidden
        case introduction
        case configure
        case permissions
        case verification(waitingForActivation: Bool)
        case success
        case failure(Failure)
    }

    enum Failure: Equatable {
        case activationRejected
        case activationTimedOut
        case shortcutUnavailable
        case targetAlreadyFrontmost
    }

    enum Completion: String {
        case skipped
        case verified
    }

    enum SystemSettingsDestination: Equatable {
        case accessibility
        case inputMonitoring
    }

    struct Client {
        let readiness: @MainActor (AppShortcut) -> FirstShortcutOnboardingReadiness
        let requestPermissions: @MainActor (AppShortcut) -> Void
        let openSystemSettings: @MainActor (SystemSettingsDestination) -> Void
        let setAutomaticPermissionPromptSuppressed: @MainActor (Bool) -> Void
        let scheduleVerificationTimeout: @MainActor (
            _ delay: Duration,
            _ operation: @escaping @MainActor () -> Void
        ) -> Void
        let log: @Sendable (String) -> Void

        nonisolated init(
            readiness: @escaping @MainActor (AppShortcut) -> FirstShortcutOnboardingReadiness,
            requestPermissions: @escaping @MainActor (AppShortcut) -> Void,
            openSystemSettings: @escaping @MainActor (SystemSettingsDestination) -> Void,
            setAutomaticPermissionPromptSuppressed: @escaping @MainActor (Bool) -> Void,
            scheduleVerificationTimeout: @escaping @MainActor (
                _ delay: Duration,
                _ operation: @escaping @MainActor () -> Void
            ) -> Void,
            log: @escaping @Sendable (String) -> Void
        ) {
            self.readiness = readiness
            self.requestPermissions = requestPermissions
            self.openSystemSettings = openSystemSettings
            self.setAutomaticPermissionPromptSuppressed = setAutomaticPermissionPromptSuppressed
            self.scheduleVerificationTimeout = scheduleVerificationTimeout
            self.log = log
        }

        static let inert = Client(
            readiness: { _ in
                FirstShortcutOnboardingReadiness(
                    route: .standard,
                    shortcutAvailable: false,
                    accessibilityGranted: false,
                    inputMonitoringGranted: false,
                    routeReady: false,
                    shortcutsPaused: false,
                    secureInputActive: false
                )
            },
            requestPermissions: { _ in },
            openSystemSettings: { _ in },
            setAutomaticPermissionPromptSuppressed: { _ in },
            scheduleVerificationTimeout: { _, _ in },
            log: { _ in }
        )
    }

    static let completionDefaultsKey = "com.wink.firstShortcutOnboardingCompletion"
    static let pendingShortcutIDDefaultsKey = "com.wink.firstShortcutOnboardingShortcutID"
    static let inProgressDefaultsKey = "com.wink.firstShortcutOnboardingInProgress"
    /// AppSwitcher's production activation session can remain valid for five
    /// seconds. Keep the guide outside that ceiling, with one second for the
    /// final main-run-loop confirmation callback, so a legitimate cold launch
    /// cannot be reported as failed while its owned session is still active.
    static let verificationTimeout: Duration = .seconds(6)

    private(set) var phase: Phase = .hidden
    private(set) var activeShortcut: AppShortcut?
    private(set) var readiness: FirstShortcutOnboardingReadiness?
    private(set) var verificationAttemptID: UUID?

    private let userDefaults: UserDefaults
    private let legacyCompletionDefaultsKey: String
    private let client: Client
    private var matchedVerificationAttemptID: UUID?
    private var matchedActivationAttemptIdentity: AppActivationAttemptIdentity?

    init(
        userDefaults: UserDefaults,
        legacyCompletionDefaultsKey: String,
        client: Client
    ) {
        self.userDefaults = userDefaults
        self.legacyCompletionDefaultsKey = legacyCompletionDefaultsKey
        self.client = client
    }

    var isPresented: Bool {
        phase != .hidden
    }

    var isConfiguring: Bool {
        phase == .configure
    }

    /// The ordinary composer is usable outside onboarding and while the guide
    /// explicitly owns the configure step. Keeping it disabled during the
    /// introduction prevents a fresh user from persisting a shortcut before
    /// the guide can store its exact UUID.
    var allowsShortcutComposition: Bool {
        phase == .hidden || phase == .configure
    }

    /// The Current App pseudo-target resolves only at press time, so its
    /// persisted sentinel can never be the concrete bundle that onboarding
    /// observes becoming frontmost.
    var allowsFrontmostTargetSelection: Bool {
        !isPresented
    }

    /// Aggregate permission requests can prompt for transports the user has
    /// not selected. While the guide is visible, only its exact saved route
    /// may request access.
    var allowsAggregatePermissionRequests: Bool {
        !isPresented
    }

    var isWaitingForFrontmostConfirmation: Bool {
        phase == .verification(waitingForActivation: true)
    }

    var selectedRouteIsBlockedBySecureInput: Bool {
        readiness?.route.requiresInputMonitoring == true
            && readiness?.secureInputActive == true
    }

    func isAwaitingPhysicalVerification(for shortcutID: UUID) -> Bool {
        guard case .verification(waitingForActivation: false) = phase else {
            return false
        }
        return activeShortcut?.id == shortcutID
    }

    var completion: Completion? {
        userDefaults.string(forKey: Self.completionDefaultsKey).flatMap(Completion.init(rawValue:))
    }

    /// Restores an unfinished attempt before deciding whether this is a fresh
    /// install. Existing users remain exempt, while a shortcut created by an
    /// earlier onboarding run keeps its exact UUID across relaunch.
    @discardableResult
    func prepareForLaunch(shortcuts: [AppShortcut], hasLegacyCompletion: Bool) -> Bool {
        defer { client.setAutomaticPermissionPromptSuppressed(isPresented) }
        if let pendingID = pendingShortcutID(),
           let shortcut = shortcuts.first(where: { $0.id == pendingID }) {
            markInProgress()
            activeShortcut = shortcut
            readiness = nil
            // Capture has not started yet, so trigger-index availability is
            // not authoritative. AppController refreshes once providers and
            // the index are live.
            phase = .permissions
            return true
        }

        if pendingShortcutID() != nil {
            markInProgress()
            clearPendingShortcut()
            activeShortcut = nil
            phase = .configure
            return true
        }

        // This marker is written before a fresh or manual guide is presented,
        // so imports, a quit before Add, or another mutation path cannot turn
        // a nonempty store into an implicit completion on relaunch.
        if isInProgress {
            activeShortcut = nil
            readiness = nil
            phase = .introduction
            return true
        }

        // A manual run can begin after an earlier Skip or verification. Its
        // pending UUID is authoritative until the user finishes or skips the
        // new attempt, so only consult the old completion after restoring (or
        // recovering) that in-progress run.
        guard completion == nil else {
            phase = .hidden
            return false
        }

        guard !hasLegacyCompletion else {
            phase = .hidden
            return false
        }

        guard shortcuts.isEmpty else {
            // A pre-onboarding install with configured shortcuts is an existing
            // user, not an interrupted fresh-user attempt.
            userDefaults.set(true, forKey: legacyCompletionDefaultsKey)
            phase = .hidden
            return false
        }

        markInProgress()
        phase = .introduction
        return true
    }

    func startManually() {
        guard !isPresented else { return }
        // Commit the new run before clearing any older pending UUID. If the
        // process exits between writes, relaunch must still prefer the guide
        // over an earlier completion/existing-user exemption.
        markInProgress()
        matchedVerificationAttemptID = nil
        matchedActivationAttemptIdentity = nil
        verificationAttemptID = nil
        readiness = nil
        activeShortcut = nil
        clearPendingShortcut()
        phase = .introduction
        client.setAutomaticPermissionPromptSuppressed(true)
    }

    func continueFromIntroduction() {
        guard phase == .introduction else { return }
        phase = .configure
    }

    func skip() {
        persistCompletion(.skipped)
        resetAndHide()
    }

    /// Called only after the existing editor has persisted a newly-created
    /// binding. The UUID is stored immediately so a quit between creation and
    /// permission grant resumes the same attempt rather than accepting an
    /// unrelated shortcut after relaunch.
    func shortcutWasAdded(_ shortcut: AppShortcut) {
        guard phase == .configure else { return }
        activeShortcut = shortcut
        userDefaults.set(shortcut.id.uuidString, forKey: Self.pendingShortcutIDDefaultsKey)
        refreshReadiness()
    }

    func synchronize(shortcuts: [AppShortcut]) {
        guard let activeShortcut else { return }
        guard let updated = shortcuts.first(where: { $0.id == activeShortcut.id }) else {
            // Verification already persisted completion. A later delete or
            // profile switch must not make the Finish action disappear and
            // ask for another binding inside the same completed run.
            if phase == .success { return }
            clearPendingShortcut()
            self.activeShortcut = nil
            readiness = nil
            verificationAttemptID = nil
            matchedVerificationAttemptID = nil
            matchedActivationAttemptIdentity = nil
            phase = .configure
            return
        }
        let changedDuringOwnedActivation = updated != activeShortcut
            && isWaitingForFrontmostConfirmation
        self.activeShortcut = updated
        if changedDuringOwnedActivation {
            // Readiness-only changes are intentionally sticky while the exact
            // activation session settles, but a mutation of the binding itself
            // invalidates the proof: the captured chord no longer describes
            // the saved row that would be marked verified.
            verificationAttemptID = nil
            matchedVerificationAttemptID = nil
            matchedActivationAttemptIdentity = nil
            phase = .permissions
        }
        refreshReadiness()
    }

    func refreshReadiness() {
        guard let activeShortcut else { return }
        let current = client.readiness(activeShortcut)
        readiness = current

        // Once a physical match owns an exact activation session, transient
        // capture degradation (most notably the target itself triggering an
        // exception auto-pause as it becomes frontmost) cannot revoke that
        // proof while AppSwitcher is still confirming it. Terminal states are
        // equally sticky until the user explicitly retries/finishes/skips.
        switch phase {
        case .verification(waitingForActivation: true), .success, .failure:
            return
        default:
            break
        }

        guard current.shortcutAvailable else {
            verificationAttemptID = nil
            matchedVerificationAttemptID = nil
            matchedActivationAttemptIdentity = nil
            phase = .failure(.shortcutUnavailable)
            return
        }

        guard current.routeReady else {
            verificationAttemptID = nil
            matchedVerificationAttemptID = nil
            matchedActivationAttemptIdentity = nil
            phase = .permissions
            return
        }

        if phase != .verification(waitingForActivation: false) {
            beginVerificationAttempt()
        }
    }

    func requestPermissions() {
        guard let activeShortcut else { return }
        client.requestPermissions(activeShortcut)
        refreshReadiness()
    }

    func openSystemSettings() {
        guard let readiness else { return }
        let destination: SystemSettingsDestination
        if !readiness.accessibilityGranted || !readiness.route.requiresInputMonitoring {
            destination = .accessibility
        } else {
            destination = .inputMonitoring
        }
        client.openSystemSettings(destination)
    }

    func retry() {
        guard activeShortcut != nil else {
            phase = .configure
            return
        }
        phase = .permissions
        refreshReadiness()
    }

    func changeShortcut() {
        clearPendingShortcut()
        activeShortcut = nil
        readiness = nil
        verificationAttemptID = nil
        matchedVerificationAttemptID = nil
        matchedActivationAttemptIdentity = nil
        phase = .configure
    }

    /// This hook is emitted only by the real capture/match path. A direct UI
    /// action never calls it, so onboarding cannot be completed by a test
    /// button or by an unrelated workspace activation.
    func capturedShortcutTriggered(
        _ shortcut: AppShortcut,
        accepted: Bool,
        targetWasFrontmost: Bool = false,
        activationAttempt: AppActivationAttemptSnapshot? = nil
    ) {
        guard case .verification(waitingForActivation: false) = phase,
              let activeShortcut,
              activeShortcut.id == shortcut.id,
              let attemptID = verificationAttemptID else {
            return
        }

        guard accepted else {
            phase = .failure(.activationRejected)
            client.log(
                "ONBOARDING_VERIFY event=rejected shortcutId=\(shortcut.id.uuidString) attemptId=\(attemptID.uuidString)"
            )
            return
        }

        guard !targetWasFrontmost else {
            phase = .failure(.targetAlreadyFrontmost)
            client.log(
                "ONBOARDING_VERIFY event=rejected shortcutId=\(shortcut.id.uuidString) attemptId=\(attemptID.uuidString) reason=target_already_frontmost"
            )
            return
        }

        guard let activationAttempt,
              activationAttempt.identity.bundleIdentifier == shortcut.bundleIdentifier else {
            phase = .failure(.activationRejected)
            client.log(
                "ONBOARDING_VERIFY event=rejected shortcutId=\(shortcut.id.uuidString) attemptId=\(attemptID.uuidString) reason=no_activation_session"
            )
            return
        }

        matchedVerificationAttemptID = attemptID
        matchedActivationAttemptIdentity = activationAttempt.identity
        phase = .verification(waitingForActivation: true)
        client.log(
            "ONBOARDING_VERIFY event=matched shortcutId=\(shortcut.id.uuidString) attemptId=\(attemptID.uuidString) target=\(shortcut.bundleIdentifier) activationAttemptId=\(activationAttempt.identity.attemptID.uuidString) activationGeneration=\(activationAttempt.identity.generation)"
        )
        // AppSwitcher can confirm synchronously while the capture callback is
        // still unwinding. The exact session snapshot closes that race without
        // accepting an ownership-free workspace/frontmost observation.
        if activationAttempt.isConfirmed {
            activationAttemptDidConfirm(activationAttempt.identity)
            return
        }
        client.scheduleVerificationTimeout(Self.verificationTimeout) { [weak self] in
            self?.verificationTimedOut(attemptID: attemptID)
        }
    }

    /// Only AppSwitcher's successful confirmation transition for the exact
    /// activation session created by this physical match can complete the
    /// guide. A Dock/Cmd-Tab activation of the same bundle has no matching
    /// attempt ID/generation and is therefore ineligible by construction.
    func activationAttemptDidConfirm(_ identity: AppActivationAttemptIdentity) {
        guard case .verification(waitingForActivation: true) = phase,
              let activeShortcut,
              let attemptID = verificationAttemptID,
              matchedVerificationAttemptID == attemptID,
              matchedActivationAttemptIdentity == identity else {
            return
        }

        persistCompletion(.verified)
        phase = .success
        client.log(
            "ONBOARDING_VERIFY event=confirmed shortcutId=\(activeShortcut.id.uuidString) attemptId=\(attemptID.uuidString) target=\(activeShortcut.bundleIdentifier) activationAttemptId=\(identity.attemptID.uuidString) activationGeneration=\(identity.generation)"
        )
    }

    func verificationTimedOut(attemptID: UUID) {
        guard case .verification(waitingForActivation: true) = phase,
              verificationAttemptID == attemptID,
              matchedVerificationAttemptID == attemptID else {
            return
        }
        phase = .failure(.activationTimedOut)
        client.log("ONBOARDING_VERIFY event=timeout attemptId=\(attemptID.uuidString)")
    }

    func finish() {
        guard phase == .success else { return }
        resetAndHide()
    }

    private func beginVerificationAttempt() {
        let attemptID = UUID()
        verificationAttemptID = attemptID
        matchedVerificationAttemptID = nil
        matchedActivationAttemptIdentity = nil
        phase = .verification(waitingForActivation: false)
    }

    private func pendingShortcutID() -> UUID? {
        userDefaults.string(forKey: Self.pendingShortcutIDDefaultsKey).flatMap(UUID.init(uuidString:))
    }

    private func clearPendingShortcut() {
        userDefaults.removeObject(forKey: Self.pendingShortcutIDDefaultsKey)
    }

    private var isInProgress: Bool {
        userDefaults.bool(forKey: Self.inProgressDefaultsKey)
    }

    private func markInProgress() {
        userDefaults.set(true, forKey: Self.inProgressDefaultsKey)
    }

    private func persistCompletion(_ completion: Completion) {
        userDefaults.set(completion.rawValue, forKey: Self.completionDefaultsKey)
        userDefaults.set(true, forKey: legacyCompletionDefaultsKey)
        clearPendingShortcut()
        userDefaults.removeObject(forKey: Self.inProgressDefaultsKey)
    }

    private func resetAndHide() {
        activeShortcut = nil
        readiness = nil
        verificationAttemptID = nil
        matchedVerificationAttemptID = nil
        matchedActivationAttemptIdentity = nil
        phase = .hidden
        client.setAutomaticPermissionPromptSuppressed(false)
    }
}
