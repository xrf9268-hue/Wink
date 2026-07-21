import AppKit
import CoreGraphics
import Testing
@testable import Wink

@MainActor
private final class CycleClock {
    var time: CFAbsoluteTime

    init(time: CFAbsoluteTime) {
        self.time = time
    }
}

@Test @MainActor
func advanceRequiresAtLeastTwoWindows() {
    let coordinator = WindowCycleCoordinator(now: { 100 })

    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [],
        focusedWindowID: nil
    ) == nil)
    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101],
        focusedWindowID: 101
    ) == nil)
    #expect(coordinator.session == nil)
}

@Test @MainActor
func advanceStartsAfterFocusedWindowAndWraps() {
    let coordinator = WindowCycleCoordinator(now: { 100 })

    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102, 103],
        focusedWindowID: 102
    ) == 103)

    let fresh = WindowCycleCoordinator(now: { 100 })
    #expect(fresh.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102, 103],
        focusedWindowID: 103
    ) == 101)
}

@Test @MainActor
func advanceStartsAtFirstWindowWithoutAnyCursor() {
    let coordinator = WindowCycleCoordinator(now: { 100 })

    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102],
        focusedWindowID: nil
    ) == 101)
}

@Test @MainActor
func advancePrefersLiveSessionCursorOverStaleFocusReport() {
    let clock = CycleClock(time: 100)
    let coordinator = WindowCycleCoordinator(now: { clock.time })

    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102, 103],
        focusedWindowID: 101
    ) == 102)

    // Rapid second press: AX focus still reports 101, but the session
    // cursor (102) must win so the rotation keeps moving forward.
    clock.time = 100.2
    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102, 103],
        focusedWindowID: 101
    ) == 103)
}

@Test @MainActor
func sessionExpiresAfterIdleWindow() {
    let clock = CycleClock(time: 100)
    let coordinator = WindowCycleCoordinator(now: { clock.time })

    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102, 103],
        focusedWindowID: 101
    ) == 102)

    // Past the idle expiry the stale cursor is discarded and the focused
    // window re-seeds the rotation.
    clock.time = 104
    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102, 103],
        focusedWindowID: 101
    ) == 102)
}

@Test @MainActor
func staleCursorMissingFromWindowListFallsBackToFocus() {
    let clock = CycleClock(time: 100)
    let coordinator = WindowCycleCoordinator(now: { clock.time })

    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102, 103],
        focusedWindowID: 101
    ) == 102)

    // Window 102 closed before the next press and focus reverted to 101:
    // the gone cursor must fall back to the focus seed (yielding 103), not
    // to the first window (which would also yield 101 and mask a lost
    // focus-fallback).
    clock.time = 100.2
    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 103],
        focusedWindowID: 101
    ) == 103)
}

@Test @MainActor
func manualWindowSwitchMidGestureReseedsRotation() {
    let clock = CycleClock(time: 100)
    let coordinator = WindowCycleCoordinator(now: { clock.time })

    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102, 103],
        focusedWindowID: 101
    ) == 102)

    // The user clicked window 103 manually — a window this gesture never
    // visited. The rotation must re-seed from it (103 → 101) instead of
    // advancing from the stale cursor (102 → 103), which would visibly
    // no-op on the already-focused window.
    clock.time = 100.5
    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102, 103],
        focusedWindowID: 103
    ) == 101)
}

@Test @MainActor
func pidChangeDiscardsSessionCursor() {
    let clock = CycleClock(time: 100)
    let coordinator = WindowCycleCoordinator(now: { clock.time })

    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102],
        focusedWindowID: nil
    ) == 101)

    // Same bundle relaunched under a new pid: the old cursor must not
    // steer the rotation.
    clock.time = 100.2
    #expect(coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 6,
        orderedWindowIDs: [101, 102],
        focusedWindowID: nil
    ) == 101)
}

@Test @MainActor
func bundleChangeDiscardsSessionCursor() {
    let clock = CycleClock(time: 100)
    let coordinator = WindowCycleCoordinator(now: { clock.time })

    #expect(coordinator.advance(
        bundleIdentifier: "com.test.A",
        pid: 5,
        orderedWindowIDs: [101, 102],
        focusedWindowID: nil
    ) == 101)

    // Same pid and an id list that still contains A's cursor (101): only
    // the bundle-identity guard separates "fresh rotation from first
    // window" (101) from "advance the stale cursor" (202).
    clock.time = 100.2
    #expect(coordinator.advance(
        bundleIdentifier: "com.test.B",
        pid: 5,
        orderedWindowIDs: [101, 202],
        focusedWindowID: nil
    ) == 101)
}

