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
        /// Seed plus every target this gesture has focused. A focused-window
        /// report NOT in this set can only come from a manual intra-app
        /// switch (click, ⌘\`), so it re-seeds the cursor; a lagging AX
        /// report is always a previously visited window. Once a lap
        /// completes the set saturates and manual switches within the same
        /// session read as lag — an accepted residual, bounded by the idle
        /// expiry.
        var visitedWindowIDs: Set<CGWindowID>
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
        var visited: Set<CGWindowID> = []
        if let session,
           session.bundleIdentifier == bundleIdentifier,
           session.pid == pid,
           currentTime - session.lastAdvanceAt <= configuration.sessionIdleExpiry,
           orderedWindowIDs.contains(session.lastTargetWindowID) {
            if let focusedWindowID,
               orderedWindowIDs.contains(focusedWindowID),
               !session.visitedWindowIDs.contains(focusedWindowID) {
                // Manual intra-app switch mid-gesture: the user focused a
                // window this gesture never targeted. Re-seed from it so
                // the next press advances from what they actually see.
                cursor = focusedWindowID
                visited = [focusedWindowID]
            } else {
                cursor = session.lastTargetWindowID
                visited = session.visitedWindowIDs
            }
        } else if let focusedWindowID, orderedWindowIDs.contains(focusedWindowID) {
            cursor = focusedWindowID
            visited = [focusedWindowID]
        }

        let nextIndex: Int
        if let cursor, let cursorIndex = orderedWindowIDs.firstIndex(of: cursor) {
            nextIndex = (cursorIndex + 1) % orderedWindowIDs.count
        } else {
            DiagnosticLog.log(
                "CYCLE: degraded seed focused=\(focusedWindowID.map(String.init) ?? "nil") count=\(orderedWindowIDs.count); starting at first wid"
            )
            nextIndex = 0
        }

        let target = orderedWindowIDs[nextIndex]
        session = CycleSession(
            bundleIdentifier: bundleIdentifier,
            pid: pid,
            lastTargetWindowID: target,
            lastAdvanceAt: currentTime,
            visitedWindowIDs: visited.union([target]),
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

    // nonisolated(unsafe): written from MainActor start and from the
    // nonisolated stop (called from deinits, where exclusivity comes from
    // unique ownership); NotificationCenter.removeObserver itself is
    // thread-safe. Safe only while the coordinator is uniquely owned by a
    // single MainActor owner.
    private nonisolated(unsafe) var activationObserver: Any?
    private nonisolated(unsafe) var terminationObserver: Any?

    deinit {
        stopObservingWorkspaceNotifications()
    }

    func startObservingWorkspaceNotifications() {
        // Idempotent: drop prior tokens so a repeat start cannot leak
        // observers that would double-handle every notification.
        stopObservingWorkspaceNotifications()
        let center = NSWorkspace.shared.notificationCenter
        // MainActor.assumeIsolated (not a Task hop): the observers use
        // queue .main, so delivery is already on the main actor, and the
        // inline call keeps invalidation ordered ahead of any key event
        // processed later on the same run loop.
        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundle = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { [weak self] in
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
                MainActor.assumeIsolated { [weak self] in
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
