import AppKit
import Carbon.HIToolbox
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "AppSwitcher")

struct TogglePostActionState: Equatable, Sendable {
    let frontmostBundleIdentifier: String?
    let targetBundleIdentifier: String?
    let targetFrontmost: Bool
    let targetHidden: Bool
    let targetVisibleWindows: Bool

    init(
        frontmostBundleIdentifier: String?,
        targetBundleIdentifier: String?,
        targetFrontmost: Bool,
        targetHidden: Bool,
        targetVisibleWindows: Bool
    ) {
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.targetBundleIdentifier = targetBundleIdentifier
        self.targetFrontmost = targetFrontmost
        self.targetHidden = targetHidden
        self.targetVisibleWindows = targetVisibleWindows
    }

    init(snapshot: ActivationObservationSnapshot) {
        self.frontmostBundleIdentifier = snapshot.observedFrontmostBundleIdentifier
        self.targetBundleIdentifier = snapshot.targetBundleIdentifier
        self.targetFrontmost = snapshot.targetIsObservedFrontmost
        self.targetHidden = snapshot.targetIsHidden
        self.targetVisibleWindows = snapshot.targetHasVisibleWindows
    }

    var logDetails: String {
        "postFrontmost=\(frontmostBundleIdentifier ?? "nil"), targetBundle=\(targetBundleIdentifier ?? "nil"), targetFrontmost=\(targetFrontmost), targetHidden=\(targetHidden), targetVisibleWindows=\(targetVisibleWindows)"
    }
}

@MainActor
final class AppSwitcher: AppSwitching {
    struct PendingActivationState: Equatable, Sendable {
        let bundleIdentifier: String
        let previousBundleIdentifier: String?
        let generation: Int
        let startedAt: CFAbsoluteTime
    }

    struct PendingDeactivationState: Equatable, Sendable {
        let bundleIdentifier: String
        let appName: String
        let previousBundleIdentifier: String?
        let activationPath: ActivationPath
        let generation: Int
        let startedAt: CFAbsoluteTime
    }

    struct StableActivationState: Equatable, Sendable {
        let bundleIdentifier: String
        let previousBundleIdentifier: String?
        let generation: Int
        let startedAt: CFAbsoluteTime
        let confirmedAt: CFAbsoluteTime
    }

    enum WindowRecoveryStage: String, Sendable {
        case makeKeyWindow
        case axRaise
        case reopen
        case commandN

        var nextStage: Self? {
            switch self {
            case .makeKeyWindow:
                .axRaise
            case .axRaise:
                .reopen
            case .reopen:
                .commandN
            case .commandN:
                nil
            }
        }

        var settlingDelay: TimeInterval {
            switch self {
            case .makeKeyWindow:
                0.05
            case .axRaise:
                0.05
            case .reopen:
                0.1
            case .commandN:
                0.05
            }
        }
    }

    enum FrontProcessActivationResult {
        case success(ProcessSerialNumber)
        case processLookupFailed(OSStatus)
        case activationFailed(CGError)
    }

    enum ActivationResult {
        case skyLight(ProcessSerialNumber)
        case fallback(Bool)
    }

    enum PostActionPhase: String {
        case postActivateState = "POST_ACTIVATE_STATE"
        case postHideState = "POST_HIDE_STATE"
    }

    enum ActivationPath: String {
        case launch
        case hideUntracked = "hide_untracked"
        case hide
        case activate
        case unhideActivate = "unhide_activate"
    }

    enum HideTransport: String, Sendable {
        case runningApplicationHide = "running_application_hide"
    }

    enum WindowServerActivationMode: String, Sendable {
        case frontProcessOnly = "front_process_only"
    }

    enum ToggleLifecycle: String {
        case attempt = "TOGGLE_ATTEMPT"
        case hideUntracked = "TOGGLE_HIDE_UNTRACKED"
        case hideAttempt = "TOGGLE_HIDE_ATTEMPT"
        case hideConfirmed = "TOGGLE_HIDE_CONFIRMED"
        case hideDegraded = "TOGGLE_HIDE_DEGRADED"
        case confirmation = "TOGGLE_CONFIRMATION"
        case stable = "TOGGLE_STABLE"
        case degraded = "TOGGLE_DEGRADED"
    }

    struct ActivationClient {
        let activateFrontProcess: (pid_t, CGWindowID?) -> FrontProcessActivationResult
    }

    struct FallbackActivationClient {
        let openApplication: (
            URL,
            NSWorkspace.OpenConfiguration,
            @escaping @Sendable (NSRunningApplication?, Error?) -> Void
        ) -> Void
    }

    struct HideRequestClient {
        let hideApplication: (NSRunningApplication) -> Bool
    }

    struct AppLookupClient {
        let runningApplications: (String) -> [NSRunningApplication]
        let applicationURL: (String) -> URL?
    }

    struct ConfirmationClient {
        let now: @MainActor () -> CFAbsoluteTime
        let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    }

    private let frontmostTracker: FrontmostApplicationTracker
    private let applicationObservation: ApplicationObservation
    private let activationClient: ActivationClient
    private let fallbackActivationClient: FallbackActivationClient
    private let hideRequestClient: HideRequestClient
    private let appLookupClient: AppLookupClient
    private let confirmationClient: ConfirmationClient
    private let sessionCoordinator: ToggleSessionCoordinator
    private var frontmostTargetBehavior: FrontmostTargetBehavior = .toggle

    /// Re-entry guard: prevents nested calls to toggleApplication on the same run loop turn.
    private var isToggling = false
    /// Per-bundle cooldown: tracks when each bundle was last toggled to prevent rapid re-triggers.
    private var lastToggleTimeByBundle: [String: CFAbsoluteTime] = [:]
    /// Minimum interval (seconds) between toggles of the same bundle.
    private let toggleCooldown: TimeInterval = 0.4
    private let cooldownCacheLimit = 20
    private let cooldownEvictionWindow: CFAbsoluteTime = 60
    private let hiddenStateSettleRetryDelay: TimeInterval = 0.05
    private let deactivationConfirmationInitialDelay: TimeInterval = 0.05
    private let deactivationConfirmationPollInterval: TimeInterval = 0.05
    private let deactivationConfirmationTimeout: TimeInterval = 0.3
    // nonisolated(unsafe): written only while @MainActor-isolated (from init)
    // but read from the nonisolated deinit below, where NotificationCenter.removeObserver
    // is thread-safe.
    private nonisolated(unsafe) var workspaceHideObserver: Any?

