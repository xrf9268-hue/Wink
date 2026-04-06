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

    struct StableActivationState: Equatable, Sendable {
        let bundleIdentifier: String
        let previousBundleIdentifier: String?
        let generation: Int
        let startedAt: CFAbsoluteTime
        let confirmedAt: CFAbsoluteTime
    }

    enum WindowRecoveryStage: String, Sendable {
        case axRaise
        case reopen
        case commandN

        var nextStage: Self? {
            switch self {
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
        case postRestoreState = "POST_RESTORE_STATE"
    }

    enum ActivationPath: String {
        case launch
        case restorePrevious = "restore_previous"
        case hideUntracked = "hide_untracked"
        case activate
        case unhideActivate = "unhide_activate"
    }

    enum ToggleLifecycle: String {
        case attempt = "TOGGLE_ATTEMPT"
        case restoreAttempt = "TOGGLE_RESTORE_ATTEMPT"
        case hideUntracked = "TOGGLE_HIDE_UNTRACKED"
        case confirmation = "TOGGLE_CONFIRMATION"
        case stable = "TOGGLE_STABLE"
        case degraded = "TOGGLE_DEGRADED"
        case restoreConfirmed = "TOGGLE_RESTORE_CONFIRMED"
        case restoreDegraded = "TOGGLE_RESTORE_DEGRADED"
    }

    struct ActivationClient {
        let activateFrontProcess: (pid_t, CGWindowID?) -> FrontProcessActivationResult
    }

    struct FallbackActivationClient {
        let openApplication: (URL, NSWorkspace.OpenConfiguration, @escaping @Sendable (Error?) -> Void) -> Void
    }

    struct ConfirmationClient {
        let now: @MainActor () -> CFAbsoluteTime
        let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    }

    private let frontmostTracker: FrontmostApplicationTracker
    private let applicationObservation: ApplicationObservation
    private let activationClient: ActivationClient
    private let fallbackActivationClient: FallbackActivationClient
    private let confirmationClient: ConfirmationClient
    private let sessionCoordinator: ToggleSessionCoordinator
    private let toggleRuntime: ToggleRuntime
    private let latestGenerationStore: LatestGenerationStore
    private var nextPendingGeneration = 0
    private(set) var pendingActivationState: PendingActivationState?
    private(set) var stableActivationState: StableActivationState?

    /// Re-entry guard: prevents nested calls to toggleApplication on the same run loop turn.
    private var isToggling = false
    /// Per-bundle cooldown: tracks when each bundle was last toggled to prevent rapid re-triggers.
    private var lastToggleTimeByBundle: [String: CFAbsoluteTime] = [:]
    /// Minimum interval (seconds) between toggles of the same bundle.
    private let toggleCooldown: TimeInterval = 0.4
    private let cooldownCacheLimit = 20
    private let cooldownEvictionWindow: CFAbsoluteTime = 60

    init(
        frontmostTracker: FrontmostApplicationTracker = FrontmostApplicationTracker(),
        applicationObservation: ApplicationObservation = .live,
        activationClient: ActivationClient = .live,
        fallbackActivationClient: FallbackActivationClient = .live,
        confirmationClient: ConfirmationClient = .live,
        sessionCoordinator: ToggleSessionCoordinator = ToggleSessionCoordinator(),
        toggleRuntime: ToggleRuntime = ToggleRuntime(),
        latestGenerationStore: LatestGenerationStore = LatestGenerationStore()
    ) {
        self.frontmostTracker = frontmostTracker
        self.applicationObservation = applicationObservation
        self.activationClient = activationClient
        self.fallbackActivationClient = fallbackActivationClient
        self.confirmationClient = confirmationClient
        self.sessionCoordinator = sessionCoordinator
        self.toggleRuntime = toggleRuntime
        self.latestGenerationStore = latestGenerationStore
        sessionCoordinator.startObservingWorkspaceNotifications()
    }

    @discardableResult
    func acceptPendingActivation(
        for bundleIdentifier: String,
        previousBundleIdentifier: String?,
        startedAt: CFAbsoluteTime
    ) -> PendingActivationState {
        nextPendingGeneration += 1
        let state = PendingActivationState(
            bundleIdentifier: bundleIdentifier,
            previousBundleIdentifier: previousBundleIdentifier,
            generation: nextPendingGeneration,
            startedAt: startedAt
        )
        pendingActivationState = state
        if stableActivationState?.bundleIdentifier == bundleIdentifier {
            stableActivationState = nil
        }
        sessionCoordinator.beginActivation(for: bundleIdentifier, previousBundle: previousBundleIdentifier)
        latestGenerationStore.write(state.generation)
        return state
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
        // Coordinator may have invalidated the session via notification
        let coordinatorPhase = sessionCoordinator.session(for: bundleIdentifier)?.phase
        guard coordinatorPhase == .activeStable else {
            DiagnosticLog.log("TOGGLE[\(stableActivationState.bundleIdentifier)]: stableState invalidated by coordinator, phase=\(coordinatorPhase?.rawValue ?? "no_session")")
            self.stableActivationState = nil
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

        stableActivationState = StableActivationState(
            bundleIdentifier: bundleIdentifier,
            previousBundleIdentifier: pendingActivationState.previousBundleIdentifier,
            generation: generation,
            startedAt: pendingActivationState.startedAt,
            confirmedAt: confirmationClient.now()
        )
        self.pendingActivationState = nil
        sessionCoordinator.markStable(for: bundleIdentifier)

        // Seed the tap context cache so future toggle-off can track fast-lane misses.
        // Without this upsert, markFastLaneMiss is a no-op (guard on existing entry).
        let now = confirmationClient.now()
        toggleRuntime.tapContextCache.upsert(
            targetBundleIdentifier: bundleIdentifier,
            coordinatorPreviousBundle: stableActivationState?.previousBundleIdentifier,
            restoreContext: RestoreContext(
                targetBundleIdentifier: bundleIdentifier,
                previousBundleIdentifier: stableActivationState?.previousBundleIdentifier,
                previousPID: nil,
                previousPSNHint: nil,
                previousWindowIDHint: nil,
                previousBundleURL: nil,
                capturedAt: now,
                generation: generation
            )
        )

        return true
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
            nextRecoveryStage: .axRaise,
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
                return
            }

            guard self.shouldAttemptRecovery(for: snapshot), let nextRecoveryStage else {
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
                    observe: observe,
                    recoverIfNeeded: recoverIfNeeded
                )
            }
        }
    }

    private func shouldAttemptRecovery(for snapshot: ActivationObservationSnapshot) -> Bool {
        !snapshot.targetHasVisibleWindows
    }

    private func canPromoteToStable(with snapshot: ActivationObservationSnapshot) -> Bool {
        snapshot.isStableActivation && !shouldAttemptRecovery(for: snapshot)
    }

    private func clearActivationTracking(for bundleIdentifier: String, resetPreviousTracking: Bool) {
        if pendingActivationState?.bundleIdentifier == bundleIdentifier {
            pendingActivationState = nil
        }
        if stableActivationState?.bundleIdentifier == bundleIdentifier {
            stableActivationState = nil
        }
        if resetPreviousTracking {
            frontmostTracker.resetPreviousAppTracking()
        }
        sessionCoordinator.resetSession(for: bundleIdentifier)
    }

    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        let attemptStartedAt = confirmationClient.now()

        // Re-entry guard
        guard !isToggling else {
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: BLOCKED re-entry guard")
            return false
        }

        // Per-bundle cooldown
        if let lastTime = lastToggleTimeByBundle[shortcut.bundleIdentifier],
           attemptStartedAt - lastTime < toggleCooldown {
            let elapsed = Int((attemptStartedAt - lastTime) * 1000)
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: BLOCKED cooldown elapsedMs=\(elapsed) limit=\(Int(toggleCooldown * 1000))ms")
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

        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: shortcut.bundleIdentifier).first else {
            // App not running — launch it
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: shortcut.bundleIdentifier) {
                frontmostTracker.noteCurrentFrontmostApp(excluding: shortcut.bundleIdentifier)
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
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { @Sendable app, error in
                    if let error {
                        logger.error("Failed to launch \(bundleId): \(error.localizedDescription)")
                        DiagnosticLog.log("Failed to launch \(bundleId): \(error.localizedDescription)")
                    }
                }
                return true
            }
            logger.error("TOGGLE[\(shortcut.appName)]: NOT RUNNING, no URL found — cannot launch")
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: NOT RUNNING, no URL found — cannot launch")
            return false
        }

        let preActionWindowObservation = applicationObservation.windowObservation(for: runningApp)
        let preActionSnapshot = applicationObservation.snapshot(
            for: runningApp,
            windowObservation: preActionWindowObservation
        )

        if stableActivationState?.bundleIdentifier == shortcut.bundleIdentifier, !preActionSnapshot.isStableActivation {
            stableActivationState = nil
        }

        if shouldToggleOff(bundleIdentifier: shortcut.bundleIdentifier, runningAppIsActive: runningApp.isActive),
           preActionSnapshot.isStableActivation {
            let shadowPreviousApp = sessionCoordinator.previousBundle(for: shortcut.bundleIdentifier)
                ?? stableActivationState?.previousBundleIdentifier
                ?? frontmostTracker.lastNonTargetBundleIdentifier
            let runtimeDecision = toggleRuntime.decision(
                targetBundleIdentifier: shortcut.bundleIdentifier,
                previousBundleIdentifier: shadowPreviousApp,
                classification: preActionSnapshot.classification,
                attemptStartedAt: attemptStartedAt
            )
            if case .shadow(let shadowDecision) = runtimeDecision {
                DiagnosticLog.log("TOGGLE_SHADOW[\(shortcut.appName)]: lane=\(shadowDecision.selectedLane) wouldHide=\(shadowDecision.wouldUseHideTarget) previous=\(shadowDecision.previousBundleIdentifier ?? "nil")")
            }
            let previousApp = sessionCoordinator.previousBundle(for: shortcut.bundleIdentifier)
                ?? stableActivationState?.previousBundleIdentifier
                ?? frontmostTracker.lastNonTargetBundleIdentifier
            sessionCoordinator.beginDeactivation(for: shortcut.bundleIdentifier)
            logToggleLifecycle(
                for: shortcut,
                lifecycle: .restoreAttempt,
                previousBundle: previousApp,
                activationPath: .restorePrevious,
                snapshot: preActionSnapshot,
                elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
            )
            if let trackerPrevious = frontmostTracker.lastNonTargetBundleIdentifier, trackerPrevious != previousApp {
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: RESTORE_DIVERGENCE resolvedPrevious=\(previousApp ?? "nil") trackerPrevious=\(trackerPrevious)")
            }

            if case .execute(.fastLane) = runtimeDecision {
                return performFastLaneToggle(
                    shortcut: shortcut,
                    runningApp: runningApp,
                    previousApp: previousApp,
                    preActionSnapshot: preActionSnapshot,
                    attemptStartedAt: attemptStartedAt
                )
            }

            return performCompatibilityToggle(
                shortcut: shortcut,
                runningApp: runningApp,
                previousApp: previousApp,
                preActionSnapshot: preActionSnapshot,
                attemptStartedAt: attemptStartedAt
            )
        }

        // Target is already active and stable but wasn't tracked by us (e.g. restored
        // by another app's toggle-off, or activated externally via Dock/Cmd-Tab).
        // Treat this as a toggle-off: hide the app and let macOS bring up the next one.
        if runningApp.isActive, preActionSnapshot.isStableActivation,
           stableActivationState?.bundleIdentifier != shortcut.bundleIdentifier,
           pendingActivationState?.bundleIdentifier != shortcut.bundleIdentifier {
            let axUntrackedTarget = AXUIElementCreateApplication(runningApp.processIdentifier)
            let axUntrackedResult = AXUIElementSetAttributeValue(
                axUntrackedTarget,
                kAXHiddenAttribute as CFString,
                kCFBooleanTrue as CFTypeRef
            )
            let hidden = (axUntrackedResult == .success)
            logger.info("TOGGLE[\(shortcut.appName)]: ACTIVE_UNTRACKED → hiding, hidden=\(hidden)")
            logToggleLifecycle(
                for: shortcut,
                lifecycle: .hideUntracked,
                previousBundle: nil,
                activationPath: .hideUntracked,
                snapshot: preActionSnapshot,
                elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
            )
            clearActivationTracking(for: shortcut.bundleIdentifier, resetPreviousTracking: true)
            return hidden
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

        let pendingState = acceptPendingActivation(
            for: shortcut.bundleIdentifier,
            previousBundleIdentifier: previousApp,
            startedAt: pendingStartedAt
        )
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
                self?.recoverWindowlessApp(
                    runningApp,
                    shortcut: shortcut,
                    stage: stage,
                    completion: completion
                )
            }
        )
        return true
    }

    // MARK: - Toggle-off lanes

    private struct RestorePreviousResult {
        let restored: Bool
        let restoredBundle: String?
        let resolvedApp: NSRunningApplication?
    }

    /// Lookup, unhide, and activate the previous app via three-layer SkyLight.
    /// Returns nil only when no previous bundle identifier is available.
    private func restorePreviousApp(bundle: String?) -> RestorePreviousResult? {
        guard let prevBundle = bundle,
              let prevApp = NSRunningApplication.runningApplications(withBundleIdentifier: prevBundle).first else {
            return nil
        }
        if prevApp.isHidden { prevApp.unhide() }
        let prevWindows = applicationObservation.windowObservation(for: prevApp)
        let restored = activateViaWindowServer(prevApp, windows: prevWindows.windows)
        return RestorePreviousResult(restored: restored, restoredBundle: prevBundle, resolvedApp: prevApp)
    }

    /// Fast lane: restore previous app via SkyLight WITHOUT hiding the target first.
    /// Uses ObservationBroker for 75ms cheap confirmation. On miss, falls back to
    /// compatibility lane and tracks the miss in TapContextCache for quarantine.
    private func performFastLaneToggle(
        shortcut: AppShortcut,
        runningApp: NSRunningApplication,
        previousApp: String?,
        preActionSnapshot: ActivationObservationSnapshot,
        attemptStartedAt: CFAbsoluteTime
    ) -> Bool {
        let restoreResult = restorePreviousApp(bundle: previousApp)
        guard let result = restoreResult, result.restored else {
            let reason = restoreResult == nil ? "no previous app" : "restore failed"
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: FAST_LANE \(reason), falling back to compatibility restoreErrorCode=\(restoreResult == nil ? "noTarget" : "activationFailed")")
            return performCompatibilityToggle(
                shortcut: shortcut,
                runningApp: runningApp,
                previousApp: previousApp,
                preActionSnapshot: preActionSnapshot,
                attemptStartedAt: attemptStartedAt
            )
        }

        let broker = ObservationBroker(
            client: ObservationBroker.Client(
                frontmostBundleIdentifier: { [weak self] in
                    self?.frontmostTracker.currentFrontmostBundleIdentifier()
                },
                targetIsHidden: { runningApp.isHidden },
                targetIsActive: { runningApp.isActive },
                targetClassification: { preActionSnapshot.classification },
                escalatedSnapshot: { [weak self] in
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
                            classificationReason: "app switcher released during fast lane confirmation"
                        )
                    }
                    let windowObs = self.applicationObservation.windowObservation(for: runningApp)
                    return self.applicationObservation.snapshot(for: runningApp, windowObservation: windowObs)
                },
                now: { [weak self] in
                    self?.confirmationClient.now() ?? CFAbsoluteTimeGetCurrent()
                },
                pollOnce: { interval in
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
                }
            ),
            confirmationWindow: toggleRuntime.configuration.fastConfirmationWindow
        )

        let confirmation = broker.confirmFastRestore(
            targetBundleIdentifier: shortcut.bundleIdentifier,
            previousBundleIdentifier: previousApp
        )

        let cacheInvalidationReason = toggleRuntime.tapContextCache.lastInvalidationReason(for: shortcut.bundleIdentifier)?.rawValue
        DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: FAST_LANE confirmed=\(confirmation.confirmed) escalated=\(confirmation.usedEscalatedObservation) frontmost=\(confirmation.frontmostBundleAfterRestore ?? "nil") elapsedMs=\(elapsedMilliseconds(since: attemptStartedAt)) cacheInvalidationReason=\(cacheInvalidationReason ?? "nil")")

        if confirmation.confirmed {
            frontmostTracker.confirmRestoreAttempt()
            clearActivationTracking(for: shortcut.bundleIdentifier, resetPreviousTracking: false)
            let postRestoreWindowObservation = applicationObservation.windowObservation(for: runningApp)
            let postRestoreSnapshot = applicationObservation.snapshot(
                for: runningApp,
                windowObservation: postRestoreWindowObservation
            )
            logPostActionState(
                shortcut: shortcut,
                phase: .postRestoreState,
                snapshot: postRestoreSnapshot,
                previousBundle: result.restoredBundle,
                activationPath: .restorePrevious,
                elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
            )
            return true
        }

        DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: FAST_LANE_MISS lane=fast fallbackCount=1 cacheInvalidationReason=\(cacheInvalidationReason ?? "nil") elapsedMs=\(elapsedMilliseconds(since: attemptStartedAt))")
        toggleRuntime.tapContextCache.markFastLaneMiss(
            for: shortcut.bundleIdentifier,
            now: confirmationClient.now(),
            threshold: toggleRuntime.configuration.fastLaneMissThreshold,
            window: toggleRuntime.configuration.fastLaneMissWindow,
            quarantine: toggleRuntime.configuration.temporaryCompatibilityWindow
        )

        return performCompatibilityToggle(
            shortcut: shortcut,
            runningApp: runningApp,
            previousApp: previousApp,
            preActionSnapshot: preActionSnapshot,
            attemptStartedAt: attemptStartedAt
        )
    }

    /// Compatibility lane: hide the target via AX first, then restore the previous app
    /// via SkyLight three-layer activation. This is the original toggle-off behavior.
    private func performCompatibilityToggle(
        shortcut: AppShortcut,
        runningApp: NSRunningApplication,
        previousApp: String?,
        preActionSnapshot: ActivationObservationSnapshot,
        attemptStartedAt: CFAbsoluteTime
    ) -> Bool {
        // AX hide instead of NSRunningApplication.hide() — the latter returns false
        // from LSUIElement/accessory apps on macOS 15. Hiding first forces macOS to
        // activate another app, making SkyLight activation of the previous app immediate.
        let axTarget = AXUIElementCreateApplication(runningApp.processIdentifier)
        let axHideResult = AXUIElementSetAttributeValue(
            axTarget,
            kAXHiddenAttribute as CFString,
            kCFBooleanTrue as CFTypeRef
        )
        let hidden = (axHideResult == .success)
        let axHideErrorCode: String? = hidden ? nil : String(axHideResult.rawValue)

        let restored: Bool
        let restoredBundle: String?
        if let result = restorePreviousApp(bundle: previousApp) {
            restored = result.restored
            restoredBundle = result.restoredBundle
        } else {
            let restoreAttempt = frontmostTracker.restorePreviousAppIfPossible()
            restored = restoreAttempt.restoreAccepted
            restoredBundle = restoreAttempt.bundleIdentifier
        }
        let restoreErrorCode: String? = restored ? nil : "activationFailed"
        let compatCacheReason = toggleRuntime.tapContextCache.lastInvalidationReason(for: shortcut.bundleIdentifier)?.rawValue
        logger.info("TOGGLE[\(shortcut.appName)]: IS ACTIVE → restored=\(restored), hidden=\(hidden)")
        DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: IS ACTIVE lane=compatibility restored=\(restored) (prev=\(restoredBundle ?? previousApp ?? "nil")) hidden=\(hidden) axHideErrorCode=\(axHideErrorCode ?? "nil") restoreErrorCode=\(restoreErrorCode ?? "nil") cacheInvalidationReason=\(compatCacheReason ?? "nil") elapsedMs=\(elapsedMilliseconds(since: attemptStartedAt))")
        let postRestoreWindowObservation = applicationObservation.windowObservation(for: runningApp)
        let postRestoreSnapshot = applicationObservation.snapshot(
            for: runningApp,
            windowObservation: postRestoreWindowObservation
        )
        if !postRestoreSnapshot.targetIsObservedFrontmost {
            frontmostTracker.confirmRestoreAttempt()
        }

        // Degraded recovery: SkyLight restore reported success but produced no
        // visual change (e.g. previous app is windowless Finder).  Fall back to
        // NSRunningApplication.hide() so macOS picks the next foreground app
        // naturally — matching Thor's "hide then let macOS decide" strategy.
        if postRestoreSnapshot.targetIsObservedFrontmost {
            let nsHideResult = runningApp.hide()
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: DEGRADED_RECOVERY nsHide=\(nsHideResult) elapsedMs=\(elapsedMilliseconds(since: attemptStartedAt))")
        }

        clearActivationTracking(for: shortcut.bundleIdentifier, resetPreviousTracking: false)
        logPostActionState(
            shortcut: shortcut,
            phase: .postRestoreState,
            snapshot: postRestoreSnapshot,
            previousBundle: restoredBundle ?? previousApp,
            activationPath: .restorePrevious,
            elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
        )
        return restored || hidden
    }

    // MARK: - Three-layer activation (reference: alt-tab-macos)

    /// Activate app using three-layer approach:
    /// 1. _SLPSSetFrontProcessWithOptions — activate the process (with windowID for Space switching)
    /// 2. SLPSPostEventRecordTo — make the window the key window
    /// 3. AXUIElementPerformAction(kAXRaiseAction) — ensure correct Z-order
    private func activateViaWindowServer(_ app: NSRunningApplication, windows: [AXUIElement]?) -> Bool {
        // Get the first window's CGWindowID for Space-aware activation
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
        case .skyLight(var psn):
            // Layer 2: Make the target window the key window via WindowServer event
            if let wid = windowID {
                makeKeyWindow(psn: &psn, windowID: wid)
            }

            // Layer 3: Raise the first window via Accessibility to ensure correct Z-order
            raiseFirstWindow(from: windows)
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
        fallbackActivationClient.openApplication(bundleURL, configuration) { error in
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

    // MARK: - Windowless app recovery (reference: alt-tab + Hammerspoon)

    /// Try multiple strategies to get a window for a windowless app:
    /// 1. AX kAXRaiseAction on the app element — some apps auto-recover
    /// 2. NSWorkspace.shared.open(url) — like clicking Dock icon
    /// 3. ⌘N fallback — last resort
    private func recoverWindowlessApp(
        _ app: NSRunningApplication,
        shortcut: AppShortcut,
        stage: WindowRecoveryStage,
        completion: @escaping @MainActor () -> Void
    ) {
        switch stage {
        case .axRaise:
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementPerformAction(axApp, kAXRaiseAction as CFString)
            logger.info("TOGGLE[\(shortcut.appName)]: window recovery stage=axRaise")
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: window recovery stage=axRaise")
            completion()
        case .reopen:
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: shortcut.bundleIdentifier) else {
                logger.info("TOGGLE[\(shortcut.appName)]: sending ⌘N (no app URL)")
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: sending ⌘N (no app URL)")
                recoverWindowlessApp(app, shortcut: shortcut, stage: .commandN, completion: completion)
                return
            }

            let config = NSWorkspace.OpenConfiguration()
            fallbackActivationClient.openApplication(appURL, config) { @Sendable error in
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

        if phase == .postRestoreState {
            let lifecycle: ToggleLifecycle = snapshot.targetIsObservedFrontmost ? .restoreDegraded : .restoreConfirmed
            if lifecycle == .restoreDegraded, let prevBundle = previousBundle {
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: RESTORE_DEGRADED_DETAIL previousBundle=\(prevBundle) targetHidden=\(snapshot.targetIsHidden)")
            }
            logToggleLifecycle(
                for: shortcut,
                lifecycle: lifecycle,
                previousBundle: previousBundle,
                activationPath: activationPath,
                snapshot: snapshot,
                elapsedMilliseconds: elapsedMilliseconds
            )
            return
        }

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
        return "TOGGLE[\(shortcut.appName)]: \(phase.rawValue) \(state.logDetails) \(snapshot.structuredLogFields(stableOverride: effectiveStable))"
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
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { @Sendable _, error in
                completion(error)
            }
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
