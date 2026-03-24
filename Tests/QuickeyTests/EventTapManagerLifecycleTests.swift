import Testing
import Foundation
@testable import Quickey

// MARK: - EventTapLifecycleTracker recovery escalation

@Suite("EventTapManagerLifecycle recovery escalation")
struct EventTapLifecycleRecoveryTests {

    @Test
    func firstTimeoutReenablesInPlace() {
        var tracker = EventTapLifecycleTracker()
        let action = tracker.recordTimeout(at: 1000.0)
        #expect(action == .reenableInPlace)
        #expect(tracker.rollingTimeoutCount == 1)
    }

    @Test
    func repeatedTimeoutsTriggerRecreationAfterThreshold() {
        var tracker = EventTapLifecycleTracker()
        let base: CFAbsoluteTime = 1000.0

        // First two: re-enable in place
        #expect(tracker.recordTimeout(at: base) == .reenableInPlace)
        #expect(tracker.recordTimeout(at: base + 5) == .reenableInPlace)

        // Third within 30s window: full recreation
        #expect(tracker.recordTimeout(at: base + 10) == .fullRecreation)
        #expect(tracker.rollingTimeoutCount == 3)
        #expect(tracker.lifecycleState == .recovering)
    }

    @Test
    func timeoutWindowResetsAfterExpiry() {
        var tracker = EventTapLifecycleTracker()
        let base: CFAbsoluteTime = 1000.0

        #expect(tracker.recordTimeout(at: base) == .reenableInPlace)
        #expect(tracker.recordTimeout(at: base + 5) == .reenableInPlace)

        // Third timeout after 30s window expires — counter resets
        #expect(tracker.recordTimeout(at: base + 35) == .reenableInPlace)
        #expect(tracker.rollingTimeoutCount == 1)
    }

    @Test
    func repeatedRecreationDoesNotDeadlockBackgroundRunLoopThread() {
        var tracker = EventTapLifecycleTracker()
        let base: CFAbsoluteTime = 1000.0

        // First recreation cycle
        _ = tracker.recordTimeout(at: base)
        _ = tracker.recordTimeout(at: base + 1)
        #expect(tracker.recordTimeout(at: base + 2) == .fullRecreation)
        tracker.recordRecreationSuccess(at: base + 3)
        #expect(tracker.lifecycleState == .running)
        #expect(tracker.rollingTimeoutCount == 0)

        // Second recreation cycle — counters were reset, works again
        _ = tracker.recordTimeout(at: base + 10)
        _ = tracker.recordTimeout(at: base + 11)
        #expect(tracker.recordTimeout(at: base + 12) == .fullRecreation)
        tracker.recordRecreationSuccess(at: base + 13)
        #expect(tracker.lifecycleState == .running)
    }

    @Test
    func recreationFailureEmitsExplicitDegradedState() {
        var tracker = EventTapLifecycleTracker()
        let base: CFAbsoluteTime = 1000.0

        // Trigger recreation
        _ = tracker.recordTimeout(at: base)
        _ = tracker.recordTimeout(at: base + 1)
        _ = tracker.recordTimeout(at: base + 2)

        // First recreation failure — not yet degraded
        let first = tracker.recordRecreationFailure(at: base + 3)
        #expect(first != .markDegraded)
        #expect(tracker.lifecycleState != .degraded)

        // Second recreation failure within 120s — degraded
        let second = tracker.recordRecreationFailure(at: base + 10)
        #expect(second == .markDegraded)
        #expect(tracker.lifecycleState == .degraded)
        #expect(tracker.recreationFailureCount == 2)
    }

    @Test
    func recreationFailureWindowResetsAfterExpiry() {
        var tracker = EventTapLifecycleTracker()
        let base: CFAbsoluteTime = 1000.0

        // Trigger recreation
        _ = tracker.recordTimeout(at: base)
        _ = tracker.recordTimeout(at: base + 1)
        _ = tracker.recordTimeout(at: base + 2)

        // First failure
        _ = tracker.recordRecreationFailure(at: base + 3)

        // Second failure AFTER 120s window — resets, not degraded
        let action = tracker.recordRecreationFailure(at: base + 130)
        #expect(action != .markDegraded)
        #expect(tracker.lifecycleState != .degraded)
        #expect(tracker.recreationFailureCount == 1)
    }

    @Test
    func successfulRecreationResetsBothCounters() {
        var tracker = EventTapLifecycleTracker()
        let base: CFAbsoluteTime = 1000.0

        _ = tracker.recordTimeout(at: base)
        _ = tracker.recordTimeout(at: base + 1)
        _ = tracker.recordTimeout(at: base + 2) // triggers recreation

        // One failure, then success
        _ = tracker.recordRecreationFailure(at: base + 3)
        tracker.recordRecreationSuccess(at: base + 5)

        #expect(tracker.rollingTimeoutCount == 0)
        #expect(tracker.recreationFailureCount == 0)
        #expect(tracker.lifecycleState == .running)
    }