    deinit {
        if let workspaceHideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceHideObserver)
        }
        // AppSwitcher owns the lifecycle of the workspace observers it asked
        // sessionCoordinator to install, so stop them even if the coordinator
        // is kept alive by another owner.
        sessionCoordinator.stopObservingWorkspaceNotifications()
    }

    init(
        frontmostTracker: FrontmostApplicationTracker = FrontmostApplicationTracker(),
        applicationObservation: ApplicationObservation = .live,
        activationClient: ActivationClient = .live,
        fallbackActivationClient: FallbackActivationClient = .live,
        hideRequestClient: HideRequestClient = .live,
        appLookupClient: AppLookupClient = .live,
        confirmationClient: ConfirmationClient = .live,
        sessionCoordinator: ToggleSessionCoordinator? = nil
    ) {
        self.frontmostTracker = frontmostTracker
        self.applicationObservation = applicationObservation
        self.activationClient = activationClient
        self.fallbackActivationClient = fallbackActivationClient
        self.hideRequestClient = hideRequestClient
        self.appLookupClient = appLookupClient
        self.confirmationClient = confirmationClient
        self.sessionCoordinator = sessionCoordinator ?? ToggleSessionCoordinator(now: confirmationClient.now)
        self.sessionCoordinator.startObservingWorkspaceNotifications()
        self.sessionCoordinator.setFrontmostTargetBehavior(frontmostTargetBehavior)
        workspaceHideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundle = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { [weak self] in
                guard let self,
                      let bundle,
                      self.pendingDeactivationState?.bundleIdentifier == bundle else {
                    return
                }
                _ = self.handleWorkspaceHideNotification(bundleIdentifier: bundle)
            }
        }
    }

    func setFrontmostTargetBehavior(_ behavior: FrontmostTargetBehavior) {
        frontmostTargetBehavior = behavior
        sessionCoordinator.setFrontmostTargetBehavior(behavior)
    }

    var pendingActivationState: PendingActivationState? {
        pendingActivationState(for: nil)
    }

    var pendingDeactivationState: PendingDeactivationState? {
        pendingDeactivationState(for: nil)
    }

    var stableActivationState: StableActivationState? {
        stableActivationState(for: nil)
    }

    private func pendingActivationState(for bundleIdentifier: String?) -> PendingActivationState? {
        let session = sessionCoordinator.pendingActivationSession(for: bundleIdentifier)
        return session.map {
            PendingActivationState(
                bundleIdentifier: $0.bundleIdentifier,
                previousBundleIdentifier: $0.previousBundle,
                generation: $0.generation,
                startedAt: $0.activationStartedAt
            )
        }
    }

    private func pendingDeactivationState(for bundleIdentifier: String?) -> PendingDeactivationState? {
        let session = sessionCoordinator.pendingDeactivationSession(for: bundleIdentifier)
        guard let session, let appName = session.appName else {
            return nil
        }
        return PendingDeactivationState(
            bundleIdentifier: session.bundleIdentifier,
            appName: appName,
            previousBundleIdentifier: session.previousBundle,
            activationPath: session.activationPath,
            generation: session.generation,
            startedAt: session.phaseStartedAt
        )
    }

    private func stableActivationState(for bundleIdentifier: String?) -> StableActivationState? {
        let session = sessionCoordinator.stableSession(for: bundleIdentifier)
        guard let session, let confirmedAt = session.confirmedAt else {
            return nil
        }
        return StableActivationState(
            bundleIdentifier: session.bundleIdentifier,
            previousBundleIdentifier: session.previousBundle,
            generation: session.generation,
            startedAt: session.activationStartedAt,
            confirmedAt: confirmedAt
        )
    }

    @discardableResult
    func acceptPendingActivation(
        for bundleIdentifier: String,
        previousBundleIdentifier: String?,
        startedAt: CFAbsoluteTime,
        pid: pid_t? = nil
    ) -> PendingActivationState {
        let session = sessionCoordinator.beginActivation(
            for: bundleIdentifier,
            previousBundle: previousBundleIdentifier,
            pid: pid,
            startedAt: startedAt
        )
        return PendingActivationState(
            bundleIdentifier: session.bundleIdentifier,
            previousBundleIdentifier: session.previousBundle,
            generation: session.generation,
            startedAt: startedAt
        )
    }

    @discardableResult
    private func acceptPendingLaunch(
        for shortcut: AppShortcut,
        previousBundleIdentifier: String?,
        startedAt: CFAbsoluteTime
    ) -> PendingActivationState {
        let session = sessionCoordinator.beginLaunch(
            for: shortcut.bundleIdentifier,
            appName: shortcut.appName,
            previousBundle: previousBundleIdentifier,
            startedAt: startedAt
        )
        return PendingActivationState(
            bundleIdentifier: session.bundleIdentifier,
            previousBundleIdentifier: session.previousBundle,
            generation: session.generation,
            startedAt: startedAt
        )
    }

    @discardableResult
    func recordAcceptedTrigger(
        bundleIdentifier: String,
        previousBundleIdentifier: String?,
        startedAt: CFAbsoluteTime
    ) -> Bool {
        _ = acceptPendingActivation(
            for: bundleIdentifier,
            previousBundleIdentifier: previousBundleIdentifier,
            startedAt: startedAt
        )
        return true
    }

    @discardableResult
    func acceptPendingDeactivation(
        for bundleIdentifier: String,
        appName: String,
        previousBundleIdentifier: String?,
        activationPath: ActivationPath,
        startedAt: CFAbsoluteTime,
        pid: pid_t? = nil
    ) -> PendingDeactivationState {
        let session = sessionCoordinator.beginDeactivation(
            for: bundleIdentifier,
            appName: appName,
            previousBundle: previousBundleIdentifier,
            activationPath: activationPath,
            pid: pid,
            startedAt: startedAt
        )
        guard let session else {
            return PendingDeactivationState(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                previousBundleIdentifier: previousBundleIdentifier,
                activationPath: activationPath,
                generation: pendingDeactivationState?.generation ?? -1,
                startedAt: startedAt
            )
        }
        return PendingDeactivationState(
            bundleIdentifier: session.bundleIdentifier,
            appName: session.appName ?? appName,
            previousBundleIdentifier: session.previousBundle,
            activationPath: session.activationPath,
            generation: session.generation,
            startedAt: startedAt
        )
    }

    func shouldToggleOff(bundleIdentifier: String, runningAppIsActive: Bool) -> Bool {
        guard runningAppIsActive else {
            return false
        }
        guard let stableActivationState, stableActivationState.bundleIdentifier == bundleIdentifier else {
            return false
        }
        guard pendingActivationState?.bundleIdentifier != bundleIdentifier else {
            return false
        }
        let coordinatorPhase = sessionCoordinator.session(for: bundleIdentifier)?.phase
        if pendingDeactivationState?.bundleIdentifier == bundleIdentifier || coordinatorPhase == .deactivating {
            return false
        }
        guard coordinatorPhase == .activeStable else {
            DiagnosticLog.log("TOGGLE[\(stableActivationState.bundleIdentifier)]: stableState invalidated by coordinator, phase=\(coordinatorPhase?.rawValue ?? "no_session")")
            return false
        }
        return true
    }

    @discardableResult
    func promotePendingActivationIfCurrent(
        bundleIdentifier: String,
        generation: Int,
        snapshot: ActivationObservationSnapshot
    ) -> Bool {
        guard let pendingActivationState,
              pendingActivationState.bundleIdentifier == bundleIdentifier,
              pendingActivationState.generation == generation,
              canPromoteToStable(with: snapshot) else {
            return false
        }

        return sessionCoordinator.markStable(for: bundleIdentifier, generation: generation) != nil
    }

    func schedulePendingConfirmation(
        state: PendingActivationState,
        shortcut: AppShortcut,
        activationPath: ActivationPath,
        observe: @escaping @MainActor () -> ActivationObservationSnapshot,
        recoverIfNeeded: @escaping @MainActor (WindowRecoveryStage, @escaping @MainActor () -> Void) -> Void
    ) {
        schedulePendingConfirmation(
            state: state,
            shortcut: shortcut,
            activationPath: activationPath,
            delay: 0.075,
            nextRecoveryStage: .makeKeyWindow,
            allowHiddenStateSettleRetry: true,
            observe: observe,
            recoverIfNeeded: recoverIfNeeded
        )
    }

    private func schedulePendingConfirmation(
        state: PendingActivationState,
        shortcut: AppShortcut,
        activationPath: ActivationPath,
        delay: TimeInterval,
        nextRecoveryStage: WindowRecoveryStage?,
        allowHiddenStateSettleRetry: Bool,
        observe: @escaping @MainActor () -> ActivationObservationSnapshot,
        recoverIfNeeded: @escaping @MainActor (WindowRecoveryStage, @escaping @MainActor () -> Void) -> Void
    ) {
        confirmationClient.schedule(delay) { [weak self] in
            guard let self,
                  let pendingActivationState = self.pendingActivationState,
                  pendingActivationState.bundleIdentifier == state.bundleIdentifier,
                  pendingActivationState.generation == state.generation else {
                return
            }

            let snapshot = observe()
            let effectiveStable = self.canPromoteToStable(with: snapshot)
            self.logPostActionState(
                shortcut: shortcut,
                phase: .postActivateState,
                snapshot: snapshot,
                previousBundle: pendingActivationState.previousBundleIdentifier,
                activationPath: activationPath,
                elapsedMilliseconds: self.elapsedMilliseconds(since: pendingActivationState.startedAt),
                effectiveStable: effectiveStable
            )

            if self.promotePendingActivationIfCurrent(
                bundleIdentifier: state.bundleIdentifier,
                generation: state.generation,
                snapshot: snapshot
            ) {
                self.logToggleTrace(
                    family: .confirmation,
                    bundleIdentifier: state.bundleIdentifier,
                    event: "confirmed",
                    reason: "activation_stable",
                    activationPath: activationPath,
                    previousBundle: pendingActivationState.previousBundleIdentifier
                )
                return
            }

            if allowHiddenStateSettleRetry,
               self.shouldRetryObservationForHiddenStateLag(with: snapshot) {
                self.logToggleTrace(
                    family: .confirmation,
                    bundleIdentifier: state.bundleIdentifier,
                    event: "awaiting_hidden_state_settle",
                    reason: "frontmost_window_complete_hidden_lag",
                    activationPath: activationPath,
                    previousBundle: pendingActivationState.previousBundleIdentifier
                )
                self.schedulePendingConfirmation(
                    state: state,
                    shortcut: shortcut,
                    activationPath: activationPath,
                    delay: self.hiddenStateSettleRetryDelay,
                    nextRecoveryStage: nextRecoveryStage,
                    allowHiddenStateSettleRetry: false,
                    observe: observe,
                    recoverIfNeeded: recoverIfNeeded
                )
                return
            }

            if snapshot.targetIsObservedFrontmost,
               snapshot.targetIsActive,
               !snapshot.targetIsHidden,
               !snapshot.allowsWindowlessStableActivation,
               !snapshot.targetHasVisibleWindows,
               !snapshot.hasFocusedWindow,
               !snapshot.hasMainWindow {
                self.logToggleTrace(
                    family: .confirmation,
                    bundleIdentifier: state.bundleIdentifier,
                    event: "awaiting_window_evidence",
                    reason: "frontmost_without_window_evidence",
                    activationPath: activationPath,
                    previousBundle: pendingActivationState.previousBundleIdentifier
                )
            }

            guard let nextRecoveryStage = self.nextRecoveryStage(for: snapshot, candidate: nextRecoveryStage) else {
                self.logToggleTrace(
                    family: .reset,
                    bundleIdentifier: state.bundleIdentifier,
                    event: "session_cleared",
                    reason: "activation_recovery_exhausted",
                    activationPath: activationPath,
                    previousBundle: pendingActivationState.previousBundleIdentifier
                )
                self.clearActivationTracking(for: state.bundleIdentifier, resetPreviousTracking: true)
                return
            }

            recoverIfNeeded(nextRecoveryStage) { [weak self] in
                guard let self else { return }
                self.schedulePendingConfirmation(
                    state: state,
                    shortcut: shortcut,
                    activationPath: activationPath,
                    delay: nextRecoveryStage.settlingDelay,
                    nextRecoveryStage: nextRecoveryStage.nextStage,
                    allowHiddenStateSettleRetry: false,
                    observe: observe,
                    recoverIfNeeded: recoverIfNeeded
                )
            }
        }
    }

    func schedulePendingDeactivation(
        state: PendingDeactivationState,
        shortcut: AppShortcut,
        previousBundle: String?,
        activationPath: ActivationPath,
        observe: @escaping @MainActor () -> ActivationObservationSnapshot
    ) {
        schedulePendingDeactivation(
            state: state,
            shortcut: shortcut,
            previousBundle: previousBundle,
            activationPath: activationPath,
            delay: deactivationConfirmationInitialDelay,
            observe: observe
        )
    }

    private func schedulePendingDeactivation(
        state: PendingDeactivationState,
        shortcut: AppShortcut,
        previousBundle: String?,
        activationPath: ActivationPath,
        delay: TimeInterval,
        observe: @escaping @MainActor () -> ActivationObservationSnapshot
    ) {
        confirmationClient.schedule(delay) { [weak self] in
            guard let self,
                  let pendingDeactivationState = self.pendingDeactivationState,
                  pendingDeactivationState.bundleIdentifier == state.bundleIdentifier,
                  pendingDeactivationState.generation == state.generation else {
                return
            }

            let snapshot = observe()
            let elapsedMilliseconds = self.elapsedMilliseconds(since: state.startedAt)
            let confirmed = self.canConfirmDeactivation(with: snapshot)
            let message = self.postActionLogMessage(
                for: shortcut,
                phase: .postHideState,
                snapshot: snapshot
            ) + " confirmed=\(confirmed)"
            logger.info("\(message)")
            DiagnosticLog.log(message)

            if confirmed {
                self.completePendingDeactivation(for: state.bundleIdentifier)
                self.logToggleTrace(
                    family: .confirmation,
                    bundleIdentifier: state.bundleIdentifier,
                    event: "confirmed",
                    reason: "hide_confirmed",
                    activationPath: activationPath,
                    previousBundle: previousBundle
                )
                self.logToggleLifecycle(
                    for: shortcut,
                    lifecycle: .hideConfirmed,
                    previousBundle: previousBundle,
                    activationPath: activationPath,
                    snapshot: snapshot,
                    elapsedMilliseconds: elapsedMilliseconds
                )
                return
            }

            if self.confirmationClient.now() - state.startedAt >= self.deactivationConfirmationTimeout {
                self.cancelPendingDeactivation(for: state.bundleIdentifier)
                self.logToggleTrace(
                    family: .confirmation,
                    bundleIdentifier: state.bundleIdentifier,
                    event: "degraded",
                    reason: "partial_hide_degraded",
                    activationPath: activationPath,
                    previousBundle: previousBundle
                )
                self.logToggleLifecycle(
                    for: shortcut,
                    lifecycle: .hideDegraded,
                    previousBundle: previousBundle,
                    activationPath: activationPath,
                    snapshot: snapshot,
                    elapsedMilliseconds: elapsedMilliseconds
                )
                return
            }

            self.schedulePendingDeactivation(
                state: state,
                shortcut: shortcut,
                previousBundle: previousBundle,
                activationPath: activationPath,
                delay: self.deactivationConfirmationPollInterval,
                observe: observe
            )
        }
    }

    private func canPromoteToStable(with snapshot: ActivationObservationSnapshot) -> Bool {
        snapshot.isStableActivation
    }

    private func nextRecoveryStage(
        for snapshot: ActivationObservationSnapshot,
        candidate: WindowRecoveryStage?
    ) -> WindowRecoveryStage? {
        guard let candidate else {
            return nil
        }

        if snapshot.targetHasVisibleWindows {
            switch candidate {
            case .makeKeyWindow, .axRaise:
                return candidate
            case .reopen, .commandN:
                return nil
            }
        }

        if candidate == .makeKeyWindow {
            return .axRaise
        }
        return candidate
    }

    private func shouldRetryObservationForHiddenStateLag(with snapshot: ActivationObservationSnapshot) -> Bool {
        snapshot.targetIsObservedFrontmost &&
            snapshot.targetIsActive &&
            snapshot.targetIsHidden &&
            snapshot.targetHasVisibleWindows &&
            snapshot.hasFocusedWindow &&
            snapshot.hasMainWindow
    }

    private func canConfirmDeactivation(with snapshot: ActivationObservationSnapshot) -> Bool {
        !snapshot.targetIsObservedFrontmost && (snapshot.targetIsHidden || !snapshot.targetHasVisibleWindows)
    }

    private func isTargetCurrentlyFrontmost(
        runningApp: NSRunningApplication,
        snapshot: ActivationObservationSnapshot
    ) -> Bool {
        snapshot.targetIsObservedFrontmost || runningApp.isActive
    }

    private func clearActivationTracking(for bundleIdentifier: String, resetPreviousTracking: Bool) {
        if resetPreviousTracking {
            frontmostTracker.resetPreviousAppTracking()
        }
        sessionCoordinator.resetSession(for: bundleIdentifier)
    }

    private func completePendingDeactivation(for bundleIdentifier: String) {
        sessionCoordinator.completeDeactivation(for: bundleIdentifier)
    }

    private func cancelPendingDeactivation(for bundleIdentifier: String) {
        sessionCoordinator.cancelDeactivation(for: bundleIdentifier)
    }

    @discardableResult
    func handleWorkspaceHideNotification(bundleIdentifier: String) -> String? {
        guard let state = pendingDeactivationState,
              state.bundleIdentifier == bundleIdentifier else {
            return nil
        }

        let shortcut = AppShortcut(
            appName: state.appName,
            bundleIdentifier: state.bundleIdentifier,
            keyEquivalent: "",
            modifierFlags: []
        )
        let message = toggleLifecycleLogMessage(
            for: shortcut,
            lifecycle: .hideConfirmed,
            previousBundle: state.previousBundleIdentifier,
            activationPath: state.activationPath,
            elapsedMilliseconds: elapsedMilliseconds(since: state.startedAt)
        )
        logger.info("\(message)")
        DiagnosticLog.log(message)
        completePendingDeactivation(for: bundleIdentifier)
        return message
    }

    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        let attemptStartedAt = confirmationClient.now()

        // Re-entry guard
        guard !isToggling else {
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: BLOCKED re-entry guard")
            logToggleTrace(
                family: .decision,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "blocked",
                reason: "re_entry_guard",
                activationPath: nil,
                previousBundle: sessionCoordinator.previousBundle(for: shortcut.bundleIdentifier)
            )
            return false
        }

        // Per-bundle cooldown
        if let lastTime = lastToggleTimeByBundle[shortcut.bundleIdentifier],
           attemptStartedAt - lastTime < toggleCooldown {
            let elapsed = Int((attemptStartedAt - lastTime) * 1000)
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: BLOCKED cooldown elapsedMs=\(elapsed) limit=\(Int(toggleCooldown * 1000))ms")
            logToggleTrace(
                family: .decision,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "blocked",
                reason: "cooldown",
                activationPath: nil,
                previousBundle: sessionCoordinator.previousBundle(for: shortcut.bundleIdentifier)
            )
            return false
        }

        isToggling = true
        defer {
            isToggling = false
            let now = confirmationClient.now()
            lastToggleTimeByBundle[shortcut.bundleIdentifier] = now
            if lastToggleTimeByBundle.count > cooldownCacheLimit {
                lastToggleTimeByBundle = lastToggleTimeByBundle.filter { now - $0.value < cooldownEvictionWindow }
            }
        }

        guard let runningApp = appLookupClient.runningApplications(shortcut.bundleIdentifier).first else {
            // App not running — launch it
            if let appURL = appLookupClient.applicationURL(shortcut.bundleIdentifier) {
                frontmostTracker.noteCurrentFrontmostApp(excluding: shortcut.bundleIdentifier)
                _ = acceptPendingLaunch(
                    for: shortcut,
                    previousBundleIdentifier: frontmostTracker.lastNonTargetBundleIdentifier,
                    startedAt: attemptStartedAt
                )
                logToggleTrace(
                    family: .session,
                    bundleIdentifier: shortcut.bundleIdentifier,
                    event: "session_started",
                    reason: "not_running_launch_request",
                    activationPath: .launch,
                    previousBundle: frontmostTracker.lastNonTargetBundleIdentifier
                )
                logger.info("TOGGLE[\(shortcut.appName)]: NOT RUNNING → launching")
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: NOT RUNNING → launching, saved previous=\(frontmostTracker.lastNonTargetBundleIdentifier ?? "nil")")
                logToggleLifecycle(
                    for: shortcut,
                    lifecycle: .attempt,
                    previousBundle: frontmostTracker.lastNonTargetBundleIdentifier,
                    activationPath: .launch,
                    elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
                )
                let bundleId = shortcut.bundleIdentifier
                let configuration = NSWorkspace.OpenConfiguration()
                fallbackActivationClient.openApplication(appURL, configuration) { [weak self] launchedApp, error in
                    if let error {
                        logger.error("Failed to launch \(bundleId): \(error.localizedDescription)")
                        DiagnosticLog.log("Failed to launch \(bundleId): \(error.localizedDescription)")
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.logToggleTrace(
                                family: .reset,
                                bundleIdentifier: bundleId,
                                event: "session_cleared",
                                reason: "launch_failed",
                                activationPath: .launch,
                                previousBundle: self.sessionCoordinator.previousBundle(for: bundleId)
                            )
                            self.clearActivationTracking(for: bundleId, resetPreviousTracking: true)
                        }
                        return
                    }

                    let launchedProcessIdentifier = launchedApp?.processIdentifier
                    Task { @MainActor [weak self] in
                        self?.continueOwnedLaunchConfirmation(
                            for: shortcut,
                            launchedProcessIdentifier: launchedProcessIdentifier
                        )
                    }
                }
                return true
            }
            logger.error("TOGGLE[\(shortcut.appName)]: NOT RUNNING, no URL found — cannot launch")
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: NOT RUNNING, no URL found — cannot launch")
            return false
        }

        _ = sessionCoordinator.updateProcessIdentifier(
            for: shortcut.bundleIdentifier,
            pid: runningApp.processIdentifier
        )

        let preActionWindowObservation = applicationObservation.windowObservation(for: runningApp)
        let preActionSnapshot = applicationObservation.snapshot(
            for: runningApp,
            windowObservation: preActionWindowObservation
        )

        if stableActivationState?.bundleIdentifier == shortcut.bundleIdentifier,
           pendingDeactivationState?.bundleIdentifier != shortcut.bundleIdentifier,
           !preActionSnapshot.isStableActivation {
            logToggleTrace(
                family: .reset,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "session_invalidated",
                reason: "stale_state_invalidated",
                activationPath: sessionCoordinator.session(for: shortcut.bundleIdentifier)?.activationPath,
                previousBundle: sessionCoordinator.previousBundle(for: shortcut.bundleIdentifier)
            )
            sessionCoordinator.resetSession(for: shortcut.bundleIdentifier)
        }

        if let pendingDeactivationState, pendingDeactivationState.bundleIdentifier == shortcut.bundleIdentifier {
            if canConfirmDeactivation(with: preActionSnapshot) {
                completePendingDeactivation(for: shortcut.bundleIdentifier)
            } else {
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: DEACTIVATING pending=true elapsedMs=\(elapsedMilliseconds(since: pendingDeactivationState.startedAt))")
            }
            return true
        }

        if let pendingActivationState = pendingActivationState(for: shortcut.bundleIdentifier),
           canPromoteToStable(with: preActionSnapshot) {
            logToggleTrace(
                family: .decision,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "pending_promoted",
                reason: "activation_pending_now_stable",
                activationPath: sessionCoordinator.session(for: shortcut.bundleIdentifier)?.activationPath,
                previousBundle: pendingActivationState.previousBundleIdentifier
            )
            _ = promotePendingActivationIfCurrent(
                bundleIdentifier: shortcut.bundleIdentifier,
                generation: pendingActivationState.generation,
                snapshot: preActionSnapshot
            )
        }

        if isTargetCurrentlyFrontmost(runningApp: runningApp, snapshot: preActionSnapshot) {
            switch frontmostTargetBehavior {
            case .focus:
                return performFrontmostFocus(
                    shortcut: shortcut,
                    runningApp: runningApp,
                    windows: preActionWindowObservation.windows,
                    snapshot: preActionSnapshot,
                    attemptStartedAt: attemptStartedAt
                )
            case .hide:
                var previousApp = sessionCoordinator.previousBundle(for: shortcut.bundleIdentifier)
                    ?? stableActivationState?.previousBundleIdentifier
                    ?? frontmostTracker.lastNonTargetBundleIdentifier
                if previousApp == shortcut.bundleIdentifier {
                    previousApp = nil
                }
                let activationPath: ActivationPath = stableActivationState?.bundleIdentifier == shortcut.bundleIdentifier
                    ? .hide
                    : .hideUntracked
                let deactivationState = acceptPendingDeactivation(
                    for: shortcut.bundleIdentifier,
                    appName: shortcut.appName,
                    previousBundleIdentifier: previousApp,
                    activationPath: activationPath,
                    startedAt: attemptStartedAt,
                    pid: runningApp.processIdentifier
                )
                logToggleTrace(
                    family: .decision,
                    bundleIdentifier: shortcut.bundleIdentifier,
                    event: activationPath == .hide ? "hide_tracked" : "hide_untracked",
                    reason: "frontmost_behavior_hide",
                    activationPath: activationPath,
                    previousBundle: previousApp
                )
                let lifecycle: ToggleLifecycle = activationPath == .hide ? .hideAttempt : .hideUntracked
                logToggleLifecycle(
                    for: shortcut,
                    lifecycle: lifecycle,
                    previousBundle: previousApp,
                    activationPath: activationPath,
                    snapshot: preActionSnapshot,
                    elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
                )
                return performHideToggle(
                    shortcut: shortcut,
                    runningApp: runningApp,
                    state: deactivationState,
                    previousBundle: previousApp,
                    activationPath: activationPath,
                    attemptStartedAt: attemptStartedAt
                )
            case .toggle:
                break
            }
        }

        if shouldToggleOff(bundleIdentifier: shortcut.bundleIdentifier, runningAppIsActive: runningApp.isActive),
           preActionSnapshot.isStableActivation {
            let previousApp = sessionCoordinator.previousBundle(for: shortcut.bundleIdentifier)
                ?? stableActivationState?.previousBundleIdentifier
                ?? frontmostTracker.lastNonTargetBundleIdentifier
            logToggleLifecycle(
                for: shortcut,
                lifecycle: .hideAttempt,
                previousBundle: previousApp,
                activationPath: .hide,
                snapshot: preActionSnapshot,
                elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
            )
            let deactivationState = acceptPendingDeactivation(
                for: shortcut.bundleIdentifier,
                appName: shortcut.appName,
                previousBundleIdentifier: previousApp,
                activationPath: .hide,
                startedAt: attemptStartedAt,
                pid: runningApp.processIdentifier
            )
            return performHideToggle(
                shortcut: shortcut,
                runningApp: runningApp,
                state: deactivationState,
                previousBundle: previousApp,
                activationPath: .hide,
                attemptStartedAt: attemptStartedAt
            )
        }

        // Target is already active and stable but wasn't tracked by us (e.g. restored
        // by another app's toggle-off, or activated externally via Dock/Cmd-Tab).
        // Treat this as a toggle-off: hide the app and let macOS bring up the next one.
        if runningApp.isActive, preActionSnapshot.isStableActivation,
           stableActivationState?.bundleIdentifier != shortcut.bundleIdentifier,
           pendingActivationState?.bundleIdentifier != shortcut.bundleIdentifier {
            let deactivationState = acceptPendingDeactivation(
                for: shortcut.bundleIdentifier,
                appName: shortcut.appName,
                previousBundleIdentifier: nil,
                activationPath: .hideUntracked,
                startedAt: attemptStartedAt,
                pid: runningApp.processIdentifier
            )
            logToggleTrace(
                family: .decision,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "hide_untracked",
                reason: "external_untracked_hide",
                activationPath: .hideUntracked,
                previousBundle: nil
            )
            logToggleLifecycle(
                for: shortcut,
                lifecycle: .hideUntracked,
                previousBundle: nil,
                activationPath: .hideUntracked,
                snapshot: preActionSnapshot,
                elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
            )
            return performHideToggle(
                shortcut: shortcut,
                runningApp: runningApp,
                state: deactivationState,
                previousBundle: nil,
                activationPath: .hideUntracked,
                attemptStartedAt: attemptStartedAt
            )
        }

        if let pendingActivationState, pendingActivationState.bundleIdentifier != shortcut.bundleIdentifier {
            clearActivationTracking(for: pendingActivationState.bundleIdentifier, resetPreviousTracking: true)
        } else if let stableActivationState, stableActivationState.bundleIdentifier != shortcut.bundleIdentifier {
            clearActivationTracking(for: stableActivationState.bundleIdentifier, resetPreviousTracking: true)
        }

        let continuingPendingActivation = pendingActivationState?.bundleIdentifier == shortcut.bundleIdentifier
        if !continuingPendingActivation {
            frontmostTracker.noteCurrentFrontmostApp(excluding: shortcut.bundleIdentifier)
        }
        var previousApp = continuingPendingActivation
            ? pendingActivationState?.previousBundleIdentifier
            : frontmostTracker.lastNonTargetBundleIdentifier
        // Guard against self-referencing previous app (can happen when target was
        // restored by another app's toggle-off — the tracker still holds the old value)
        if previousApp == shortcut.bundleIdentifier {
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: previousApp self-reference detected, clearing")
            previousApp = nil
        }
        let pendingStartedAt = continuingPendingActivation
            ? pendingActivationState?.startedAt ?? attemptStartedAt
            : attemptStartedAt
        let activationPath: ActivationPath = runningApp.isHidden ? .unhideActivate : .activate
        if continuingPendingActivation, !canPromoteToStable(with: preActionSnapshot) {
            logToggleTrace(
                family: .decision,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "blocked",
                reason: "activation_pending_not_stable",
                activationPath: activationPath,
                previousBundle: previousApp
            )
        }
        if runningApp.isActive {
            // Should not normally reach here — ACTIVE_UNTRACKED should have caught it.
            // Log a warning for diagnostics if it happens (e.g. isStableActivation was false).
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: WARNING activate path reached with isActive=true, isStable=\(preActionSnapshot.isStableActivation), stableState=\(stableActivationState?.bundleIdentifier ?? "nil"), pendingState=\(pendingActivationState?.bundleIdentifier ?? "nil")")
        }
        logger.info("TOGGLE[\(shortcut.appName)]: RUNNING NOT FRONT → activating, isHidden=\(runningApp.isHidden)")
        DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: RUNNING NOT FRONT → activating, saved previous=\(previousApp ?? "nil"), isHidden=\(runningApp.isHidden)")
        logToggleLifecycle(
            for: shortcut,
            lifecycle: .attempt,
            previousBundle: previousApp,
            activationPath: activationPath,
            snapshot: preActionSnapshot,
            elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
        )
        if runningApp.isHidden {
            runningApp.unhide()
        }
        let windows = preActionWindowObservation.windows
        unminimizeWindows(of: runningApp, windows: windows)
        let activated = activateViaWindowServer(runningApp, windows: windows)
        guard activated || continuingPendingActivation else {
            clearActivationTracking(for: shortcut.bundleIdentifier, resetPreviousTracking: true)
            return false
        }

        let pendingState: PendingActivationState
        if continuingPendingActivation {
            _ = sessionCoordinator.continueActivation(
                for: shortcut.bundleIdentifier,
                activationPath: activationPath,
                pid: runningApp.processIdentifier
            )
            pendingState = pendingActivationState(for: shortcut.bundleIdentifier)
                ?? PendingActivationState(
                    bundleIdentifier: shortcut.bundleIdentifier,
                    previousBundleIdentifier: previousApp,
                    generation: pendingActivationState?.generation ?? -1,
                    startedAt: pendingStartedAt
                )
        } else {
            pendingState = acceptPendingActivation(
                for: shortcut.bundleIdentifier,
                previousBundleIdentifier: previousApp,
                startedAt: pendingStartedAt,
                pid: runningApp.processIdentifier
            )
        }
        schedulePendingConfirmation(
            state: pendingState,
            shortcut: shortcut,
            activationPath: activationPath,
            observe: { [weak self] in
                guard let self else {
                    return ActivationObservationSnapshot(
                        targetBundleIdentifier: runningApp.bundleIdentifier,
                        observedFrontmostBundleIdentifier: nil,
                        targetIsActive: false,
                        targetIsHidden: true,
                        visibleWindowCount: 0,
                        hasFocusedWindow: false,
                        hasMainWindow: false,
                        windowObservationSucceeded: false,
                        windowObservationFailureReason: "appSwitcherReleased",
                        classification: .windowlessOrAccessory,
                        classificationReason: "app switcher released during confirmation"
                    )
                }
                let confirmationWindowObservation = self.applicationObservation.windowObservation(for: runningApp)
                return self.applicationObservation.snapshot(
                    for: runningApp,
                    windowObservation: confirmationWindowObservation
                )
            },
            recoverIfNeeded: { [weak self] stage, completion in
                self?.recoverActivation(
                    runningApp,
                    shortcut: shortcut,
                    stage: stage,
                    fallbackActivate: {
                        self?.requestFallbackActivation(
                            bundleURL: runningApp.bundleURL,
                            bundleIdentifier: runningApp.bundleIdentifier ?? "\(runningApp.processIdentifier)",
                            plainActivate: {
                                runningApp.activate()
                            }
                        ) ?? false
                    },
                    completion: completion
                )
            }
        )
        return true
    }

    private func performFrontmostFocus(
        shortcut: AppShortcut,
        runningApp: NSRunningApplication,
        windows: [AXUIElement]?,
        snapshot: ActivationObservationSnapshot,
        attemptStartedAt: CFAbsoluteTime
    ) -> Bool {
        if runningApp.isHidden {
            runningApp.unhide()
        }
        unminimizeWindows(of: runningApp, windows: windows)
        let activated = activateViaWindowServer(runningApp, windows: windows)
        logToggleTrace(
            family: .decision,
            bundleIdentifier: shortcut.bundleIdentifier,
            event: "focus_frontmost",
            reason: "frontmost_behavior_focus",
            activationPath: .activate,
            previousBundle: sessionCoordinator.previousBundle(for: shortcut.bundleIdentifier)
        )
        logToggleLifecycle(
            for: shortcut,
            lifecycle: .attempt,
            previousBundle: sessionCoordinator.previousBundle(for: shortcut.bundleIdentifier),
            activationPath: .activate,
            snapshot: snapshot,
            elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
        )
        return activated || runningApp.isActive
    }

    // MARK: - Toggle-off lanes

    private func performHideToggle(
        shortcut: AppShortcut,
        runningApp: NSRunningApplication,
        state: PendingDeactivationState,
        previousBundle: String?,
        activationPath: ActivationPath,
        attemptStartedAt: CFAbsoluteTime
    ) -> Bool {
        confirmationClient.schedule(Self.hideRequestDispatchDelay) { [weak self] in
            guard let self,
                  let pendingDeactivationState = self.pendingDeactivationState,
                  pendingDeactivationState.bundleIdentifier == state.bundleIdentifier,
                  pendingDeactivationState.generation == state.generation else {
                return
            }
            let apiReturn = self.hideRequestClient.hideApplication(runningApp)
            DiagnosticLog.log(
                "TOGGLE[\(shortcut.appName)]: \(Self.hideRequestLogEvent) transport=\(Self.hideTransport.rawValue) apiReturn=\(apiReturn) pid=\(runningApp.processIdentifier) elapsedMs=\(self.elapsedMilliseconds(since: attemptStartedAt))"
            )
        }

        schedulePendingDeactivation(
            state: state,
            shortcut: shortcut,
            previousBundle: previousBundle,
            activationPath: activationPath,
            observe: { [weak self] in
                guard let self else {
                    return ActivationObservationSnapshot(
                        targetBundleIdentifier: runningApp.bundleIdentifier,
                        observedFrontmostBundleIdentifier: nil,
                        targetIsActive: false,
                        targetIsHidden: true,
                        visibleWindowCount: 0,
                        hasFocusedWindow: false,
                        hasMainWindow: false,
                        windowObservationSucceeded: false,
                        windowObservationFailureReason: "appSwitcherReleased",
                        classification: .windowlessOrAccessory,
                        classificationReason: "app switcher released during hide confirmation"
                    )
                }
                let windowObservation = self.applicationObservation.windowObservation(for: runningApp)
                return self.applicationObservation.snapshot(
                    for: runningApp,
                    windowObservation: windowObservation
                )
            }
        )
        return true
    }

    private func continueOwnedLaunchConfirmation(
        for shortcut: AppShortcut,
        launchedProcessIdentifier: pid_t?
    ) {
        guard let pendingState = pendingActivationState(for: shortcut.bundleIdentifier) else {
            return
        }

        let runningApp = appLookupClient.runningApplications(shortcut.bundleIdentifier)
            .first { runningApp in
                guard let launchedProcessIdentifier else { return true }
                return runningApp.processIdentifier == launchedProcessIdentifier
            }
        guard let runningApp else {
            logToggleTrace(
                family: .confirmation,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "awaiting_process",
                reason: "launch_completion_missing_process",
                activationPath: .launch,
                previousBundle: pendingState.previousBundleIdentifier
            )
            return
        }

        _ = sessionCoordinator.continueActivation(
            for: shortcut.bundleIdentifier,
            activationPath: .launch,
            pid: runningApp.processIdentifier
        )
        logToggleTrace(
            family: .session,
            bundleIdentifier: shortcut.bundleIdentifier,
            event: "launch_attached",
            reason: "launch_completion_process_lookup",
            activationPath: .launch,
            previousBundle: pendingState.previousBundleIdentifier
        )

        let preActionWindowObservation = applicationObservation.windowObservation(for: runningApp)
        let preActionSnapshot = applicationObservation.snapshot(
            for: runningApp,
            windowObservation: preActionWindowObservation
        )

        if promotePendingActivationIfCurrent(
            bundleIdentifier: shortcut.bundleIdentifier,
            generation: pendingState.generation,
            snapshot: preActionSnapshot
        ) {
            logToggleTrace(
                family: .confirmation,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "confirmed",
                reason: "activation_stable",
                activationPath: .launch,
                previousBundle: pendingState.previousBundleIdentifier
            )
            return
        }

        if runningApp.isHidden {
            runningApp.unhide()
        }
        let windows = preActionWindowObservation.windows
        unminimizeWindows(of: runningApp, windows: windows)
        _ = activateViaWindowServer(runningApp, windows: windows)

        let continuedState = pendingActivationState(for: shortcut.bundleIdentifier) ?? pendingState
        schedulePendingConfirmation(
            state: continuedState,
            shortcut: shortcut,
            activationPath: .launch,
            observe: { [weak self] in
                guard let self else {
                    return ActivationObservationSnapshot(
                        targetBundleIdentifier: runningApp.bundleIdentifier,
                        observedFrontmostBundleIdentifier: nil,
                        targetIsActive: false,
                        targetIsHidden: true,
                        visibleWindowCount: 0,
                        hasFocusedWindow: false,
                        hasMainWindow: false,
                        windowObservationSucceeded: false,
                        windowObservationFailureReason: "appSwitcherReleased",
                        classification: .windowlessOrAccessory,
                        classificationReason: "app switcher released during confirmation"
                    )
                }
                let confirmationWindowObservation = self.applicationObservation.windowObservation(for: runningApp)
                return self.applicationObservation.snapshot(
                    for: runningApp,
                    windowObservation: confirmationWindowObservation
                )
            },
            recoverIfNeeded: { [weak self] stage, completion in
                self?.recoverActivation(
                    runningApp,
                    shortcut: shortcut,
                    stage: stage,
                    fallbackActivate: {
                        self?.requestFallbackActivation(
                            bundleURL: runningApp.bundleURL,
                            bundleIdentifier: runningApp.bundleIdentifier ?? "\(runningApp.processIdentifier)",
                            plainActivate: {
                                runningApp.activate()
                            }
                        ) ?? false
                    },
                    completion: completion
                )
            }
        )
    }

    // MARK: - Activation path

    /// Default activation is minimal: front-process only.
    /// Window/key-order recovery is observation-driven and escalates separately.
    private func activateViaWindowServer(_ app: NSRunningApplication, windows: [AXUIElement]?) -> Bool {
        let windowID = firstWindowID(from: windows)
        switch activateProcess(
            pid: app.processIdentifier,
            windowID: windowID,
            fallbackActivate: {
                self.requestFallbackActivation(
                    bundleURL: app.bundleURL,
                    bundleIdentifier: app.bundleIdentifier ?? "\(app.processIdentifier)",
                    plainActivate: {
                        app.activate()
                    }
                )
            }
        ) {
        case .skyLight:
            return true
        case .fallback(let activated):
            return activated
        }
    }

    func activateProcess(
        pid: pid_t,
        windowID: CGWindowID?,
        fallbackActivate: () -> Bool
    ) -> ActivationResult {
        switch activationClient.activateFrontProcess(pid, windowID) {
        case .success(let psn):
            return .skyLight(psn)
        case .processLookupFailed(let status):
            logger.error("GetProcessForPID failed for pid \(pid): \(status)")
            DiagnosticLog.log("GetProcessForPID failed for pid \(pid): \(status)")
            return .fallback(fallbackActivate())
        case .activationFailed(let result):
            logger.error("_SLPSSetFrontProcessWithOptions failed: \(result.rawValue), falling back")
            DiagnosticLog.log("SkyLight activation failed: \(result.rawValue), falling back to modern activation request")
            return .fallback(fallbackActivate())
        }
    }

    func requestFallbackActivation(
        bundleURL: URL?,
        bundleIdentifier: String,
        plainActivate: () -> Bool
    ) -> Bool {
        guard let bundleURL else {
            return plainActivate()
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        fallbackActivationClient.openApplication(bundleURL, configuration) { _, error in
            if let error {
                logger.error("Fallback activation via NSWorkspace failed for \(bundleIdentifier): \(error.localizedDescription)")
                DiagnosticLog.log("Fallback activation via NSWorkspace failed for \(bundleIdentifier): \(error.localizedDescription)")
            }
        }
        return true
    }

    /// Send a WindowServer event to make a specific window the key window.
    /// Uses the 0xf8 byte pattern from alt-tab-macos.
    private func makeKeyWindow(psn: inout ProcessSerialNumber, windowID: CGWindowID) {
        // 176-byte event record (alt-tab pattern: bytes[0x3a] = 0x10, wid at offset 0x3c)
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xF8  // record length
        bytes[0x08] = 0x01  // event type
        bytes[0x3a] = 0x10  // sub-type: makeKeyWindow

        // Write windowID at offset 0x3c (little-endian UInt32)
        let widBytes = withUnsafeBytes(of: windowID.littleEndian) { Array($0) }
        for (i, b) in widBytes.enumerated() {
            bytes[0x3c + i] = b
        }

        let postResult = SLPSPostEventRecordTo(&psn, &bytes)
        if postResult != .success {
            #if DEBUG
            logger.debug("makeKeyWindow: SLPSPostEventRecordTo failed: \(postResult.rawValue)")
            #endif
        }
    }

    /// Raise the first window via AX kAXRaiseAction using pre-fetched windows.
    private func raiseFirstWindow(from windows: [AXUIElement]?) {
        guard let firstWindow = windows?.first else { return }
        AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
    }

    /// Get the CGWindowID of the first window via _AXUIElementGetWindow private API.
    /// This ID is needed for Space-aware activation and makeKeyWindow.
    private func firstWindowID(from windows: [AXUIElement]?) -> CGWindowID? {
        guard let firstWindow = windows?.first else { return nil }
        var windowID: CGWindowID = 0
        let axResult = _AXUIElementGetWindow(firstWindow, &windowID)
        guard axResult == .success, windowID != 0 else { return nil }
        return windowID
    }

    // MARK: - Observation-driven activation recovery

    private func recoverActivation(
        _ app: NSRunningApplication,
        shortcut: AppShortcut,
        stage: WindowRecoveryStage,
        fallbackActivate: () -> Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        switch stage {
        case .makeKeyWindow:
            let windows = fetchWindows(of: app)
            guard let windowID = firstWindowID(from: windows) else {
                logger.info("TOGGLE[\(shortcut.appName)]: activation recovery stage=makeKeyWindow skipped (no window id)")
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: activation recovery stage=makeKeyWindow skipped (no window id)")
                completion()
                return
            }

            switch activateProcess(
                pid: app.processIdentifier,
                windowID: windowID,
                fallbackActivate: fallbackActivate
            ) {
            case .skyLight(var psn):
                makeKeyWindow(psn: &psn, windowID: windowID)
            case .fallback:
                break
            }
            logger.info("TOGGLE[\(shortcut.appName)]: activation recovery stage=makeKeyWindow")
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: activation recovery stage=makeKeyWindow")
            completion()
        case .axRaise:
            let windows = fetchWindows(of: app)
            if hasVisibleWindows(of: app, windows: windows) {
                raiseFirstWindow(from: windows)
                logger.info("TOGGLE[\(shortcut.appName)]: activation recovery stage=axRaise")
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: activation recovery stage=axRaise")
            } else {
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementPerformAction(axApp, kAXRaiseAction as CFString)
                logger.info("TOGGLE[\(shortcut.appName)]: window recovery stage=axRaise")
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: window recovery stage=axRaise")
            }
            completion()
        case .reopen:
            guard let appURL = appLookupClient.applicationURL(shortcut.bundleIdentifier) else {
                logger.info("TOGGLE[\(shortcut.appName)]: sending ⌘N (no app URL)")
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: sending ⌘N (no app URL)")
                recoverActivation(
                    app,
                    shortcut: shortcut,
                    stage: .commandN,
                    fallbackActivate: fallbackActivate,
                    completion: completion
                )
                return
            }

            let config = NSWorkspace.OpenConfiguration()
            fallbackActivationClient.openApplication(appURL, config) { @Sendable _, error in
                if let error {
                    logger.error("TOGGLE[\(shortcut.appName)]: NSWorkspace.open failed: \(error.localizedDescription)")
                    DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: NSWorkspace.open failed: \(error.localizedDescription)")
                } else {
                    logger.info("TOGGLE[\(shortcut.appName)]: window recovery stage=reopen")
                    DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: window recovery stage=reopen")
                }

                Task { @MainActor in
                    completion()
                }
            }
        case .commandN:
            logger.info("TOGGLE[\(shortcut.appName)]: sending ⌘N as fallback")
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: sending ⌘N as fallback")
            openNewWindow(of: app)
            completion()
        }
    }

    // MARK: - Window helpers

    /// Fetch all AX windows for the given app (single IPC roundtrip).
    private func fetchWindows(of app: NSRunningApplication) -> [AXUIElement]? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            logger.error("fetchWindows: AXWindows failed for pid \(app.processIdentifier), result=\(result.rawValue)")
            DiagnosticLog.log("fetchWindows: AXWindows failed for pid \(app.processIdentifier), result=\(result.rawValue)")
            return nil
        }
        return windows
    }

    /// Unminimize all minimized windows using pre-fetched window list.
    private func unminimizeWindows(of app: NSRunningApplication, windows: [AXUIElement]?) {
        guard let windows else {
            logger.error("unminimize: no windows for pid \(app.processIdentifier)")
            DiagnosticLog.log("unminimize: no windows for pid \(app.processIdentifier)")
            return
        }
        #if DEBUG
        logger.debug("unminimize: found \(windows.count) windows for pid \(app.processIdentifier)")
        #endif
        for (i, window) in windows.enumerated() {
            var minimizedRef: CFTypeRef?
            let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
            if minResult == .success, let isMinimized = minimizedRef as? Bool, isMinimized {
                let setResult = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                #if DEBUG
                logger.debug("unminimize: window[\(i)] was minimized, unminimize result=\(setResult.rawValue)")
                #endif
            }
        }
    }

    /// Check if app has any visible (non-minimized) windows using pre-fetched window list.
    private func hasVisibleWindows(of app: NSRunningApplication, windows: [AXUIElement]?) -> Bool {
        guard let windows else { return false }
        for window in windows {
            var minimizedRef: CFTypeRef?
            let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
            if minResult != .success || !(minimizedRef as? Bool ?? false) {
                return true // not minimized = visible
            }
        }
        return false
    }

    /// Open a new window by pressing ⌘N via CGEvent.
    private func openNewWindow(of app: NSRunningApplication) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_N), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_N), keyDown: false) else { return }
        keyDown.flags = CGEventFlags.maskCommand
        keyUp.flags = CGEventFlags.maskCommand
        let pid = app.processIdentifier
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }

    private func logPostActionState(
        shortcut: AppShortcut,
        phase: PostActionPhase,
        snapshot: ActivationObservationSnapshot,
        previousBundle: String?,
        activationPath: ActivationPath,
        elapsedMilliseconds: Int,
        effectiveStable: Bool? = nil
    ) {
        let message = postActionLogMessage(
            for: shortcut,
            phase: phase,
            snapshot: snapshot,
            effectiveStable: effectiveStable
        )
        logger.info("\(message)")
        DiagnosticLog.log(message)

        logToggleLifecycle(
            for: shortcut,
            lifecycle: .confirmation,
            previousBundle: previousBundle,
            activationPath: activationPath,
            snapshot: snapshot,
            elapsedMilliseconds: elapsedMilliseconds,
            effectiveStable: effectiveStable
        )
        logToggleLifecycle(
            for: shortcut,
            lifecycle: (effectiveStable ?? snapshot.isStableActivation) ? .stable : .degraded,
            previousBundle: previousBundle,
            activationPath: activationPath,
            snapshot: snapshot,
            elapsedMilliseconds: elapsedMilliseconds,
            effectiveStable: effectiveStable
        )
    }

    func postActionLogMessage(
        for shortcut: AppShortcut,
        phase: PostActionPhase,
        snapshot: ActivationObservationSnapshot,
        effectiveStable: Bool? = nil
    ) -> String {
        let state = TogglePostActionState(snapshot: snapshot)
        let sessionFields = sessionLogFields(for: shortcut.bundleIdentifier)
        return "TOGGLE[\(shortcut.appName)]: \(phase.rawValue) \(state.logDetails) \(snapshot.structuredLogFields(stableOverride: effectiveStable)) \(sessionFields.joined(separator: " "))"
    }

    func toggleLifecycleLogMessage(
        for shortcut: AppShortcut,
        lifecycle: ToggleLifecycle,
        previousBundle: String?,
        activationPath: ActivationPath,
        snapshot: ActivationObservationSnapshot? = nil,
        elapsedMilliseconds: Int,
        effectiveStable: Bool? = nil
    ) -> String {
        var fields = [
            "target=\(shortcut.bundleIdentifier)",
            "previous=\(previousBundle ?? "nil")",
            "activationPath=\(activationPath.rawValue)",
            "elapsedMs=\(elapsedMilliseconds)"
        ]

        if let snapshot {
            fields.append(snapshot.structuredLogFields(stableOverride: effectiveStable))
        } else {
            fields.append(ActivationObservationSnapshot.quotedField("frontmost", frontmostTracker.currentFrontmostBundleIdentifier()))
        }
        fields.append(contentsOf: sessionLogFields(for: shortcut.bundleIdentifier))

        return "TOGGLE[\(shortcut.appName)]: \(lifecycle.rawValue) \(fields.joined(separator: " "))"
    }

    private func logToggleLifecycle(
        for shortcut: AppShortcut,
        lifecycle: ToggleLifecycle,
        previousBundle: String?,
        activationPath: ActivationPath,
        snapshot: ActivationObservationSnapshot? = nil,
        elapsedMilliseconds: Int,
        effectiveStable: Bool? = nil
    ) {
        let message = toggleLifecycleLogMessage(
            for: shortcut,
            lifecycle: lifecycle,
            previousBundle: previousBundle,
            activationPath: activationPath,
            snapshot: snapshot,
            elapsedMilliseconds: elapsedMilliseconds,
            effectiveStable: effectiveStable
        )
        logger.info("\(message)")
        DiagnosticLog.log(message)
    }

    private func elapsedMilliseconds(since startedAt: CFAbsoluteTime) -> Int {
        Int((confirmationClient.now() - startedAt) * 1000)
    }

    private func sessionLogFields(for bundleIdentifier: String) -> [String] {
        guard let session = sessionCoordinator.session(for: bundleIdentifier) else {
            return ["attemptId=nil", "pid=nil", "phase=nil"]
        }
        return [
            "attemptId=\(session.attemptID.uuidString)",
            "pid=\(session.pid.map(String.init) ?? "nil")",
            "phase=\(session.phase.rawValue)"
        ]
    }

    private func logToggleTrace(
        family: ToggleDiagnosticEvent.Family,
        bundleIdentifier: String,
        event: String,
        reason: String?,
        activationPath: ActivationPath?,
        previousBundle: String?
    ) {
        let session = sessionCoordinator.session(for: bundleIdentifier)
        let message = ToggleDiagnosticEvent(
            family: family,
            attemptID: session?.attemptID,
            bundleIdentifier: bundleIdentifier,
            pid: session?.pid,
            phase: session?.phase,
            event: event,
            activationPath: activationPath ?? session?.activationPath,
            reason: reason,
            previousBundleIdentifier: previousBundle ?? session?.previousBundle
        ).logMessage
        logger.info("\(message)")
        DiagnosticLog.log(message)
    }

    nonisolated static let hideTransport: HideTransport = .runningApplicationHide
    nonisolated static let hideRequestLogEvent = "HIDE_REQUEST"
    nonisolated static let hideRequestDispatchDelay: TimeInterval = 0
    nonisolated static let windowServerActivationMode: WindowServerActivationMode = .frontProcessOnly
}

