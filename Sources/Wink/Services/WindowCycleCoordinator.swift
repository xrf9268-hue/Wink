import AppKit

// Intentional @MainActor: consumes NSWorkspace notifications and is queried
// from the (main-actor) toggle decision path; not part of the event-tap
// callback hot path.
@MainActor
final class WindowCycleCoordinator {

    struct Configuration: Equatable, Sendable {
        /// A cycle session older than this is discarded and the cursor is
        /// re-derived from the target's focused window. Long enough to
        /// survive deliberate repeat presses, short enough that a returning
        /// user starts from what they actually see focused.
        var sessionIdleExpiry: TimeInterval = 3.0
    }

    struct CycleSession: Equatable {
        let bundleIdentifier: String
        var pid: pid_t
        /// The window we last asked the WindowServer to focus. Kept as the
        /// cursor instead of the observed focused window because AX focus
        /// reporting lags rapid presses; identity is the CGWindowID, never
        /// an index into `kAXWindows` (its order changes after a raise).
        var lastTargetWindowID: CGWindowID
        var lastAdvanceAt: CFAbsoluteTime
        /// 1-based position of `lastTargetWindowID` in the ordered window
        /// list at the time of the advance, for diagnostics/HUD ("2/5").
        var stepIndex: Int
        var windowCount: Int
    }

    let configuration: Configuration
    private let now: @MainActor () -> CFAbsoluteTime
    private(set) var session: CycleSession?

    init(
        configuration: Configuration = .init(),
        now: @escaping @MainActor () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() }
    ) {
        self.configuration = configuration
        self.now = now
    }

    /// Advance the cycle for `bundleIdentifier` across `orderedWindowIDs`
    /// (caller-provided stable order) and record the new cursor.
    ///
    /// Cursor resolution: a live session's `lastTargetWindowID` wins (rapid
    /// presses outpace AX focus reporting); otherwise the caller-observed
    /// `focusedWindowID` seeds the cursor; otherwise the rotation starts at
    /// the first window. Returns `nil` when fewer than two windows are
    /// cyclable so the caller can fall back to toggle semantics.
    func advance(
        bundleIdentifier: String,
        pid: pid_t,
        orderedWindowIDs: [CGWindowID],
        focusedWindowID: CGWindowID?
    ) -> CGWindowID? {
        guard orderedWindowIDs.count >= 2 else {
            session = nil
            return nil
        }

        let currentTime = now()
        var cursor: CGWindowID?
        if let session,
           session.bundleIdentifier == bundleIdentifier,
           session.pid == pid,
           currentTime - session.lastAdvanceAt <= configuration.sessionIdleExpiry,
           orderedWindowIDs.contains(session.lastTargetWindowID) {
            cursor = session.lastTargetWindowID
        } else if let focusedWindowID, orderedWindowIDs.contains(focusedWindowID) {
            cursor = focusedWindowID
        }

        let nextIndex: Int
        if let cursor, let cursorIndex = orderedWindowIDs.firstIndex(of: cursor) {
            nextIndex = (cursorIndex + 1) % orderedWindowIDs.count
        } else {
            nextIndex = 0
        }

        let target = orderedWindowIDs[nextIndex]
        session = CycleSession(
            bundleIdentifier: bundleIdentifier,
            pid: pid,
            lastTargetWindowID: target,
            lastAdvanceAt: currentTime,
            stepIndex: nextIndex + 1,
            windowCount: orderedWindowIDs.count
        )
        return target
    }

    func invalidate(reason: String) {
        guard session != nil else { return }
        DiagnosticLog.log("CYCLE: session invalidated reason=\(reason)")
        session = nil
    }

    // MARK: - Live notification wiring

    // nonisolated(unsafe): tokens are written only while @MainActor-isolated
    // (from start/stop) but also read from the nonisolated deinit below, where
    // NotificationCenter.removeObserver is thread-safe.
    private nonisolated(unsafe) var activationObserver: Any?
    private nonisolated(unsafe) var terminationObserver: Any?

    deinit {
        stopObservingWorkspaceNotifications()
    }

    func startObservingWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundle = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor [weak self] in
                self?.handleFrontmostChange(newFrontmostBundle: bundle)
            }
        }
        terminationObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundle = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            if let bundle {
                Task { @MainActor [weak self] in
                    self?.handleTermination(bundleIdentifier: bundle)
                }
            }
        }
    }

    nonisolated func stopObservingWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        if let activationObserver {
            center.removeObserver(activationObserver)
        }
        if let terminationObserver {
            center.removeObserver(terminationObserver)
        }
        activationObserver = nil
        terminationObserver = nil
    }

    func handleFrontmostChange(newFrontmostBundle: String?) {
        guard let session, session.bundleIdentifier != newFrontmostBundle else { return }
        invalidate(reason: "frontmost_changed")
    }

    func handleTermination(bundleIdentifier: String) {
        guard session?.bundleIdentifier == bundleIdentifier else { return }
        invalidate(reason: "target_terminated")
    }
}