@Test @MainActor
func workspaceNotificationWiringDrivesInvalidation() {
    let coordinator = WindowCycleCoordinator(now: { 100 })
    coordinator.startObservingWorkspaceNotifications()
    defer { coordinator.stopObservingWorkspaceNotifications() }

    _ = coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102],
        focusedWindowID: nil
    )
    #expect(coordinator.session != nil)

    // didActivate without userInfo means "frontmost changed to unknown":
    // delivered synchronously (queue .main + MainActor.assumeIsolated), it
    // must invalidate the session before this line returns.
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.didActivateApplicationNotification,
        object: nil
    )
    #expect(coordinator.session == nil)

    _ = coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102],
        focusedWindowID: nil
    )

    // Termination without a bundle identifier is ignored.
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.didTerminateApplicationNotification,
        object: nil
    )
    #expect(coordinator.session != nil)

    // After stop, notifications no longer reach the coordinator.
    coordinator.stopObservingWorkspaceNotifications()
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.didActivateApplicationNotification,
        object: nil
    )
    #expect(coordinator.session != nil)
}

@Test @MainActor
func repeatStartObservingDoesNotDoubleHandleNotifications() {
    let coordinator = WindowCycleCoordinator(now: { 100 })
    coordinator.startObservingWorkspaceNotifications()
    coordinator.startObservingWorkspaceNotifications()
    defer { coordinator.stopObservingWorkspaceNotifications() }

    _ = coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102],
        focusedWindowID: nil
    )

    // A single stop after a double start must fully disconnect: if the
    // first start's tokens leaked, this notification would still
    // invalidate the session through the orphaned observer.
    coordinator.stopObservingWorkspaceNotifications()
    NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.didActivateApplicationNotification,
        object: nil
    )
    #expect(coordinator.session != nil)
}

@Test @MainActor
func liveSessionAppliesIdleExpiryAndBundleIdentity() {
    let clock = CycleClock(time: 100)
    let coordinator = WindowCycleCoordinator(now: { clock.time })

    _ = coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102],
        focusedWindowID: nil
    )

    clock.time = 102
    #expect(coordinator.liveSession(for: "com.test.App") != nil)
    #expect(coordinator.liveSession(for: "com.other.App") == nil)

    // Past the idle expiry the raw session record may still exist (lazy
    // discard), but liveSession must report no gesture in flight.
    clock.time = 104
    #expect(coordinator.session != nil)
    #expect(coordinator.liveSession(for: "com.test.App") == nil)
}

@Test @MainActor
func frontmostChangeToOtherAppInvalidatesSession() {
    let coordinator = WindowCycleCoordinator(now: { 100 })
    _ = coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102],
        focusedWindowID: nil
    )
    #expect(coordinator.session != nil)

    coordinator.handleFrontmostChange(newFrontmostBundle: "com.test.App")
    #expect(coordinator.session != nil)

    coordinator.handleFrontmostChange(newFrontmostBundle: "com.other.App")
    #expect(coordinator.session == nil)
}

@Test @MainActor
func terminationOfTargetInvalidatesSession() {
    let coordinator = WindowCycleCoordinator(now: { 100 })
    _ = coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102],
        focusedWindowID: nil
    )

    coordinator.handleTermination(bundleIdentifier: "com.other.App")
    #expect(coordinator.session != nil)

    coordinator.handleTermination(bundleIdentifier: "com.test.App")
    #expect(coordinator.session == nil)
}

@Test @MainActor
func sessionRecordsStepIndexAndWindowCount() {
    let clock = CycleClock(time: 100)
    let coordinator = WindowCycleCoordinator(now: { clock.time })

    _ = coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102, 103],
        focusedWindowID: 101
    )
    #expect(coordinator.session?.lastTargetWindowID == 102)
    #expect(coordinator.session?.stepIndex == 2)
    #expect(coordinator.session?.windowCount == 3)

    clock.time = 100.2
    _ = coordinator.advance(
        bundleIdentifier: "com.test.App",
        pid: 5,
        orderedWindowIDs: [101, 102, 103],
        focusedWindowID: 102
    )
    #expect(coordinator.session?.lastTargetWindowID == 103)
    #expect(coordinator.session?.stepIndex == 3)
}