extension AppSwitcher.ActivationClient {
    @MainActor
    static let live = AppSwitcher.ActivationClient(
        activateFrontProcess: { pid, windowID in
            var psn = ProcessSerialNumber()
            let status = GetProcessForPID(pid, &psn)
            guard status == noErr else {
                return .processLookupFailed(status)
            }

            let result = _SLPSSetFrontProcessWithOptions(&psn, windowID ?? 0, SLPSMode.userGenerated.rawValue)
            guard result == .success else {
                return .activationFailed(result)
            }

            return .success(psn)
        }
    )
}

extension AppSwitcher.FallbackActivationClient {
    @MainActor
    static let live = AppSwitcher.FallbackActivationClient(
        openApplication: { url, configuration, completion in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { @Sendable app, error in
                completion(app, error)
            }
        }
    )
}

extension AppSwitcher.HideRequestClient {
    @MainActor
    static let live = AppSwitcher.HideRequestClient(
        hideApplication: { app in
            app.hide()
        }
    )
}

extension AppSwitcher.AppLookupClient {
    @MainActor
    static let live = AppSwitcher.AppLookupClient(
        runningApplications: { bundleIdentifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        },
        applicationURL: { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
    )
}

extension AppSwitcher.ConfirmationClient {
    @MainActor
    static let live = AppSwitcher.ConfirmationClient(
        now: {
            CFAbsoluteTimeGetCurrent()
        },
        schedule: { delay, operation in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Task { @MainActor in
                    operation()
                }
            }
        }
    )
}
