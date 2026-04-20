import AppKit
import CoreFoundation
import Testing
@testable import Wink

// MARK: - Required test directions

@Test @MainActor
func activeStableExpiresWhenAnotherAppBecomesFrontmost() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(now: { clock.time })

    coordinator.beginActivation(for: "com.apple.Safari", previousBundle: "com.apple.Terminal")
    clock.time = 101
    coordinator.markStable(for: "com.apple.Safari")

    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .activeStable)

    coordinator.handleFrontmostChange(newFrontmostBundle: "com.apple.Terminal")

    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .idle)
}

@Test @MainActor
func degradedSessionReturnsToIdleAfterRetryCap() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(
        configuration: .init(degradedRetryCap: 2),
        now: { clock.time }
    )

    coordinator.beginActivation(for: "com.apple.Home", previousBundle: "com.apple.Terminal")
    coordinator.markDegraded(for: "com.apple.Home", reason: "no visible windows")

    // First reconfirm — accepted
    clock.time = 101
    let result1 = coordinator.reconfirmDegraded(for: "com.apple.Home")
    #expect(result1 == .accepted)
    coordinator.markDegraded(for: "com.apple.Home", reason: "still no visible windows")

    // Second reconfirm — accepted
    clock.time = 102
    let result2 = coordinator.reconfirmDegraded(for: "com.apple.Home")
    #expect(result2 == .accepted)
    coordinator.markDegraded(for: "com.apple.Home", reason: "still no visible windows")

    // Third reconfirm — capped (retry cap is 2)
    clock.time = 103
    let result3 = coordinator.reconfirmDegraded(for: "com.apple.Home")
    #expect(result3 == .retryCapped)
    #expect(coordinator.session(for: "com.apple.Home")?.phase == .idle)
}

@Test @MainActor
func terminatedTargetClearsPendingSession() {
    let coordinator = ToggleSessionCoordinator(now: { 100 })

    coordinator.beginActivation(for: "com.apple.Safari", previousBundle: "com.apple.Terminal")
    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .activating)

    coordinator.handleTermination(bundleIdentifier: "com.apple.Safari")

    #expect(coordinator.session(for: "com.apple.Safari") == nil)
}

@Test @MainActor
func sessionStoreEvictsStalestIdleOrExpiredSessionAtConfiguredCap() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(
        configuration: .init(sessionCap: 3),
        now: { clock.time }
    )

    // Create 3 sessions that become idle
    coordinator.beginActivation(for: "com.app.A", previousBundle: nil)
    clock.time = 101
    coordinator.resetSession(for: "com.app.A")

    clock.time = 200
    coordinator.beginActivation(for: "com.app.B", previousBundle: nil)
    clock.time = 201
    coordinator.resetSession(for: "com.app.B")

    clock.time = 300
    coordinator.beginActivation(for: "com.app.C", previousBundle: nil)

    // Cap is 3, we have 3 sessions. Adding one more should evict stalest idle.
    clock.time = 400
    coordinator.beginActivation(for: "com.app.D", previousBundle: nil)

    // A was stalest idle → evicted
    #expect(coordinator.session(for: "com.app.A") == nil)
    // B, C, D remain
    #expect(coordinator.session(for: "com.app.B") != nil)
    #expect(coordinator.session(for: "com.app.C") != nil)
    #expect(coordinator.session(for: "com.app.D") != nil)
}

// MARK: - Degraded expiry and retry interaction

@Test @MainActor
func degradedReconfirmResetsIdleExpiryTimer() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(
        configuration: .init(degradedIdleExpiry: 2.0, absoluteActivationCeiling: 10.0),
        now: { clock.time }
    )

    coordinator.beginActivation(for: "com.apple.Home", previousBundle: "com.apple.Terminal")
    coordinator.markDegraded(for: "com.apple.Home", reason: "no windows")

    // Advance 1.5s (under 2s idle expiry)
    clock.time = 101.5
    let result = coordinator.reconfirmDegraded(for: "com.apple.Home")
    #expect(result == .accepted)
    coordinator.markDegraded(for: "com.apple.Home", reason: "still no windows")

    // Advance 1.5s more (3.0 total, but only 1.5s since reconfirm) — still valid
    clock.time = 103.0
    #expect(coordinator.session(for: "com.apple.Home")?.phase == .degraded)

    // Advance past idle expiry from last activity (101.5 + 2.0 = 103.5)
    clock.time = 104.0
    #expect(coordinator.session(for: "com.apple.Home")?.phase == .idle)
}

