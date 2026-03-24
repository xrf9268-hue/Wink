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

    struct Session: Equatable {
        let bundleIdentifier: String
        var phase: Phase
        var previousBundle: String?
        var activationStartedAt: CFAbsoluteTime
        var lastActivityAt: CFAbsoluteTime
        var confirmedAt: CFAbsoluteTime?
        var retryCount: Int
        var degradedReason: String?

        enum Phase: String, Equatable, Sendable {
            case idle
            case activating
            case activeStable
            case deactivating
            case degraded
        }
    }

    enum ReconfirmResult: Equatable {
        case accepted
        case retryCapped
        case absoluteCeilingReached
        case notDegraded
    }

    let configuration: Configuration
    private let now: @MainActor () -> CFAbsoluteTime
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

    // MARK: - Mutations

    @discardableResult
    func beginActivation(for bundleIdentifier: String, previousBundle: String?) -> Session {
        evictIfNeeded(excluding: bundleIdentifier)
        let currentTime = now()
        let session = Session(
            bundleIdentifier: bundleIdentifier,
            phase: .activating,
            previousBundle: previousBundle,
            activationStartedAt: currentTime,
            lastActivityAt: currentTime,
            confirmedAt: nil,
            retryCount: 0,
            degradedReason: nil
        )
        sessions[bundleIdentifier] = session
        return session
    }

    @discardableResult
    func markStable(for bundleIdentifier: String) -> Session? {
        guard var session = sessions[bundleIdentifier],
              session.phase == .activating || session.phase == .degraded else {
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
    func markDegraded(for bundleIdentifier: String, reason: String) -> Session? {
        guard var session = sessions[bundleIdentifier],
              session.phase == .activating || session.phase == .degraded else {
            return nil
        }
        session.phase = .degraded
        session.degradedReason = reason
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
    func beginDeactivation(for bundleIdentifier: String) -> Session? {
        guard var session = sessions[bundleIdentifier],
              session.phase == .activeStable else {
            return nil
        }
        let currentTime = now()
        session.phase = .deactivating
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
                && (session.phase == .activeStable || session.phase == .deactivating) {
                session.phase = .idle
                session.lastActivityAt = currentTime
                sessions[bundleId] = session
            }
        }
    }

    func handleTermination(bundleIdentifier: String) {
        sessions.removeValue(forKey: bundleIdentifier)
    }

    // MARK: - Live notification wiring

    private var activationObserver: Any?
    private var terminationObserver: Any?

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

    func stopObservingWorkspaceNotifications() {
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
        case .activating:
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

    // MARK: - Eviction

    private func evictIfNeeded(excluding currentBundleIdentifier: String) {
        guard sessions.count >= configuration.sessionCap else { return }

        // Prefer evicting stalest idle session
        if let stalestIdle = sessions
            .filter({ $0.key != currentBundleIdentifier && $0.value.phase == .idle })
            .min(by: { $0.value.lastActivityAt < $1.value.lastActivityAt }) {
            sessions.removeValue(forKey: stalestIdle.key)
            return
        }

        // Fall back to stalest expired non-idle session.
        // expireIfNeeded is called on a local copy purely as a predicate;
        // the session is removed immediately, so the write-back is unnecessary.
        if let stalestExpired = sessions
            .filter({ $0.key != currentBundleIdentifier })
            .filter({ var s = $0.value; return expireIfNeeded(&s) })
            .min(by: { $0.value.lastActivityAt < $1.value.lastActivityAt }) {
            sessions.removeValue(forKey: stalestExpired.key)
            return
        }

        // Safety net: if all non-current sessions are non-idle and non-expired,
        // evict the stalest to prevent exceeding the cap. This goes beyond
        // the two-tier spec rule but ensures the cap is never violated.
        if let stalest = sessions
            .filter({ $0.key != currentBundleIdentifier })
            .min(by: { $0.value.lastActivityAt < $1.value.lastActivityAt }) {
            sessions.removeValue(forKey: stalest.key)
        }
    }
}
