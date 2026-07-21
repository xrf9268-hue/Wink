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
        let generation: Int
        let startedAt: CFAbsoluteTime
    }

    struct PendingDeactivationState: Equatable, Sendable {
        let bundleIdentifier: String
        let appName: String
        let activationPath: ActivationPath
        let generation: Int
        let startedAt: CFAbsoluteTime
    }

    struct StableActivationState: Equatable, Sendable {
        let bundleIdentifier: String
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

    struct WindowCycleClient {
        let windowID: (AXUIElement) -> CGWindowID?
        let focusedWindowID: (pid_t) -> CGWindowID?
        let raiseWindow: (AXUIElement) -> Void
        let unminimizeWindow: (AXUIElement) -> Void
        /// Seam over the WindowServer event post so tests never send real
        /// CGSEventRecords with forged PSNs.
        let makeKeyWindow: (ProcessSerialNumber, CGWindowID) -> Void
    }

    struct AppLookupClient {
        let runningApplications: (String) -> [NSRunningApplication]
        let applicationURL: (String) -> URL?
    }

    struct ConfirmationClient {
        let now: @MainActor () -> CFAbsoluteTime
        let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    }

    struct RecoveryClient {
        let perform: @MainActor (
            WindowRecoveryStage,
            @escaping @MainActor () -> Void
        ) -> Void
    }

    private let frontmostTracker: FrontmostApplicationTracker
    private let applicationObservation: ApplicationObservation
    private let activationClient: ActivationClient
    private let fallbackActivationClient: FallbackActivationClient
    private let hideRequestClient: HideRequestClient
    private let appLookupClient: AppLookupClient
    private let confirmationClient: ConfirmationClient
    private let recoveryClient: RecoveryClient?
    private let sessionCoordinator: ToggleSessionCoordinator
    private let windowCycleClient: WindowCycleClient
    private let windowCycleCoordinator: WindowCycleCoordinator
    private var frontmostTargetBehavior: FrontmostTargetBehavior = .toggle

    /// Re-entry guard: prevents nested calls to toggleApplication on the same run loop turn.
    private var isToggling = false
    /// Per-bundle cooldown: tracks when each bundle was last toggled to prevent rapid re-triggers.
    private var lastToggleTimeByBundle: [String: CFAbsoluteTime] = [:]
    /// Minimum interval (seconds) between toggles of the same bundle.
    private let toggleCooldown: TimeInterval = 0.4
    /// Shorter per-bundle cooldown applied only when the Cycle behavior will
    /// handle this press (target already frontmost): repeat presses are the
    /// deliberate gesture there, so 0.4s would fight the interaction. The
    /// Hyper route's separate 200ms EventTap debounce still applies upstream.
    private let cycleToggleCooldown: TimeInterval = 0.15
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
        windowCycleCoordinator.stopObservingWorkspaceNotifications()
    }

    init(
        frontmostTracker: FrontmostApplicationTracker = FrontmostApplicationTracker(),
        applicationObservation: ApplicationObservation = .live,
        activationClient: ActivationClient = .live,
        fallbackActivationClient: FallbackActivationClient = .live,
        hideRequestClient: HideRequestClient = .live,
        appLookupClient: AppLookupClient = .live,
        confirmationClient: ConfirmationClient = .live,
        recoveryClient: RecoveryClient? = nil,
        sessionCoordinator: ToggleSessionCoordinator? = nil,
        // Optional with a nil default instead of `= .live`: the Swift 6.1.2
        // (Xcode 16.4 CI) SILGen crashes with signal 11 while lowering this
        // initializer's default-argument thunk when the default is the
        // @MainActor static `.live` value; a nil literal generator is
        // trivial and the `.live` access moves into the isolated init body.
        windowCycleClient: WindowCycleClient? = nil,
        windowCycleCoordinator: WindowCycleCoordinator? = nil
    ) {
        self.frontmostTracker = frontmostTracker
        self.applicationObservation = applicationObservation
        self.activationClient = activationClient
        self.fallbackActivationClient = fallbackActivationClient
        self.hideRequestClient = hideRequestClient
        self.appLookupClient = appLookupClient
        self.confirmationClient = confirmationClient
        self.recoveryClient = recoveryClient
        self.sessionCoordinator = sessionCoordinator ?? ToggleSessionCoordinator(now: confirmationClient.now)
        self.windowCycleClient = windowCycleClient ?? .live
        self.windowCycleCoordinator = windowCycleCoordinator ?? WindowCycleCoordinator(now: confirmationClient.now)
        self.sessionCoordinator.startObservingWorkspaceNotifications()
        self.windowCycleCoordinator.startObservingWorkspaceNotifications()
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
        // Unconditional: overrides decouple live sessions from the global
        // value, so even a change *to* .cycleWindows can hand a stale
        // cursor (created by an override-Cycle shortcut) to a different
        // shortcut that now follows the new global setting.
        windowCycleCoordinator.invalidate(reason: "behavior_changed")
    }

    func invalidateWindowCycleSession(reason: String) {
        windowCycleCoordinator.invalidate(reason: reason)
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
            activationPath: session.activationPath,
            generation: session.generation,
            startedAt: session.phaseStartedAt
        )
    }

    private func stableActivationState(for bundleIdentifier: String?) -> StableActivationState? {
        let session = sessionCoordinator.stableOrDeactivatingSession(for: bundleIdentifier)
        guard let session, let confirmedAt = session.confirmedAt else {
            return nil
        }
        return StableActivationState(
            bundleIdentifier: session.bundleIdentifier,
            generation: session.generation,
            startedAt: session.activationStartedAt,
            confirmedAt: confirmedAt
        )
    }

    @discardableResult
    func acceptPendingActivation(
        for bundleIdentifier: String,
        startedAt: CFAbsoluteTime,
        pid: pid_t? = nil
    ) -> PendingActivationState {
        let session = sessionCoordinator.beginActivation(
            for: bundleIdentifier,
            pid: pid,
            startedAt: startedAt
        )
        return PendingActivationState(
            bundleIdentifier: session.bundleIdentifier,
            generation: session.generation,
            startedAt: startedAt
        )
    }

    @discardableResult
    private func acceptPendingLaunch(
        for shortcut: AppShortcut,
        startedAt: CFAbsoluteTime
    ) -> PendingActivationState {
        let session = sessionCoordinator.beginLaunch(
            for: shortcut.bundleIdentifier,
            appName: shortcut.appName,
            startedAt: startedAt
        )
        return PendingActivationState(
            bundleIdentifier: session.bundleIdentifier,
            generation: session.generation,
            startedAt: startedAt
        )
    }

    @discardableResult
    func recordAcceptedTrigger(
        bundleIdentifier: String,
        startedAt: CFAbsoluteTime
    ) -> Bool {
        _ = acceptPendingActivation(
            for: bundleIdentifier,
            startedAt: startedAt
        )
        return true
    }

    @discardableResult
    func acceptPendingDeactivation(
        for bundleIdentifier: String,
        appName: String,
        activationPath: ActivationPath,
        startedAt: CFAbsoluteTime,
        pid: pid_t? = nil
    ) -> PendingDeactivationState {
        let session = sessionCoordinator.beginDeactivation(
            for: bundleIdentifier,
            appName: appName,
            activationPath: activationPath,
            pid: pid,
            startedAt: startedAt
        )
        guard let session else {
            return PendingDeactivationState(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                activationPath: activationPath,
                generation: pendingDeactivationState?.generation ?? -1,
                startedAt: startedAt
            )
        }
        return PendingDeactivationState(
            bundleIdentifier: session.bundleIdentifier,
            appName: session.appName ?? appName,
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
                    activationPath: activationPath
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
                    activationPath: activationPath
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
                    activationPath: activationPath
                )
            }

            guard let nextRecoveryStage = self.nextRecoveryStage(for: snapshot, candidate: nextRecoveryStage) else {
                guard self.sessionCoordinator.markDegraded(
                    for: state.bundleIdentifier,
                    reason: "activation_recovery_exhausted",
                    generation: state.generation
                ) != nil else {
                    return
                }
                self.logToggleTrace(
                    family: .confirmation,
                    bundleIdentifier: state.bundleIdentifier,
                    event: "degraded",
                    reason: "activation_recovery_exhausted",
                    activationPath: activationPath
                )
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
        activationPath: ActivationPath,
        observe: @escaping @MainActor () -> ActivationObservationSnapshot
    ) {
        schedulePendingDeactivation(
            state: state,
            shortcut: shortcut,
            activationPath: activationPath,
            delay: deactivationConfirmationInitialDelay,
            observe: observe
        )
    }

    private func schedulePendingDeactivation(
        state: PendingDeactivationState,
        shortcut: AppShortcut,
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
                    activationPath: activationPath
                )
                self.logToggleLifecycle(
                    for: shortcut,
                    lifecycle: .hideConfirmed,
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
                    activationPath: activationPath
                )
                self.logToggleLifecycle(
                    for: shortcut,
                    lifecycle: .hideDegraded,
                    activationPath: activationPath,
                    snapshot: snapshot,
                    elapsedMilliseconds: elapsedMilliseconds
                )
                return
            }

            self.schedulePendingDeactivation(
                state: state,
                shortcut: shortcut,
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
        !snapshot.targetIsObservedFrontmost &&
            (snapshot.targetIsHidden ||
                (snapshot.windowObservationSucceeded && !snapshot.targetHasVisibleWindows))
    }

    private func isTargetCurrentlyFrontmost(
        snapshot: ActivationObservationSnapshot
    ) -> Bool {
        snapshot.targetIsObservedFrontmost
    }

    private func clearActivationTracking(for bundleIdentifier: String) {
        sessionCoordinator.resetSession(for: bundleIdentifier)
    }

    private func degradedReconfirmationDetails(
        result: String,
        session: ToggleSessionCoordinator.Session?
    ) -> String {
        let retryCount = session?.retryCount ?? 0
        let elapsedMilliseconds = session.map {
            Int(($0.lastActivityAt - $0.activationStartedAt) * 1_000)
        } ?? 0
        return "result=\(result) retryCount=\(retryCount) retryCap=\(sessionCoordinator.configuration.degradedRetryCap) absoluteCeilingMs=\(Int(sessionCoordinator.configuration.absoluteActivationCeiling * 1_000)) elapsedMs=\(elapsedMilliseconds)"
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
            activationPath: state.activationPath,
            elapsedMilliseconds: elapsedMilliseconds(since: state.startedAt)
        )
        logger.info("\(message)")
        DiagnosticLog.log(message)
        completePendingDeactivation(for: bundleIdentifier)
        return message
    }

    @discardableResult
    func toggleApplication(for requestedShortcut: AppShortcut) -> Bool {
        let shortcut: AppShortcut
        if requestedShortcut.isFrontmostAppTarget {
            guard let resolved = resolveFrontmostAppTarget(requestedShortcut) else {
                logToggleTrace(
                    family: .decision,
                    bundleIdentifier: requestedShortcut.bundleIdentifier,
                    event: "blocked",
                    reason: "frontmost_target_unresolved",
                    activationPath: nil
                )
                return false
            }
            shortcut = resolved
        } else {
            shortcut = requestedShortcut
        }

        let attemptStartedAt = confirmationClient.now()

        // Re-entry guard
        guard !isToggling else {
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: BLOCKED re-entry guard")
            logToggleTrace(
                family: .decision,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "blocked",
                reason: "re_entry_guard",
                activationPath: nil
            )
            return false
        }

        // Per-bundle cooldown. The gate runs before the frontmost lane is
        // chosen, so the Cycle relaxation needs its own cheap frontmost
        // pre-check here (workspace snapshot only — no AX on this path).
        let effectiveCooldown = effectiveToggleCooldown(for: shortcut)
        if let lastTime = lastToggleTimeByBundle[shortcut.bundleIdentifier],
           attemptStartedAt - lastTime < effectiveCooldown {
            let elapsed = Int((attemptStartedAt - lastTime) * 1000)
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: BLOCKED cooldown elapsedMs=\(elapsed) limit=\(Int(effectiveCooldown * 1000))ms")
            logToggleTrace(
                family: .decision,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "blocked",
                reason: "cooldown",
                activationPath: nil
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
                let launchState = acceptPendingLaunch(
                    for: shortcut,
                    startedAt: attemptStartedAt
                )
                logToggleTrace(
                    family: .session,
                    bundleIdentifier: shortcut.bundleIdentifier,
                    event: "session_started",
                    reason: "not_running_launch_request",
                    activationPath: .launch
                )
                logger.info("TOGGLE[\(shortcut.appName)]: NOT RUNNING → launching")
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: NOT RUNNING → launching")
                logToggleLifecycle(
                    for: shortcut,
                    lifecycle: .attempt,
                    activationPath: .launch,
                    elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
                )
                let bundleId = shortcut.bundleIdentifier
                let launchGeneration = launchState.generation
                let launchAttemptID = sessionCoordinator.session(for: bundleId)?.attemptID
                let configuration = NSWorkspace.OpenConfiguration()
                fallbackActivationClient.openApplication(appURL, configuration) { [weak self] launchedApp, error in
                    if let error {
                        let errorDescription = error.localizedDescription
                        Task { @MainActor [weak self] in
                            self?.handleOwnedLaunchError(
                                bundleIdentifier: bundleId,
                                expectedGeneration: launchGeneration,
                                expectedAttemptID: launchAttemptID,
                                errorDescription: errorDescription
                            )
                        }
                        return
                    }

                    let launchedProcessIdentifier = launchedApp?.processIdentifier
                    Task { @MainActor [weak self] in
                        self?.continueOwnedLaunchConfirmation(
                            for: shortcut,
                            launchedProcessIdentifier: launchedProcessIdentifier,
                            expectedGeneration: launchGeneration
                        )
                    }
                }
                return true
            }
            logger.error("TOGGLE[\(shortcut.appName)]: NOT RUNNING, no URL found — cannot launch")
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: NOT RUNNING, no URL found — cannot launch")
            return false
        }

        var reconfirmingDegradedSession: ToggleSessionCoordinator.Session?
        let degradedReconfirmDecision = sessionCoordinator.reconfirmDegradedSession(
            for: shortcut.bundleIdentifier
        )
        switch degradedReconfirmDecision.result {
        case .accepted:
            reconfirmingDegradedSession = degradedReconfirmDecision.session
            logToggleTrace(
                family: .decision,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "degraded_reconfirm",
                reason: degradedReconfirmationDetails(
                    result: "accepted",
                    session: degradedReconfirmDecision.session
                ),
                activationPath: nil,
                sessionSnapshot: degradedReconfirmDecision.session
            )
        case .retryCapped:
            logToggleTrace(
                family: .decision,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "degraded_reconfirm",
                reason: degradedReconfirmationDetails(
                    result: "retry_capped",
                    session: degradedReconfirmDecision.session
                ),
                activationPath: nil,
                sessionSnapshot: degradedReconfirmDecision.session
            )
            return true
        case .absoluteCeilingReached:
            logToggleTrace(
                family: .decision,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "degraded_reconfirm",
                reason: degradedReconfirmationDetails(
                    result: "absolute_ceiling_reached",
                    session: degradedReconfirmDecision.session
                ),
                activationPath: nil,
                sessionSnapshot: degradedReconfirmDecision.session
            )
            return true
        case .notDegraded:
            reconfirmingDegradedSession = nil
        }

        let processUpdatedSession = sessionCoordinator.updateProcessIdentifier(
            for: shortcut.bundleIdentifier,
            pid: runningApp.processIdentifier
        )
        if reconfirmingDegradedSession != nil {
            reconfirmingDegradedSession = processUpdatedSession ?? reconfirmingDegradedSession
        }

        let preActionWindowObservation = applicationObservation.windowObservation(for: runningApp, phase: .preAction)
        let preActionSnapshot = applicationObservation.snapshot(
            for: runningApp,
            windowObservation: preActionWindowObservation
        )

        if let reconfirmingDegradedSession {
            return performDegradedReconfirmation(
                shortcut: shortcut,
                runningApp: runningApp,
                windowObservation: preActionWindowObservation,
                snapshot: preActionSnapshot,
                attemptStartedAt: attemptStartedAt,
                session: reconfirmingDegradedSession
            )
        }

        if stableActivationState?.bundleIdentifier == shortcut.bundleIdentifier,
           pendingDeactivationState?.bundleIdentifier != shortcut.bundleIdentifier,
           !preActionSnapshot.isStableActivation {
            logToggleTrace(
                family: .reset,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "session_invalidated",
                reason: "stale_state_invalidated",
                activationPath: sessionCoordinator.session(for: shortcut.bundleIdentifier)?.activationPath
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
                activationPath: sessionCoordinator.session(for: shortcut.bundleIdentifier)?.activationPath
            )
            _ = promotePendingActivationIfCurrent(
                bundleIdentifier: shortcut.bundleIdentifier,
                generation: pendingActivationState.generation,
                snapshot: preActionSnapshot
            )
        }

        if isTargetCurrentlyFrontmost(snapshot: preActionSnapshot) {
            switch effectiveFrontmostBehavior(for: shortcut) {
            case .focus:
                return performFrontmostFocus(
                    shortcut: shortcut,
                    runningApp: runningApp,
                    windowObservation: preActionWindowObservation,
                    snapshot: preActionSnapshot,
                    attemptStartedAt: attemptStartedAt
                )
            case .hide:
                let activationPath: ActivationPath = stableActivationState?.bundleIdentifier == shortcut.bundleIdentifier
                    ? .hide
                    : .hideUntracked
                let deactivationState = acceptPendingDeactivation(
                    for: shortcut.bundleIdentifier,
                    appName: shortcut.appName,
                    activationPath: activationPath,
                    startedAt: attemptStartedAt,
                    pid: runningApp.processIdentifier
                )
                logToggleTrace(
                    family: .decision,
                    bundleIdentifier: shortcut.bundleIdentifier,
                    event: activationPath == .hide ? "hide_tracked" : "hide_untracked",
                    reason: "frontmost_behavior_hide",
                    activationPath: activationPath
                )
                let lifecycle: ToggleLifecycle = activationPath == .hide ? .hideAttempt : .hideUntracked
                logToggleLifecycle(
                    for: shortcut,
                    lifecycle: lifecycle,
                    activationPath: activationPath,
                    snapshot: preActionSnapshot,
                    elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
                )
                return performHideToggle(
                    shortcut: shortcut,
                    runningApp: runningApp,
                    state: deactivationState,
                    activationPath: activationPath,
                    attemptStartedAt: attemptStartedAt
                )
            case .cycleWindows:
                if performFrontmostWindowCycle(
                    shortcut: shortcut,
                    runningApp: runningApp,
                    windowObservation: preActionWindowObservation,
                    snapshot: preActionSnapshot,
                    attemptStartedAt: attemptStartedAt
                ) {
                    // A cycle keeps the target frontmost, so a still-pending
                    // activation session for it is settled evidence: promote
                    // it before its confirmation ladder can re-raise the
                    // first window over the user's cycled choice.
                    if pendingActivationState(for: shortcut.bundleIdentifier) != nil,
                       sessionCoordinator.markStable(for: shortcut.bundleIdentifier) != nil {
                        logToggleTrace(
                            family: .decision,
                            bundleIdentifier: shortcut.bundleIdentifier,
                            event: "pending_promoted",
                            reason: "cycle_settled_frontmost",
                            activationPath: sessionCoordinator.session(for: shortcut.bundleIdentifier)?.activationPath
                        )
                    }
                    return true
                }
                // Fewer than two cyclable windows (or a windows read failure
                // with no gesture in flight). A frontmost-app pseudo-target
                // ends here as a no-op — "cycle the current app" must never
                // hide the app the user is working in. Concrete-app
                // shortcuts fall through to standard toggle semantics so
                // they keep their "step aside" ability.
                logToggleTrace(
                    family: .decision,
                    bundleIdentifier: shortcut.bundleIdentifier,
                    event: shortcut.isFrontmostAppTarget ? "cycle_noop" : "cycle_fallback",
                    reason: preActionWindowObservation.windowsReadSucceeded
                        ? "insufficient_cyclable_windows"
                        : "windows_read_failed",
                    activationPath: nil
                )
                if shortcut.isFrontmostAppTarget {
                    return true
                }
            case .toggle:
                break
            }
        }

        if shouldToggleOff(bundleIdentifier: shortcut.bundleIdentifier, runningAppIsActive: runningApp.isActive),
           preActionSnapshot.isStableActivation {
            logToggleLifecycle(
                for: shortcut,
                lifecycle: .hideAttempt,
                activationPath: .hide,
                snapshot: preActionSnapshot,
                elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
            )
            let deactivationState = acceptPendingDeactivation(
                for: shortcut.bundleIdentifier,
                appName: shortcut.appName,
                activationPath: .hide,
                startedAt: attemptStartedAt,
                pid: runningApp.processIdentifier
            )
            return performHideToggle(
                shortcut: shortcut,
                runningApp: runningApp,
                state: deactivationState,
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
                activationPath: .hideUntracked,
                startedAt: attemptStartedAt,
                pid: runningApp.processIdentifier
            )
            logToggleTrace(
                family: .decision,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "hide_untracked",
                reason: "external_untracked_hide",
                activationPath: .hideUntracked
            )
            logToggleLifecycle(
                for: shortcut,
                lifecycle: .hideUntracked,
                activationPath: .hideUntracked,
                snapshot: preActionSnapshot,
                elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
            )
            return performHideToggle(
                shortcut: shortcut,
                runningApp: runningApp,
                state: deactivationState,
                activationPath: .hideUntracked,
                attemptStartedAt: attemptStartedAt
            )
        }

        if let pendingActivationState, pendingActivationState.bundleIdentifier != shortcut.bundleIdentifier {
            clearActivationTracking(for: pendingActivationState.bundleIdentifier)
        } else if let stableActivationState, stableActivationState.bundleIdentifier != shortcut.bundleIdentifier {
            clearActivationTracking(for: stableActivationState.bundleIdentifier)
        }

        let continuingPendingActivation = pendingActivationState?.bundleIdentifier == shortcut.bundleIdentifier
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
                activationPath: activationPath
            )
        }
        if runningApp.isActive {
            // Should not normally reach here — ACTIVE_UNTRACKED should have caught it.
            // Log a warning for diagnostics if it happens (e.g. isStableActivation was false).
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: WARNING activate path reached with isActive=true, isStable=\(preActionSnapshot.isStableActivation), stableState=\(stableActivationState?.bundleIdentifier ?? "nil"), pendingState=\(pendingActivationState?.bundleIdentifier ?? "nil")")
        }
        logger.info("TOGGLE[\(shortcut.appName)]: RUNNING NOT FRONT → activating, isHidden=\(runningApp.isHidden)")
        DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: RUNNING NOT FRONT → activating, isHidden=\(runningApp.isHidden)")
        logToggleLifecycle(
            for: shortcut,
            lifecycle: .attempt,
            activationPath: activationPath,
            snapshot: preActionSnapshot,
            elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
        )
        if runningApp.isHidden {
            runningApp.unhide()
        }
        unminimizeWindows(of: runningApp, observation: preActionWindowObservation)
        logToggleTrace(
            family: .decision,
            bundleIdentifier: shortcut.bundleIdentifier,
            event: "activation_side_effect",
            reason: "front_process",
            activationPath: activationPath
        )
        let activated = activateViaWindowServer(runningApp, windows: preActionWindowObservation.windows)
        guard activated || continuingPendingActivation else {
            clearActivationTracking(for: shortcut.bundleIdentifier)
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
                    generation: pendingActivationState?.generation ?? -1,
                    startedAt: pendingStartedAt
                )
        } else {
            pendingState = acceptPendingActivation(
                for: shortcut.bundleIdentifier,
                startedAt: pendingStartedAt,
                pid: runningApp.processIdentifier
            )
        }
        scheduleRuntimeActivationConfirmation(
            state: pendingState,
            shortcut: shortcut,
            runningApp: runningApp,
            activationPath: activationPath
        )
        return true
    }

    private func performDegradedReconfirmation(
        shortcut: AppShortcut,
        runningApp: NSRunningApplication,
        windowObservation: ApplicationObservation.WindowObservation,
        snapshot: ActivationObservationSnapshot,
        attemptStartedAt: CFAbsoluteTime,
        session: ToggleSessionCoordinator.Session
    ) -> Bool {
        if canPromoteToStable(with: snapshot) {
            logToggleTrace(
                family: .decision,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "pending_promoted",
                reason: "degraded_reconfirm_now_stable",
                activationPath: session.activationPath,
                sessionSnapshot: session
            )
            guard let stableSession = sessionCoordinator.markStable(
                for: shortcut.bundleIdentifier,
                generation: session.generation
            ) else {
                return true
            }
            logToggleTrace(
                family: .confirmation,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "confirmed",
                reason: "degraded_reconfirm_stable",
                activationPath: stableSession.activationPath,
                sessionSnapshot: stableSession
            )
            return true
        }

        let activationPath: ActivationPath = runningApp.isHidden ? .unhideActivate : .activate
        logger.info("TOGGLE[\(shortcut.appName)]: DEGRADED RECONFIRM → activating, isHidden=\(runningApp.isHidden)")
        DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: DEGRADED RECONFIRM → activating, isHidden=\(runningApp.isHidden)")
        logToggleLifecycle(
            for: shortcut,
            lifecycle: .attempt,
            activationPath: activationPath,
            snapshot: snapshot,
            elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt),
            sessionSnapshot: session
        )
        if runningApp.isHidden {
            runningApp.unhide()
        }
        unminimizeWindows(of: runningApp, observation: windowObservation)
        logToggleTrace(
            family: .decision,
            bundleIdentifier: shortcut.bundleIdentifier,
            event: "activation_side_effect",
            reason: "degraded_reconfirm_front_process",
            activationPath: activationPath,
            sessionSnapshot: session
        )
        _ = activateViaWindowServer(runningApp, windows: windowObservation.windows)

        guard let continuedSession = sessionCoordinator.continueActivation(
            for: shortcut.bundleIdentifier,
            activationPath: activationPath,
            pid: runningApp.processIdentifier
        ) else {
            return true
        }
        let pendingState = PendingActivationState(
            bundleIdentifier: continuedSession.bundleIdentifier,
            generation: continuedSession.generation,
            startedAt: continuedSession.activationStartedAt
        )
        scheduleRuntimeActivationConfirmation(
            state: pendingState,
            shortcut: shortcut,
            runningApp: runningApp,
            activationPath: activationPath
        )
        return true
    }

    private func scheduleRuntimeActivationConfirmation(
        state: PendingActivationState,
        shortcut: AppShortcut,
        runningApp: NSRunningApplication,
        activationPath: ActivationPath
    ) {
        schedulePendingConfirmation(
            state: state,
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
                let confirmationWindowObservation = self.applicationObservation.windowObservation(for: runningApp, phase: .activationConfirmation)
                return self.applicationObservation.snapshot(
                    for: runningApp,
                    windowObservation: confirmationWindowObservation
                )
            },
            recoverIfNeeded: { [weak self] stage, completion in
                guard let self else { return }
                if let recoveryClient = self.recoveryClient {
                    recoveryClient.perform(stage, completion)
                    return
                }
                self.recoverActivation(
                    runningApp,
                    shortcut: shortcut,
                    stage: stage,
                    fallbackActivate: {
                        self.requestFallbackActivation(
                            bundleURL: runningApp.bundleURL,
                            bundleIdentifier: runningApp.bundleIdentifier ?? "\(runningApp.processIdentifier)",
                            plainActivate: {
                                runningApp.activate()
                            }
                        )
                    },
                    completion: completion
                )
            }
        )
    }

    private func performFrontmostFocus(
        shortcut: AppShortcut,
        runningApp: NSRunningApplication,
        windowObservation: ApplicationObservation.WindowObservation,
        snapshot: ActivationObservationSnapshot,
        attemptStartedAt: CFAbsoluteTime
    ) -> Bool {
        if runningApp.isHidden {
            runningApp.unhide()
        }
        unminimizeWindows(of: runningApp, observation: windowObservation)
        let activated = activateViaWindowServer(runningApp, windows: windowObservation.windows)
        logToggleTrace(
            family: .decision,
            bundleIdentifier: shortcut.bundleIdentifier,
            event: "focus_frontmost",
            reason: "frontmost_behavior_focus",
            activationPath: .activate
        )
        logToggleLifecycle(
            for: shortcut,
            lifecycle: .attempt,
            activationPath: .activate,
            snapshot: snapshot,
            elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
        )
        return activated || runningApp.isActive
    }

    /// Cycle to the target app's next window (Cycle frontmost behavior).
    /// Returns false when fewer than two windows are cyclable so the caller
    /// can fall back to standard toggle semantics.
    private func performFrontmostWindowCycle(
        shortcut: AppShortcut,
        runningApp: NSRunningApplication,
        windowObservation: ApplicationObservation.WindowObservation,
        snapshot: ActivationObservationSnapshot,
        attemptStartedAt: CFAbsoluteTime
    ) -> Bool {
        guard windowObservation.windowsReadSucceeded,
              let windows = windowObservation.windows else {
            if windowCycleCoordinator.liveSession(for: shortcut.bundleIdentifier) != nil {
                // Transient AX windows-read failure mid-gesture: swallow the
                // press instead of declining. Declining would fall through
                // to the hide lanes and hide the app the user is actively
                // cycling through.
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: CYCLE windows read failed mid-gesture — press swallowed")
                logToggleTrace(
                    family: .decision,
                    bundleIdentifier: shortcut.bundleIdentifier,
                    event: "cycle_read_failed",
                    reason: "windows_read_failed_mid_gesture",
                    activationPath: nil
                )
                return true
            }
            return false
        }

        var elementsByWindowID: [CGWindowID: AXUIElement] = [:]
        for window in windows {
            guard let windowID = windowCycleClient.windowID(window),
                  elementsByWindowID[windowID] == nil else {
                continue
            }
            elementsByWindowID[windowID] = window
        }
        // Rotation order is the sorted CGWindowID list: stable across
        // presses, unlike kAXWindows order, which reshuffles after a raise.
        // Identity stays the window id, never an index.
        let orderedWindowIDs = elementsByWindowID.keys.sorted()
        guard orderedWindowIDs.count >= 2 else {
            windowCycleCoordinator.invalidate(reason: "insufficient_windows")
            return false
        }

        let focusedWindowID = windowCycleClient.focusedWindowID(runningApp.processIdentifier)
        guard let targetWindowID = windowCycleCoordinator.advance(
            bundleIdentifier: shortcut.bundleIdentifier,
            pid: runningApp.processIdentifier,
            orderedWindowIDs: orderedWindowIDs,
            focusedWindowID: focusedWindowID
        ), let targetElement = elementsByWindowID[targetWindowID] else {
            return false
        }

        if windowObservation.minimizedWindows.contains(where: { CFEqual($0, targetElement) }) {
            windowCycleClient.unminimizeWindow(targetElement)
        }

        // Same trio as full activation, aimed at one window: front the
        // process for this window id, make it key via the WindowServer
        // event record, then AX-raise it.
        switch activateProcess(
            pid: runningApp.processIdentifier,
            windowID: targetWindowID,
            fallbackActivate: {
                self.requestFallbackActivation(
                    bundleURL: runningApp.bundleURL,
                    bundleIdentifier: runningApp.bundleIdentifier ?? "\(runningApp.processIdentifier)",
                    plainActivate: {
                        runningApp.activate()
                    }
                )
            }
        ) {
        case .skyLight(let psn):
            windowCycleClient.makeKeyWindow(psn, targetWindowID)
        case .fallback:
            break
        }
        windowCycleClient.raiseWindow(targetElement)

        let stepIndex = windowCycleCoordinator.session?.stepIndex ?? 0
        let windowCount = windowCycleCoordinator.session?.windowCount ?? orderedWindowIDs.count
        DiagnosticLog.log(
            "TOGGLE[\(shortcut.appName)]: CYCLE step=\(stepIndex)/\(windowCount) wid=\(targetWindowID) elapsedMs=\(elapsedMilliseconds(since: attemptStartedAt))"
        )
        logToggleTrace(
            family: .decision,
            bundleIdentifier: shortcut.bundleIdentifier,
            event: "cycle_window",
            reason: "frontmost_behavior_cycle step=\(stepIndex)/\(windowCount) wid=\(targetWindowID)",
            activationPath: .activate
        )
        logToggleLifecycle(
            for: shortcut,
            lifecycle: .attempt,
            activationPath: .activate,
            snapshot: snapshot,
            elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
        )
        return true
    }

    /// Cycle presses are a deliberate rapid gesture, so the shorter cooldown
    /// applies only to *established* cycling: behavior is Cycle, the target
    /// is frontmost per the workspace snapshot, AND the previous press
    /// actually cycled (live coordinator session). Requiring the session
    /// keeps every press that could fall through to the hide lanes — single
    /// window targets, first repeat press — behind the standard 0.4s safety
    /// net, so non-cycle actions never run at the relaxed cadence.
    private func effectiveToggleCooldown(for shortcut: AppShortcut) -> TimeInterval {
        guard effectiveFrontmostBehavior(for: shortcut) == .cycleWindows,
              windowCycleCoordinator.liveSession(for: shortcut.bundleIdentifier) != nil,
              frontmostTracker.currentFrontmostBundleIdentifier() == shortcut.bundleIdentifier else {
            return toggleCooldown
        }
        return cycleToggleCooldown
    }

    /// The frontmost-target behavior this shortcut actually runs: its own
    /// override when set, the global preference otherwise.
    private func effectiveFrontmostBehavior(for shortcut: AppShortcut) -> FrontmostTargetBehavior {
        shortcut.frontmostBehaviorOverride ?? frontmostTargetBehavior
    }

    /// Rewrite a frontmost-app pseudo-target onto the app that is frontmost
    /// right now, so the rest of the pipeline (cooldown keying, cycle
    /// session identity, traces, usage) sees a concrete bundle. The copy
    /// keeps `target` so downstream lanes can tell it came from a
    /// pseudo-target, and defaults the behavior to Cycle — the whole point
    /// of the key — unless the user explicitly overrode it.
    private func resolveFrontmostAppTarget(_ shortcut: AppShortcut) -> AppShortcut? {
        guard let frontmostApp = frontmostTracker.currentFrontmostApplication(),
              let bundleIdentifier = frontmostApp.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        return AppShortcut(
            id: shortcut.id,
            appName: frontmostApp.localizedName ?? bundleIdentifier,
            bundleIdentifier: bundleIdentifier,
            keyEquivalent: shortcut.keyEquivalent,
            modifierFlags: shortcut.modifierFlags,
            isEnabled: shortcut.isEnabled,
            frontmostBehaviorOverride: shortcut.frontmostBehaviorOverride ?? .cycleWindows,
            target: shortcut.target
        )
    }

    // MARK: - Toggle-off lanes

    private func performHideToggle(
        shortcut: AppShortcut,
        runningApp: NSRunningApplication,
        state: PendingDeactivationState,
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
                let windowObservation = self.applicationObservation.windowObservation(for: runningApp, phase: .deactivationConfirmation)
                return self.applicationObservation.snapshot(
                    for: runningApp,
                    windowObservation: windowObservation
                )
            }
        )
        return true
    }

    private func handleOwnedLaunchError(
        bundleIdentifier: String,
        expectedGeneration: Int,
        expectedAttemptID: UUID?,
        errorDescription: String
    ) {
        guard let pendingState = pendingActivationState(for: bundleIdentifier),
              pendingState.generation == expectedGeneration else {
            logLaunchErrorTrace(
                family: .confirmation,
                bundleIdentifier: bundleIdentifier,
                expectedGeneration: expectedGeneration,
                expectedAttemptID: expectedAttemptID,
                event: "stale_completion_discarded",
                reason: "launch_error_completion_superseded"
            )
            return
        }

        logger.error("Failed to launch \(bundleIdentifier): \(errorDescription)")
        DiagnosticLog.log("Failed to launch \(bundleIdentifier): \(errorDescription)")
        logLaunchErrorTrace(
            family: .reset,
            bundleIdentifier: bundleIdentifier,
            expectedGeneration: expectedGeneration,
            expectedAttemptID: expectedAttemptID,
            event: "session_cleared",
            reason: "launch_failed"
        )
        clearActivationTracking(for: bundleIdentifier)
    }

    private func logLaunchErrorTrace(
        family: ToggleDiagnosticEvent.Family,
        bundleIdentifier: String,
        expectedGeneration: Int,
        expectedAttemptID: UUID?,
        event: String,
        reason: String
    ) {
        let currentSession = sessionCoordinator.session(for: bundleIdentifier)
        let baseMessage = ToggleDiagnosticEvent(
            family: family,
            attemptID: expectedAttemptID,
            bundleIdentifier: bundleIdentifier,
            pid: nil,
            generation: expectedGeneration,
            phase: .launching,
            event: event,
            activationPath: .launch,
            reason: reason
        ).logMessage
        let currentGeneration = currentSession.map { String($0.generation) } ?? "nil"
        let currentPID = currentSession?.pid.map(String.init) ?? "nil"
        let currentPhase = currentSession?.phase.rawValue ?? "nil"
        let message = "\(baseMessage) expectedGeneration=\(expectedGeneration) currentGeneration=\(currentGeneration) currentAttemptId=\(currentSession?.attemptID.uuidString ?? "nil") currentPid=\(currentPID) currentPhase=\(currentPhase)"
        logger.info("\(message)")
        DiagnosticLog.log(message)
    }

    private func continueOwnedLaunchConfirmation(
        for shortcut: AppShortcut,
        launchedProcessIdentifier: pid_t?,
        expectedGeneration: Int
    ) {
        guard let pendingState = pendingActivationState(for: shortcut.bundleIdentifier) else {
            return
        }

        // A slow launch can be superseded by a second press that replaced the
        // pending session (new generation). The superseding session's own
        // completion manages its lifecycle; discard this stale callback before
        // it can overwrite the new session's activationPath/pid.
        guard pendingState.generation == expectedGeneration else {
            logToggleTrace(
                family: .confirmation,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "stale_completion_discarded",
                reason: "launch_completion_superseded",
                activationPath: .launch
            )
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
                activationPath: .launch
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
            activationPath: .launch
        )

        let preActionWindowObservation = applicationObservation.windowObservation(for: runningApp, phase: .launchContinuation)
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
                activationPath: .launch
            )
            return
        }

        if runningApp.isHidden {
            runningApp.unhide()
        }
        unminimizeWindows(of: runningApp, observation: preActionWindowObservation)
        _ = activateViaWindowServer(runningApp, windows: preActionWindowObservation.windows)

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
                let confirmationWindowObservation = self.applicationObservation.windowObservation(for: runningApp, phase: .launchConfirmation)
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

            logToggleTrace(
                family: .confirmation,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "recovery_side_effect",
                reason: "stage=makeKeyWindow",
                activationPath: nil
            )

            switch activateProcess(
                pid: app.processIdentifier,
                windowID: windowID,
                fallbackActivate: fallbackActivate
            ) {
            case .skyLight(let psn):
                windowCycleClient.makeKeyWindow(psn, windowID)
            case .fallback:
                break
            }
            logger.info("TOGGLE[\(shortcut.appName)]: activation recovery stage=makeKeyWindow")
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: activation recovery stage=makeKeyWindow")
            completion()
        case .axRaise:
            let windows = fetchWindows(of: app)
            logToggleTrace(
                family: .confirmation,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "recovery_side_effect",
                reason: "stage=axRaise",
                activationPath: nil
            )
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

            logToggleTrace(
                family: .confirmation,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "recovery_side_effect",
                reason: "stage=reopen",
                activationPath: nil
            )

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
            logToggleTrace(
                family: .confirmation,
                bundleIdentifier: shortcut.bundleIdentifier,
                event: "recovery_side_effect",
                reason: "stage=commandN",
                activationPath: nil
            )
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

    /// Unminimize the windows the observation already found minimized.
    /// Consumes the per-window `kAXMinimized` reads captured during the
    /// single pre-action observation pass instead of re-issuing them — in
    /// the common nothing-minimized case this performs zero AX IPC on the
    /// keypress→activation path.
    private func unminimizeWindows(
        of app: NSRunningApplication,
        observation: ApplicationObservation.WindowObservation
    ) {
        guard observation.windows != nil else {
            logger.error("unminimize: no windows for pid \(app.processIdentifier)")
            DiagnosticLog.log("unminimize: no windows for pid \(app.processIdentifier)")
            return
        }
        for (i, window) in observation.minimizedWindows.enumerated() {
            let setResult = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            #if DEBUG
            logger.debug("unminimize: window[\(i)] was minimized, unminimize result=\(setResult.rawValue)")
            #endif
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
            activationPath: activationPath,
            snapshot: snapshot,
            elapsedMilliseconds: elapsedMilliseconds,
            effectiveStable: effectiveStable
        )
        logToggleLifecycle(
            for: shortcut,
            lifecycle: (effectiveStable ?? snapshot.isStableActivation) ? .stable : .degraded,
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
        activationPath: ActivationPath,
        snapshot: ActivationObservationSnapshot? = nil,
        elapsedMilliseconds: Int,
        effectiveStable: Bool? = nil,
        sessionSnapshot: ToggleSessionCoordinator.Session? = nil
    ) -> String {
        var fields = [
            "target=\(shortcut.bundleIdentifier)",
            "activationPath=\(activationPath.rawValue)",
            "elapsedMs=\(elapsedMilliseconds)"
        ]

        if let snapshot {
            fields.append(snapshot.structuredLogFields(stableOverride: effectiveStable))
        } else {
            fields.append(ActivationObservationSnapshot.quotedField("frontmost", frontmostTracker.currentFrontmostBundleIdentifier()))
        }
        fields.append(contentsOf: sessionLogFields(
            for: shortcut.bundleIdentifier,
            sessionSnapshot: sessionSnapshot
        ))

        return "TOGGLE[\(shortcut.appName)]: \(lifecycle.rawValue) \(fields.joined(separator: " "))"
    }

    private func logToggleLifecycle(
        for shortcut: AppShortcut,
        lifecycle: ToggleLifecycle,
        activationPath: ActivationPath,
        snapshot: ActivationObservationSnapshot? = nil,
        elapsedMilliseconds: Int,
        effectiveStable: Bool? = nil,
        sessionSnapshot: ToggleSessionCoordinator.Session? = nil
    ) {
        let message = toggleLifecycleLogMessage(
            for: shortcut,
            lifecycle: lifecycle,
            activationPath: activationPath,
            snapshot: snapshot,
            elapsedMilliseconds: elapsedMilliseconds,
            effectiveStable: effectiveStable,
            sessionSnapshot: sessionSnapshot
        )
        logger.info("\(message)")
        DiagnosticLog.log(message)
    }

    private func elapsedMilliseconds(since startedAt: CFAbsoluteTime) -> Int {
        Int((confirmationClient.now() - startedAt) * 1000)
    }

    private func sessionLogFields(
        for bundleIdentifier: String,
        sessionSnapshot: ToggleSessionCoordinator.Session? = nil
    ) -> [String] {
        guard let session = sessionSnapshot ?? sessionCoordinator.session(for: bundleIdentifier) else {
            return ["attemptId=nil", "generation=nil", "pid=nil", "phase=nil"]
        }
        return [
            "attemptId=\(session.attemptID.uuidString)",
            "generation=\(session.generation)",
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
        sessionSnapshot: ToggleSessionCoordinator.Session? = nil
    ) {
        let session = sessionSnapshot ?? sessionCoordinator.session(for: bundleIdentifier)
        let message = ToggleDiagnosticEvent(
            family: family,
            attemptID: session?.attemptID,
            bundleIdentifier: bundleIdentifier,
            pid: session?.pid,
            generation: session?.generation,
            phase: session?.phase,
            event: event,
            activationPath: activationPath ?? session?.activationPath,
            reason: reason
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
    static let live: AppSwitcher.FallbackActivationClient = {
        let workspaceClient = AppSwitcher.FallbackActivationClient(
            openApplication: { url, configuration, completion in
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { @Sendable app, error in
                    completion(app, error)
                }
            }
        )

        #if WINK_LAUNCH_FAULT_INJECTION
        if let configuration = LaunchFaultInjectionConfiguration(arguments: ProcessInfo.processInfo.arguments) {
            return LaunchFaultInjector(
                configuration: configuration,
                workspaceOpen: workspaceClient.openApplication
            ).client
        }
        #endif

        return workspaceClient
    }()
}

extension AppSwitcher.HideRequestClient {
    @MainActor
    static let live: AppSwitcher.HideRequestClient = {
        let client = AppSwitcher.HideRequestClient(hideApplication: { app in
            app.hide()
        })

        #if WINK_AX_WINDOW_OBSERVATION_FAULT_INJECTION
        if let driver = AXWindowObservationFaultInjectionRuntime.driver {
            return AppSwitcher.HideRequestClient(hideApplication: { app in
                driver.hideApplication(app, base: client.hideApplication)
            })
        }
        #endif

        return client
    }()
}

/// Byte layout of the CGSEventRecord posted to make another app's window
/// key. Offsets follow CGSInternal's CGSEvent.h; values track current
/// alt-tab-macos/yabai practice.
private enum MakeKeyWindowEvent {
    /// The record declares 0xf8 bytes but the buffer is 0x100: on
    /// macOS 14.7.4+ the WindowServer's CGSEncodeEventRecord reads past
    /// the record and crashes the target on out-of-bounds heap garbage
    /// when handed a tight 0xf8 allocation.
    static let bufferSize = 0x100
    static let lengthOffset = 0x04
    static let recordLength: UInt8 = 0xf8
    static let eventTypeOffset = 0x08
    static let leftMouseDown: UInt8 = 0x01
    static let leftMouseUp: UInt8 = 0x02
    /// Window-relative click point just outside the frame: the pair
    /// still makes the window key, but the point hit-tests to no view,
    /// so nothing in the window is actually clicked (fullscreen
    /// top-left corner included). Kept small — wild values risk the app
    /// clamping the point back onto real content.
    static let windowLocationOffset = 0x20
    static let offContentPoint = CGPoint(x: -1, y: -1)
    /// The event is delivered to this window by id, not by the point.
    static let windowIdOffset = 0x3c
    /// Purpose undocumented; yabai and Hammerspoon set 0x10.
    static let unknownFlagOffset = 0x3a
    static let unknownFlagValue: UInt8 = 0x10
}

/// Make a specific window the key window by posting a synthetic left-click
/// (down then up) to the WindowServer. No public API moves key focus across
/// apps. File-scope (not an AppSwitcher member) so the live client closure
/// below carries no reference back into the class — a member reference here
/// crashes the Swift 6.1 SILGen CI toolchain while lowering the
/// default-argument thunk. Production code reaches this only through the
/// `WindowCycleClient` seam.
private func postMakeKeyWindowEventRecord(psn: ProcessSerialNumber, windowID: CGWindowID) {
    var psn = psn
    var bytes = [UInt8](repeating: 0, count: MakeKeyWindowEvent.bufferSize)
    bytes[MakeKeyWindowEvent.lengthOffset] = MakeKeyWindowEvent.recordLength
    bytes[MakeKeyWindowEvent.unknownFlagOffset] = MakeKeyWindowEvent.unknownFlagValue
    withUnsafeBytes(of: windowID.littleEndian) { widBytes in
        for (i, b) in widBytes.enumerated() {
            bytes[MakeKeyWindowEvent.windowIdOffset + i] = b
        }
    }
    withUnsafeBytes(of: MakeKeyWindowEvent.offContentPoint) { pointBytes in
        for (i, b) in pointBytes.enumerated() {
            bytes[MakeKeyWindowEvent.windowLocationOffset + i] = b
        }
    }

    // The target app reads the down/up pair as "you are now key".
    bytes[MakeKeyWindowEvent.eventTypeOffset] = MakeKeyWindowEvent.leftMouseDown
    let downResult = SLPSPostEventRecordTo(&psn, &bytes)
    bytes[MakeKeyWindowEvent.eventTypeOffset] = MakeKeyWindowEvent.leftMouseUp
    let upResult = SLPSPostEventRecordTo(&psn, &bytes)
    if downResult != .success || upResult != .success {
        #if DEBUG
        logger.debug("makeKeyWindow: SLPSPostEventRecordTo failed down=\(downResult.rawValue) up=\(upResult.rawValue)")
        #endif
    }
}

extension AppSwitcher.WindowCycleClient {
    @MainActor
    static let live = AppSwitcher.WindowCycleClient(
        windowID: { element in
            var windowID: CGWindowID = 0
            let result = _AXUIElementGetWindow(element, &windowID)
            guard result == .success, windowID != 0 else { return nil }
            return windowID
        },
        focusedWindowID: { pid in
            let appElement = AXUIElementCreateApplication(pid)
            // Same bound as ApplicationObservation's app-element reads: a
            // hung target must not stall the main actor for the global AX
            // timeout on the cycle path.
            AXUIElementSetMessagingTimeout(appElement, ApplicationObservation.axMessagingTimeoutSeconds)
            var focusedRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef)
            guard result == .success,
                  let focusedRef,
                  CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
                return nil
            }
            let focusedWindow = focusedRef as! AXUIElement
            var windowID: CGWindowID = 0
            guard _AXUIElementGetWindow(focusedWindow, &windowID) == .success, windowID != 0 else {
                return nil
            }
            return windowID
        },
        raiseWindow: { element in
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        },
        unminimizeWindow: { element in
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        },
        makeKeyWindow: { psn, windowID in
            postMakeKeyWindowEventRecord(psn: psn, windowID: windowID)
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
            // Callers are @MainActor (the client type pins schedule to the
            // main actor), so a zero delay runs inline instead of paying a
            // dispatch-timer turn plus an executor enqueue on the toggle-off
            // hot path. Nonzero delays land on the main queue, which is the
            // main actor's executor — no second hop needed.
            if delay <= 0 {
                operation()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    operation()
                }
            }
        }
    )
}