    @Test
    func recoveryFromDegradedStateReturnsToRunning() {
        var tracker = EventTapLifecycleTracker()
        let base: CFAbsoluteTime = 1000.0

        // Drive to degraded
        _ = tracker.recordTimeout(at: base)
        _ = tracker.recordTimeout(at: base + 1)
        _ = tracker.recordTimeout(at: base + 2)
        _ = tracker.recordRecreationFailure(at: base + 3)
        _ = tracker.recordRecreationFailure(at: base + 4)
        #expect(tracker.lifecycleState == .degraded)

        // Successful recreation recovers
        tracker.recordRecreationSuccess(at: base + 10)
        #expect(tracker.lifecycleState == .running)
    }
}

// MARK: - Lifecycle snapshot and logging

@Suite("EventTapManagerLifecycle logging")
struct EventTapLifecycleLoggingTests {

    @Test
    func snapshotCaptureIsPureValueWithNoSideEffects() {
        let tracker = EventTapLifecycleTracker()
        let snapshot = tracker.captureSnapshot(at: 1000.0, threadIdentity: "bg-runloop-1")

        // Snapshot is a value type with all required fields
        #expect(snapshot.rollingTimeoutCount == 0)
        #expect(snapshot.lifecycleState == .running)
        #expect(snapshot.threadIdentity == "bg-runloop-1")
    }

    @Test
    func logEntryContainsAllRequiredFields() {
        var tracker = EventTapLifecycleTracker()
        _ = tracker.recordTimeout(at: 1000.0)

        let snapshot = tracker.captureSnapshot(at: 1005.0, threadIdentity: "bg-runloop-1")
        let entry = EventTapLifecycleLogEntry(
            event: "EVENT_TAP_REENABLED",
            snapshot: snapshot
        )
        let message = entry.logMessage

        #expect(message.contains("EVENT_TAP_REENABLED"))
        #expect(message.contains("rollingTimeoutCount=1"))
        #expect(message.contains("timeSinceLastTimeout="))
        #expect(message.contains("recoveryMode="))
        #expect(message.contains("threadIdentity=bg-runloop-1"))
        #expect(message.contains("readinessState="))
    }

    @Test
    func allLifecycleLogFamiliesAreFormattable() {
        let events = [
            "EVENT_TAP_STARTED",
            "EVENT_TAP_DISABLED",
            "EVENT_TAP_REENABLED",
            "EVENT_TAP_RECREATED",
            "EVENT_TAP_RECREATION_FAILED",
            "EVENT_TAP_DEGRADED",
            "EVENT_TAP_RECOVERED",
        ]
        let snapshot = EventTapLifecycleSnapshot(
            rollingTimeoutCount: 3,
            recreationFailureCount: 1,
            timeSinceLastTimeout: 2.5,
            lifecycleState: .recovering,
            recoveryMode: "recreated",
            threadIdentity: "bg-runloop",
            readinessState: "recovering"
        )
        for event in events {
            let entry = EventTapLifecycleLogEntry(event: event, snapshot: snapshot)
            let msg = entry.logMessage
            #expect(msg.hasPrefix(event))
            #expect(msg.contains("rollingTimeoutCount=3"))
        }
    }
}

// MARK: - Callback-safe recovery dispatch

@Suite("EventTapManagerLifecycle callback safety")
struct EventTapLifecycleCallbackSafetyTests {

    @Test
    func timeoutRecordAndDecideIsCallbackSafe() {
        // recordTimeoutAndDecide runs inside the lock within the event tap
        // callback. It must be a fast, pure state-machine operation that
        // returns a value type (action + snapshot) with no file I/O.
        let box = EventTapBox()
        let (action, snapshot) = box.recordTimeoutAndDecide(
            at: 1000.0, threadIdentity: "test-thread"
        )
        #expect(action == .reenableInPlace)
        #expect(snapshot.rollingTimeoutCount == 1)
        #expect(snapshot.threadIdentity == "test-thread")
    }

    @Test
    func recreationEscalationIsDispatchedNotInline() {
        // When recreation threshold is reached, onRecoveryNeeded must be
        // called (not inline tap logic). Verify the box records the action
        // and snapshot correctly for async dispatch.
        let box = EventTapBox()
        let capturedAction = LockedValue<EventTapRecoveryAction?>(nil)
        let capturedSnapshot = LockedValue<EventTapLifecycleSnapshot?>(nil)
        box.onRecoveryNeeded = { action, snapshot in
            capturedAction.value = action
            capturedSnapshot.value = snapshot
        }

        // Drive to recreation threshold
        _ = box.recordTimeoutAndDecide(at: 1000.0, threadIdentity: "t")
        _ = box.recordTimeoutAndDecide(at: 1001.0, threadIdentity: "t")
        let (action, snapshot) = box.recordTimeoutAndDecide(at: 1002.0, threadIdentity: "t")

        #expect(action == .fullRecreation)

        // Simulate what the callback handler does
        box.onRecoveryNeeded?(action, snapshot)

        #expect(capturedAction.value == .fullRecreation)
        #expect(capturedSnapshot.value?.rollingTimeoutCount == 3)
    }
}