@Test @MainActor
func degradedReconfirmDoesNotResetAbsoluteActivationCeiling() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(
        configuration: .init(
            degradedIdleExpiry: 2.0,
            absoluteActivationCeiling: 5.0,
            degradedRetryCap: 10
        ),
        now: { clock.time }
    )

    coordinator.beginActivation(for: "com.apple.Home", previousBundle: "com.apple.Terminal")
    coordinator.markDegraded(for: "com.apple.Home", reason: "no windows")

    // Reconfirm at 1.5s
    clock.time = 101.5
    let result1 = coordinator.reconfirmDegraded(for: "com.apple.Home")
    #expect(result1 == .accepted)
    coordinator.markDegraded(for: "com.apple.Home", reason: "still no windows")

    // Reconfirm at 3.0s — still under ceiling
    clock.time = 103.0
    let result2 = coordinator.reconfirmDegraded(for: "com.apple.Home")
    #expect(result2 == .accepted)
    coordinator.markDegraded(for: "com.apple.Home", reason: "still no windows")

    // Reconfirm at 5.5s — past absolute ceiling (100 + 5.0 = 105.0)
    clock.time = 105.5
    let result3 = coordinator.reconfirmDegraded(for: "com.apple.Home")
    #expect(result3 == .absoluteCeilingReached)
    #expect(coordinator.session(for: "com.apple.Home")?.phase == .idle)
}

@Test @MainActor
func sameSessionRetriesCountAgainstSameRetryCap() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(
        configuration: .init(absoluteActivationCeiling: 20.0, degradedRetryCap: 2),
        now: { clock.time }
    )

    coordinator.beginActivation(for: "com.apple.Home", previousBundle: nil)
    coordinator.markDegraded(for: "com.apple.Home", reason: "no windows")

    // Reconfirm 1
    clock.time = 101
    _ = coordinator.reconfirmDegraded(for: "com.apple.Home")
    #expect(coordinator.session(for: "com.apple.Home")?.retryCount == 1)
    coordinator.markDegraded(for: "com.apple.Home", reason: "still no windows")

    // Reconfirm 2
    clock.time = 102
    _ = coordinator.reconfirmDegraded(for: "com.apple.Home")
    #expect(coordinator.session(for: "com.apple.Home")?.retryCount == 2)
    coordinator.markDegraded(for: "com.apple.Home", reason: "still no windows")

    // Reconfirm 3 — capped
    clock.time = 103
    let result = coordinator.reconfirmDegraded(for: "com.apple.Home")
    #expect(result == .retryCapped)
}

// MARK: - Additional coordinator behavior

@Test @MainActor
func beginActivationStoresPreviousBundleInSession() {
    let coordinator = ToggleSessionCoordinator(now: { 100 })

    coordinator.beginActivation(for: "com.apple.Safari", previousBundle: "com.apple.Terminal")

    #expect(coordinator.previousBundle(for: "com.apple.Safari") == "com.apple.Terminal")
}

@Test @MainActor
func activatingSessionExpiresAfterIdleTimeout() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(
        configuration: .init(activatingIdleExpiry: 2.0),
        now: { clock.time }
    )

    coordinator.beginActivation(for: "com.apple.Safari", previousBundle: nil)
    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .activating)

    clock.time = 102.5
    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .idle)
}

@Test @MainActor
func activatingSessionExpiresAfterAbsoluteCeiling() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(
        configuration: .init(activatingIdleExpiry: 10.0, absoluteActivationCeiling: 5.0),
        now: { clock.time }
    )

    coordinator.beginActivation(for: "com.apple.Safari", previousBundle: nil)

    // Simulate activity within idle expiry but past absolute ceiling
    clock.time = 103
    coordinator.touchSession(for: "com.apple.Safari")
    clock.time = 105.5
    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .idle)
}

@Test @MainActor
func handleFrontmostChangeDoesNotExpireCurrentFrontmostApp() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(now: { clock.time })

    coordinator.beginActivation(for: "com.apple.Safari", previousBundle: "com.apple.Terminal")
    clock.time = 101
    coordinator.markStable(for: "com.apple.Safari")

    // Safari is still frontmost
    coordinator.handleFrontmostChange(newFrontmostBundle: "com.apple.Safari")

    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .activeStable)
}

@Test @MainActor
func evictionPrefersIdleOverExpiredNonIdle() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(
        configuration: .init(activatingIdleExpiry: 2.0, sessionCap: 2),
        now: { clock.time }
    )

    // A: activating (will become expired non-idle)
    coordinator.beginActivation(for: "com.app.A", previousBundle: nil)

    // B: idle
    clock.time = 200
    coordinator.beginActivation(for: "com.app.B", previousBundle: nil)
    coordinator.resetSession(for: "com.app.B")

    // C: triggers eviction — B (idle) should be evicted before A (expired non-idle)
    clock.time = 300
    coordinator.beginActivation(for: "com.app.C", previousBundle: nil)

    #expect(coordinator.session(for: "com.app.B") == nil)
    #expect(coordinator.session(for: "com.app.A") != nil)
    #expect(coordinator.session(for: "com.app.C") != nil)
}

