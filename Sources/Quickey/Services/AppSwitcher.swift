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
    private var nextPendingGeneration = 0
    private(set) var pendingActivationState: PendingActivationState?
    private(set) var stableActivationState: StableActivationState?

    init(
        frontmostTracker: FrontmostApplicationTracker = FrontmostApplicationTracker(),
        applicationObservation: ApplicationObservation = .live,
        activationClient: ActivationClient = .live,
        fallbackActivationClient: FallbackActivationClient = .live,
        confirmationClient: ConfirmationClient = .live,
        sessionCoordinator: ToggleSessionCoordinator = ToggleSessionCoordinator()
    ) {
        self.frontmostTracker = frontmostTracker
        self.applicationObservation = applicationObservation
        self.activationClient = activationClient
        self.fallbackActivationClient = fallbackActivationClient
        self.confirmationClient = confirmationClient
        self.sessionCoordinator = sessionCoordinator
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
        guard sessionCoordinator.session(for: bundleIdentifier)?.phase == .activeStable else {
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
        return true
    }

    func schedulePendingConfirmation(
        state: PendingActivationState,
        shortcut: AppShortcut,
        activationPath: String,
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
        activationPath: String,
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
                phase: "POST_ACTIVATE_STATE",
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

        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: shortcut.bundleIdentifier).first else {
            // App not running — launch it
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: shortcut.bundleIdentifier) {
                frontmostTracker.noteCurrentFrontmostApp(excluding: shortcut.bundleIdentifier)
                logger.info("TOGGLE[\(shortcut.appName)]: NOT RUNNING → launching")
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: NOT RUNNING → launching, saved previous=\(frontmostTracker.lastNonTargetBundleIdentifier ?? "nil")")
                logToggleLifecycle(
                    for: shortcut,
                    lifecycle: "TOGGLE_ATTEMPT",
                    previousBundle: frontmostTracker.lastNonTargetBundleIdentifier,
                    activationPath: "launch",
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
            // App is stably frontmost — hide it and restore the previous app
            let previousApp = sessionCoordinator.previousBundle(for: shortcut.bundleIdentifier)
                ?? stableActivationState?.previousBundleIdentifier
                ?? frontmostTracker.lastNonTargetBundleIdentifier
            sessionCoordinator.beginDeactivation(for: shortcut.bundleIdentifier)
            logToggleLifecycle(
                for: shortcut,
                lifecycle: "TOGGLE_RESTORE_ATTEMPT",
                previousBundle: previousApp,
                activationPath: "restore_previous",
                snapshot: preActionSnapshot,
                elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
            )
            let restoreAttempt = frontmostTracker.restorePreviousAppIfPossible()
            let hidden = runningApp.hide()
            let restored = restoreAttempt.restoreAccepted
            logger.info("TOGGLE[\(shortcut.appName)]: IS ACTIVE → restored=\(restored), hidden=\(hidden)")
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: IS ACTIVE → restored=\(restored) (prev=\(restoreAttempt.bundleIdentifier ?? previousApp ?? "nil")), hidden=\(hidden)")
            let postRestoreWindowObservation = applicationObservation.windowObservation(for: runningApp)
            let postRestoreSnapshot = applicationObservation.snapshot(
                for: runningApp,
                windowObservation: postRestoreWindowObservation
            )
            if !postRestoreSnapshot.targetIsObservedFrontmost {
                frontmostTracker.confirmRestoreAttempt()
            }
            clearActivationTracking(for: shortcut.bundleIdentifier, resetPreviousTracking: false)
            logPostActionState(
                shortcut: shortcut,
                phase: "POST_RESTORE_STATE",
                snapshot: postRestoreSnapshot,
                previousBundle: restoreAttempt.bundleIdentifier ?? previousApp,
                activationPath: "restore_previous",
                elapsedMilliseconds: elapsedMilliseconds(since: attemptStartedAt)
            )
            return restored || hidden
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
        let previousApp = continuingPendingActivation
            ? pendingActivationState?.previousBundleIdentifier
            : frontmostTracker.lastNonTargetBundleIdentifier
        let pendingStartedAt = continuingPendingActivation
            ? pendingActivationState?.startedAt ?? attemptStartedAt
            : attemptStartedAt
        let activationPath = runningApp.isHidden ? "unhide_activate" : "activate"
        logger.info("TOGGLE[\(shortcut.appName)]: RUNNING NOT FRONT → activating, isHidden=\(runningApp.isHidden)")
        DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: RUNNING NOT FRONT → activating, saved previous=\(previousApp ?? "nil"), isHidden=\(runningApp.isHidden)")
        logToggleLifecycle(
            for: shortcut,
            lifecycle: "TOGGLE_ATTEMPT",
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
        phase: String,
        snapshot: ActivationObservationSnapshot,
        previousBundle: String?,
        activationPath: String,
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

        if phase == "POST_RESTORE_STATE" {
            let lifecycle = snapshot.targetIsObservedFrontmost ? "TOGGLE_RESTORE_DEGRADED" : "TOGGLE_RESTORE_CONFIRMED"
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
            lifecycle: "TOGGLE_CONFIRMATION",
            previousBundle: previousBundle,
            activationPath: activationPath,
            snapshot: snapshot,
            elapsedMilliseconds: elapsedMilliseconds,
            effectiveStable: effectiveStable
        )
        logToggleLifecycle(
            for: shortcut,
            lifecycle: (effectiveStable ?? snapshot.isStableActivation) ? "TOGGLE_STABLE" : "TOGGLE_DEGRADED",
            previousBundle: previousBundle,
            activationPath: activationPath,
            snapshot: snapshot,
            elapsedMilliseconds: elapsedMilliseconds,
            effectiveStable: effectiveStable
        )
    }

    func postActionLogMessage(
        for shortcut: AppShortcut,
        phase: String,
        snapshot: ActivationObservationSnapshot,
        effectiveStable: Bool? = nil
    ) -> String {
        let state = TogglePostActionState(snapshot: snapshot)
        return "TOGGLE[\(shortcut.appName)]: \(phase) \(state.logDetails) \(snapshot.structuredLogFields(stableOverride: effectiveStable))"
    }

    func toggleLifecycleLogMessage(
        for shortcut: AppShortcut,
        lifecycle: String,
        previousBundle: String?,
        activationPath: String,
        snapshot: ActivationObservationSnapshot? = nil,
        elapsedMilliseconds: Int,
        effectiveStable: Bool? = nil
    ) -> String {
        var fields = [
            "target=\(shortcut.bundleIdentifier)",
            "previous=\(previousBundle ?? "nil")",
            "activationPath=\(activationPath)",
            "elapsedMs=\(elapsedMilliseconds)"
        ]

        if let snapshot {
            fields.append(snapshot.structuredLogFields(stableOverride: effectiveStable))
        } else {
            fields.append(ActivationObservationSnapshot.quotedField("frontmost", frontmostTracker.currentFrontmostBundleIdentifier()))
        }

        return "TOGGLE[\(shortcut.appName)]: \(lifecycle) \(fields.joined(separator: " "))"
    }

    private func logToggleLifecycle(
        for shortcut: AppShortcut,
        lifecycle: String,
        previousBundle: String?,
        activationPath: String,
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
