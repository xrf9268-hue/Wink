import AppKit

// Intentional @MainActor: coordinates AppKit/AX/NSWorkspace lifecycle ordering
// and is not part of the event-tap callback hot path.
@MainActor
final class ToggleSessionCoordinator {

    struct Configuration: Equatable, Sendable {
        var activatingIdleExpiry: TimeInterval = 2.0
        var degradedIdleExpiry: TimeInterval = 2.0
        var absoluteActivationCeiling: TimeInterval = 5.0
        var activeStableIdleExpiry: TimeInterval = 300.0
        var degradedRetryCap: Int = 2
        var sessionCap: Int = 50
    }

    struct ToggleSession: Equatable {
        let bundleIdentifier: String
        let attemptID: UUID
        var generation: Int
        var pid: pid_t?
        var appName: String?
        var phase: Phase
        var activationPath: AppSwitcher.ActivationPath
        var previousBundle: String?
        var activationStartedAt: CFAbsoluteTime
        var phaseStartedAt: CFAbsoluteTime
        var lastActivityAt: CFAbsoluteTime
        var confirmedAt: CFAbsoluteTime?
        var retryCount: Int
        var degradedReason: String?

        enum Phase: String, Equatable, Sendable {
            case idle
            case launching
            case activating
            case activeStable
            case deactivating
            case degraded
        }
    }

    typealias Session = ToggleSession

    enum ReconfirmResult: Equatable {
        case accepted
        case retryCapped
        case absoluteCeilingReached
        case notDegraded
    }

    let configuration: Configuration
    private let now: @MainActor () -> CFAbsoluteTime
    private var nextGeneration = 0
    private(set) var sessions: [String: Session] = [:]