@Test @MainActor
func evictionDoesNotEvictCurrentlyMutatingSession() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(
        configuration: .init(sessionCap: 2),
        now: { clock.time }
    )

    coordinator.beginActivation(for: "com.app.A", previousBundle: nil)
    clock.time = 200
    coordinator.beginActivation(for: "com.app.B", previousBundle: nil)

    // Both sessions are activating (non-idle). Adding C should evict stalest non-idle,
    // but NOT the currently mutating session (C itself).
    clock.time = 300
    coordinator.beginActivation(for: "com.app.C", previousBundle: nil)

    // A is stalest, should be evicted
    #expect(coordinator.session(for: "com.app.A") == nil)
    #expect(coordinator.session(for: "com.app.B") != nil)
    #expect(coordinator.session(for: "com.app.C") != nil)
}

@Test @MainActor
func terminatedTargetClearsDegradedSession() {
    let coordinator = ToggleSessionCoordinator(now: { 100 })

    coordinator.beginActivation(for: "com.apple.Home", previousBundle: nil)
    coordinator.markDegraded(for: "com.apple.Home", reason: "no windows")

    coordinator.handleTermination(bundleIdentifier: "com.apple.Home")

    #expect(coordinator.session(for: "com.apple.Home") == nil)
}

@Test @MainActor
func deactivationResetsSessionToIdle() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(now: { clock.time })

    coordinator.beginActivation(for: "com.apple.Safari", previousBundle: "com.apple.Terminal")
    clock.time = 101
    coordinator.markStable(for: "com.apple.Safari")
    coordinator.beginDeactivation(for: "com.apple.Safari")

    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .deactivating)

    coordinator.completeDeactivation(for: "com.apple.Safari")

    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .idle)
}

@Test @MainActor
func activeStableIdleExpiryAppliesLazily() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(
        configuration: .init(activeStableIdleExpiry: 300),
        now: { clock.time }
    )

    coordinator.beginActivation(for: "com.apple.Safari", previousBundle: nil)
    clock.time = 101
    coordinator.markStable(for: "com.apple.Safari")

    clock.time = 200
    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .activeStable)

    clock.time = 402  // 301s since confirmedAt
    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .idle)
}

@Test @MainActor
func deactivatingSessionExpiresAfterIdleTimeout() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(
        configuration: .init(activatingIdleExpiry: 2.0),
        now: { clock.time }
    )

    coordinator.beginActivation(for: "com.apple.Safari", previousBundle: nil)
    clock.time = 101
    coordinator.markStable(for: "com.apple.Safari")
    coordinator.beginDeactivation(for: "com.apple.Safari")

    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .deactivating)

    clock.time = 104  // 3s since deactivation started, past 2s expiry
    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .idle)
}

@Test @MainActor
func handleFrontmostChangeKeepsDeactivatingSessionAliveUntilHideConfirmation() {
    let clock = CoordinatorTestClock(time: 100)
    let coordinator = ToggleSessionCoordinator(now: { clock.time })

    coordinator.beginActivation(for: "com.apple.Safari", previousBundle: nil)
    clock.time = 101
    coordinator.markStable(for: "com.apple.Safari")
    coordinator.beginDeactivation(for: "com.apple.Safari")

    coordinator.handleFrontmostChange(newFrontmostBundle: "com.apple.Terminal")

    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .deactivating)
}

@Test @MainActor
func deinitRemovesWorkspaceObservers() {
    weak var weakCoordinator: ToggleSessionCoordinator?
    do {
        let coordinator = ToggleSessionCoordinator()
        coordinator.startObservingWorkspaceNotifications()
        weakCoordinator = coordinator
    }
    // Strong ref was dropped at end of scope; nonisolated deinit runs
    // synchronously on the releasing thread and tears down the observer tokens.
    #expect(weakCoordinator == nil, "coordinator should deallocate after scope exit")

    // Posting notifications that the coordinator used to observe must be safe
    // after release. If the observer wasn't removed on deinit, the block would
    // be retained forever and could fire on a dangling context.
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.didActivateApplicationNotification,
        object: nil
    )
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.didTerminateApplicationNotification,
        object: nil
    )
}

@Test @MainActor
func stopObservingWorkspaceNotificationsIsIdempotent() {
    let coordinator = ToggleSessionCoordinator()
    coordinator.startObservingWorkspaceNotifications()
    coordinator.stopObservingWorkspaceNotifications()
    // Calling again must be a safe no-op, not a double-remove crash.
    coordinator.stopObservingWorkspaceNotifications()
}

private final class CoordinatorTestClock: @unchecked Sendable {
    var time: CFAbsoluteTime

    init(time: CFAbsoluteTime) {
        self.time = time
    }
}