    init(
        configuration: Configuration = .init(),
        now: @escaping @MainActor () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() }
    ) {
        self.configuration = configuration
        self.now = now
    }

    // MARK: - Query

    func session(for bundleIdentifier: String) -> Session? {
        guard var session = sessions[bundleIdentifier] else { return nil }
        if expireIfNeeded(&session) {
            sessions[bundleIdentifier] = session
        }
        return session
    }

    func previousBundle(for bundleIdentifier: String) -> String? {
        session(for: bundleIdentifier)?.previousBundle
    }

    func durablePreviousBundle(for bundleIdentifier: String) -> String? {
        session(for: bundleIdentifier)?.previousBundle
    }

    func pendingActivationSession(for bundleIdentifier: String? = nil) -> Session? {
        session(for: bundleIdentifier, matching: [.launching, .activating, .degraded])
    }

    func pendingDeactivationSession(for bundleIdentifier: String? = nil) -> Session? {
        session(for: bundleIdentifier, matching: [.deactivating])
    }

    func stableSession(for bundleIdentifier: String? = nil) -> Session? {
        session(for: bundleIdentifier, matching: [.activeStable, .deactivating])
    }

    func trackedActivationBundle(excluding bundleIdentifier: String) -> String? {
        guard let session = mostRecentSession(matching: [.launching, .activating, .activeStable, .deactivating, .degraded]),
              session.bundleIdentifier != bundleIdentifier else {
            return nil
        }
        return session.bundleIdentifier
    }

    // MARK: - Mutations

    @discardableResult
    func beginLaunch(
        for bundleIdentifier: String,
        appName: String? = nil,
        previousBundle: String?,
        startedAt: CFAbsoluteTime? = nil
    ) -> Session {
        makeSession(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            phase: .launching,
            activationPath: .launch,
            previousBundle: previousBundle,
            pid: nil,
            startedAt: startedAt
        )
    }

    @discardableResult
    func beginActivation(
        for bundleIdentifier: String,
        previousBundle: String?,
        appName: String? = nil,
        activationPath: AppSwitcher.ActivationPath = .activate,
        pid: pid_t? = nil,
        startedAt: CFAbsoluteTime? = nil
    ) -> Session {
        makeSession(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            phase: .activating,
            activationPath: activationPath,
            previousBundle: previousBundle,
            pid: pid,
            startedAt: startedAt
        )
    }

    @discardableResult
    func updateProcessIdentifier(for bundleIdentifier: String, pid: pid_t?) -> Session? {
        guard var session = sessions[bundleIdentifier] else { return nil }
        if let existingPID = session.pid,
           let pid,
           existingPID != pid {
            let rolloverMessage = ToggleDiagnosticEvent(
                family: .reset,
                attemptID: session.attemptID,
                bundleIdentifier: bundleIdentifier,
                pid: existingPID,
                phase: session.phase,
                event: "session_cleared",
                activationPath: session.activationPath,
                reason: "pid_rollover",
                previousBundleIdentifier: session.previousBundle
            ).logMessage
            DiagnosticLog.log(rolloverMessage)

            let replacement = makeSession(
                bundleIdentifier: bundleIdentifier,
                appName: session.appName,
                phase: .activating,
                activationPath: session.activationPath,
                previousBundle: session.previousBundle,
                pid: pid,
                startedAt: now()
            )
            return replacement
        }
        session.pid = pid
        session.lastActivityAt = now()
        sessions[bundleIdentifier] = session
        return session
    }

    @discardableResult
    func continueActivation(
        for bundleIdentifier: String,
        activationPath: AppSwitcher.ActivationPath,
        pid: pid_t? = nil
    ) -> Session? {
        guard var session = sessions[bundleIdentifier],
              session.phase == .launching || session.phase == .activating || session.phase == .degraded else {
            return nil
        }
        session.phase = .activating
        session.activationPath = activationPath
        if let pid {
            session.pid = pid
        }
        session.lastActivityAt = now()
        sessions[bundleIdentifier] = session
        return session
    }

    @discardableResult
    func markStable(for bundleIdentifier: String, generation: Int? = nil) -> Session? {
        guard var session = sessions[bundleIdentifier],
              session.phase == .launching || session.phase == .activating || session.phase == .degraded,
              generation.map({ $0 == session.generation }) ?? true else {
            return nil
        }
        let currentTime = now()
        session.phase = .activeStable
        session.confirmedAt = currentTime
        session.lastActivityAt = currentTime
        sessions[bundleIdentifier] = session
        return session
    }

    @discardableResult
    func markDegraded(for bundleIdentifier: String, reason: String, generation: Int? = nil) -> Session? {
        guard var session = sessions[bundleIdentifier],
              session.phase == .launching || session.phase == .activating || session.phase == .degraded,
              generation.map({ $0 == session.generation }) ?? true else {
            return nil
        }
        session.phase = .degraded
        session.degradedReason = reason
        session.lastActivityAt = now()
        sessions[bundleIdentifier] = session
        return session
    }

    func reconfirmDegraded(for bundleIdentifier: String) -> ReconfirmResult {
        guard var session = sessions[bundleIdentifier],
              session.phase == .degraded else {
            return .notDegraded
        }

        let currentTime = now()

        if currentTime - session.activationStartedAt > configuration.absoluteActivationCeiling {
            session.phase = .idle
            session.lastActivityAt = currentTime
            sessions[bundleIdentifier] = session
            return .absoluteCeilingReached
        }

        if session.retryCount >= configuration.degradedRetryCap {
            session.phase = .idle
            session.lastActivityAt = currentTime
            sessions[bundleIdentifier] = session
            return .retryCapped
        }

        session.retryCount += 1
        session.phase = .activating
        session.lastActivityAt = currentTime
        sessions[bundleIdentifier] = session
        return .accepted
    }

    @discardableResult
    func beginDeactivation(
        for bundleIdentifier: String,
        appName: String? = nil,
        previousBundle: String? = nil,
        activationPath: AppSwitcher.ActivationPath = .hide,
        pid: pid_t? = nil,
        startedAt: CFAbsoluteTime? = nil
    ) -> Session? {
        if activationPath == .hideUntracked {
            return makeSession(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                phase: .deactivating,
                activationPath: activationPath,
                previousBundle: previousBundle,
                pid: pid,
                startedAt: startedAt
            )
        }

        guard var session = sessions[bundleIdentifier],
              session.phase == .activeStable else {
            return nil
        }
        let currentTime = now()
        if let appName {
            session.appName = appName
        }
        if let previousBundle {
            session.previousBundle = previousBundle
        }
        if let pid {
            session.pid = pid
        }
        session.activationPath = activationPath
        session.phase = .deactivating
        session.phaseStartedAt = startedAt ?? currentTime
        session.lastActivityAt = currentTime
        sessions[bundleIdentifier] = session
        return session
    }

    @discardableResult
    func cancelDeactivation(for bundleIdentifier: String) -> Session? {
        guard var session = sessions[bundleIdentifier],
              session.phase == .deactivating else {
            return nil
        }
        let currentTime = now()
        session.phase = .activeStable
        session.lastActivityAt = currentTime
        sessions[bundleIdentifier] = session
        return session
    }

    func completeDeactivation(for bundleIdentifier: String) {
        guard var session = sessions[bundleIdentifier],
              session.phase == .deactivating else {
            return
        }
        session.phase = .idle
        session.lastActivityAt = now()
        sessions[bundleIdentifier] = session
    }

    func resetSession(for bundleIdentifier: String) {
        guard var session = sessions[bundleIdentifier] else { return }
        session.phase = .idle
        session.lastActivityAt = now()
        sessions[bundleIdentifier] = session
    }

    /// Update lastActivityAt to keep the session alive during ongoing work.
    func touchSession(for bundleIdentifier: String) {
        guard var session = sessions[bundleIdentifier] else { return }
        session.lastActivityAt = now()
        sessions[bundleIdentifier] = session
    }

    // MARK: - Notification handlers

    func handleFrontmostChange(newFrontmostBundle: String?) {
        let currentTime = now()
        for (bundleId, var session) in sessions {
            if bundleId != newFrontmostBundle
                && session.phase == .activeStable {
                session.phase = .idle
                session.lastActivityAt = currentTime
                sessions[bundleId] = session
            }
        }
    }

    func handleTermination(bundleIdentifier: String, pid: pid_t? = nil) {
        guard let session = sessions[bundleIdentifier] else { return }
        guard pid == nil || session.pid == nil || session.pid == pid else { return }
        DiagnosticLog.log(
            ToggleDiagnosticEvent(
                family: .reset,
                attemptID: session.attemptID,
                bundleIdentifier: bundleIdentifier,
                pid: session.pid,
                phase: session.phase,
                event: "session_cleared",
                activationPath: session.activationPath,
                reason: "termination",
                previousBundleIdentifier: session.previousBundle
            ).logMessage
        )
        sessions.removeValue(forKey: bundleIdentifier)
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
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = app?.bundleIdentifier
            let pid = app?.processIdentifier
            if let bundle {
                Task { @MainActor [weak self] in
                    self?.handleTermination(bundleIdentifier: bundle, pid: pid)
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

    // MARK: - Expiry

    private func expireIfNeeded(_ session: inout Session) -> Bool {
        let currentTime = now()
        switch session.phase {
        case .idle:
            return false
        case .deactivating:
            if currentTime - session.lastActivityAt > configuration.activatingIdleExpiry {
                session.phase = .idle
                session.lastActivityAt = currentTime
                return true
            }
            return false
        case .launching, .activating:
            if currentTime - session.lastActivityAt > configuration.activatingIdleExpiry
                || currentTime - session.activationStartedAt > configuration.absoluteActivationCeiling {
                session.phase = .idle
                session.lastActivityAt = currentTime
                return true
            }
            return false
        case .activeStable:
            if currentTime - session.lastActivityAt > configuration.activeStableIdleExpiry {
                session.phase = .idle
                session.lastActivityAt = currentTime
                return true
            }
            return false
        case .degraded:
            if currentTime - session.lastActivityAt > configuration.degradedIdleExpiry
                || currentTime - session.activationStartedAt > configuration.absoluteActivationCeiling {
                session.phase = .idle
                session.lastActivityAt = currentTime
                return true
            }
            return false
        }
    }

    private func session(for bundleIdentifier: String?, matching phases: Set<Session.Phase>) -> Session? {
        if let bundleIdentifier {
            guard let session = session(for: bundleIdentifier), phases.contains(session.phase) else {
                return nil
            }
            return session
        }

        return mostRecentSession(matching: phases)
    }

    private func mostRecentSession(matching phases: Set<Session.Phase>) -> Session? {
        var candidates: [Session] = []
        for bundleIdentifier in sessions.keys {
            guard let session = session(for: bundleIdentifier), phases.contains(session.phase) else {
                continue
            }
            candidates.append(session)
        }
        return candidates.max { lhs, rhs in
            if lhs.lastActivityAt == rhs.lastActivityAt {
                return lhs.generation < rhs.generation
            }
            return lhs.lastActivityAt < rhs.lastActivityAt
        }
    }

    // MARK: - Eviction

    private func evictIfNeeded(excluding currentBundleIdentifier: String) {
        guard sessions.count >= configuration.sessionCap else { return }

        // Single-pass eviction: simultaneously track the stalest candidate in
        // three priority tiers (idle > expired > any). Pick from the highest
        // tier that has a candidate. Avoids three separate filter+min scans.
        //
        // expireIfNeeded operates on a local copy purely as a predicate; the
        // session is removed immediately, so the write-back is unnecessary.
        var stalestIdleKey: String?
        var stalestIdleAt: CFAbsoluteTime = .infinity
        var stalestExpiredKey: String?
        var stalestExpiredAt: CFAbsoluteTime = .infinity
        var stalestAnyKey: String?
        var stalestAnyAt: CFAbsoluteTime = .infinity

        for (key, session) in sessions where key != currentBundleIdentifier {
            let activity = session.lastActivityAt
            if activity < stalestAnyAt {
                stalestAnyAt = activity
                stalestAnyKey = key
            }
            if session.phase == .idle, activity < stalestIdleAt {
                stalestIdleAt = activity
                stalestIdleKey = key
            } else {
                var probe = session
                if expireIfNeeded(&probe), activity < stalestExpiredAt {
                    stalestExpiredAt = activity
                    stalestExpiredKey = key
                }
            }
        }

        if let key = stalestIdleKey ?? stalestExpiredKey ?? stalestAnyKey {
            sessions.removeValue(forKey: key)
        }
    }

    @discardableResult
    private func makeSession(
        bundleIdentifier: String,
        appName: String?,
        phase: Session.Phase,
        activationPath: AppSwitcher.ActivationPath,
        previousBundle: String?,
        pid: pid_t?,
        startedAt: CFAbsoluteTime?
    ) -> Session {
        evictIfNeeded(excluding: bundleIdentifier)
        nextGeneration += 1
        let currentTime = now()
        let startedAt = startedAt ?? currentTime
        let session = Session(
            bundleIdentifier: bundleIdentifier,
            attemptID: UUID(),
            generation: nextGeneration,
            pid: pid,
            appName: appName,
            phase: phase,
            activationPath: activationPath,
            previousBundle: previousBundle,
            activationStartedAt: startedAt,
            phaseStartedAt: startedAt,
            lastActivityAt: currentTime,
            confirmedAt: nil,
            retryCount: 0,
            degradedReason: nil
        )
        sessions[bundleIdentifier] = session
        return session
    }
}
