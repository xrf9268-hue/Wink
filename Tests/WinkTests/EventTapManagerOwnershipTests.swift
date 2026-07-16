import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Wink

@Suite("EventTapManager owned-session lifecycle")
struct EventTapManagerOwnedSessionTests {
    @Test @MainActor
    func replacementTapFailureExecutesRetryDegradesAndStopsIdempotently() async {
        let runtime = RecordingEventTapRuntime(replacementTapFailuresPerGeneration: 2)
        let manager = EventTapManager(runtimeFactory: runtime.factory)

        #expect(manager.start { _ in true } == .started)
        let running = manager.ownershipSnapshot
        #expect(running.lifecycleState == .running)
        #expect(running.ownerCount == 1)
        #expect(running.tapOwned == 1)
        #expect(running.sourceOwned == 1)
        #expect(running.boxOwned == 1)
        #expect(running.threadOwned == 1)

        await runtime.triggerRecreationThreshold()

        #expect(runtime.replacementTapAttempts == 2)
        #expect(manager.lifecycleState == .degraded)
        #expect(manager.isRunning == false)

        manager.stop()
        let stoppedOnce = manager.ownershipSnapshot
        #expect(stoppedOnce.lifecycleState == .stopped)
        #expect(stoppedOnce.ownerCount == 0)
        #expect(stoppedOnce.tapCreates == stoppedOnce.tapReleases)
        #expect(stoppedOnce.sourceCreates == stoppedOnce.sourceReleases)
        #expect(stoppedOnce.boxCreates == stoppedOnce.boxReleases)
        #expect(stoppedOnce.threadCreates == stoppedOnce.threadReleases)
        let allThreadsExited = runtime.threads.allSatisfy { $0.hasExited }
        #expect(allThreadsExited)

        manager.stop()
        #expect(manager.ownershipSnapshot == stoppedOnce)
    }

    @Test @MainActor
    func replacementSourceFailureReleasesEachTapAndDegrades() async {
        let runtime = RecordingEventTapRuntime(replacementSourceFailuresPerGeneration: 2)
        let manager = EventTapManager(runtimeFactory: runtime.factory)

        #expect(manager.start { _ in true } == .started)
        await runtime.triggerRecreationThreshold()

        #expect(runtime.replacementTapAttempts == 2)
        #expect(runtime.replacementSourceAttempts == 2)
        #expect(manager.lifecycleState == .degraded)
        #expect(manager.isRunning == false)

        let degraded = manager.ownershipSnapshot
        #expect(degraded.ownerCount == 0)
        #expect(degraded.tapCreates == degraded.tapReleases)
        #expect(degraded.sourceCreates == degraded.sourceReleases)
        #expect(degraded.boxCreates == degraded.boxReleases)
        #expect(degraded.threadCreates == degraded.threadReleases)

        manager.stop()
        manager.stop()
        let stopped = manager.ownershipSnapshot
        #expect(stopped.lifecycleState == .stopped)
        #expect(stopped.tapCreates == stopped.tapReleases)
        #expect(stopped.sourceCreates == stopped.sourceReleases)
    }

    @Test @MainActor
    func replacementTapFailureRetriesThenRecoversWithOneOwner() async {
        let runtime = RecordingEventTapRuntime(replacementTapFailuresPerGeneration: 1)
        let manager = EventTapManager(runtimeFactory: runtime.factory)

        #expect(manager.start { _ in true } == .started)
        await runtime.triggerRecreationThreshold()

        let recovered = manager.ownershipSnapshot
        #expect(runtime.replacementTapAttempts == 2)
        #expect(manager.lifecycleState == .running)
        #expect(manager.isRunning)
        #expect(recovered.ownerCount == 1)
        #expect(recovered.tapOwned == 1)
        #expect(recovered.sourceOwned == 1)
        #expect(recovered.boxOwned == 1)
        #expect(recovered.threadOwned == 1)

        manager.stop()
        let stopped = manager.ownershipSnapshot
        #expect(stopped.tapCreates == stopped.tapReleases)
        #expect(stopped.sourceCreates == stopped.sourceReleases)
        #expect(stopped.boxCreates == stopped.boxReleases)
        #expect(stopped.threadCreates == stopped.threadReleases)
    }

    @Test @MainActor
    func initialTapFailureStopsTwiceWithoutLeakingPartialOwner() {
        let runtime = RecordingEventTapRuntime(initialTapFailures: 1)
        let manager = EventTapManager(runtimeFactory: runtime.factory)

        #expect(manager.start { _ in true } == .failedToCreateTap)
        let failed = manager.ownershipSnapshot
        #expect(failed.lifecycleState == .stopped)
        #expect(failed.ownerCount == 0)
        #expect(failed.tapCreates == failed.tapReleases)
        #expect(failed.sourceCreates == failed.sourceReleases)
        #expect(failed.boxCreates == failed.boxReleases)
        #expect(failed.threadCreates == failed.threadReleases)

        manager.stop()
        manager.stop()
        #expect(manager.ownershipSnapshot == failed)
    }

    @Test @MainActor
    func initialSourceFailureStopsTwiceAndReleasesCreatedTap() {
        let runtime = RecordingEventTapRuntime(initialSourceFailures: 1)
        let manager = EventTapManager(runtimeFactory: runtime.factory)

        #expect(manager.start { _ in true } == .failedToCreateTap)
        let failed = manager.ownershipSnapshot
        #expect(failed.lifecycleState == .stopped)
        #expect(failed.ownerCount == 0)
        #expect(failed.tapCreates == 1)
        #expect(failed.tapCreates == failed.tapReleases)
        #expect(failed.sourceCreates == failed.sourceReleases)
        #expect(failed.boxCreates == failed.boxReleases)
        #expect(failed.threadCreates == failed.threadReleases)

        manager.stop()
        manager.stop()
        #expect(manager.ownershipSnapshot == failed)
    }

    @Test @MainActor
    func twentyFailStopRestartCyclesKeepExactlyOneOwnerAndReleaseAllPriorGenerations() async {
        let runtime = RecordingEventTapRuntime(replacementTapFailuresPerGeneration: 2)
        let manager = EventTapManager(runtimeFactory: runtime.factory)

        #expect(manager.start { _ in true } == .started)
        for _ in 1...20 {
            let failedThread = runtime.threads.last
            await runtime.triggerRecreationThreshold()

            #expect(manager.lifecycleState == .degraded)
            #expect(manager.isRunning == false)
            #expect(failedThread?.hasExited == true)

            manager.stop()
            manager.stop()
            #expect(manager.lifecycleState == .stopped)
            #expect(manager.start { _ in true } == .started)

            let recovered = manager.ownershipSnapshot
            #expect(recovered.ownerCount == 1)
            #expect(recovered.ready)
            #expect(recovered.tapOwned == 1)
            #expect(recovered.sourceOwned == 1)
            #expect(recovered.boxOwned == 1)
            #expect(recovered.threadOwned == 1)
            let priorThreadsExited = runtime.threads.dropLast().allSatisfy { $0.hasExited }
            #expect(priorThreadsExited)
            let priorBoxesReleased = runtime.boxes.dropLast().allSatisfy { $0.value == nil }
            #expect(priorBoxesReleased)
        }

        manager.stop()
        let final = manager.ownershipSnapshot
        #expect(final.ownerCount == 0)
        #expect(final.tapCreates == final.tapReleases)
        #expect(final.sourceCreates == final.sourceReleases)
        #expect(final.boxCreates == final.boxReleases)
        #expect(final.threadCreates == final.threadReleases)
        #expect(final.keyCallbackDeliveries == 0)
        let allThreadsExited = runtime.threads.allSatisfy { $0.hasExited }
        #expect(allThreadsExited)
        let allBoxesReleased = runtime.boxes.allSatisfy { $0.value == nil }
        #expect(allBoxesReleased)
    }

    @Test @MainActor
    func callbacksCapturedFromStoppedGenerationCannotReachRestartedOwner() async {
        let runtime = RecordingEventTapRuntime()
        let manager = EventTapManager(runtimeFactory: runtime.factory)
        var handledCount = 0

        #expect(manager.start { _ in
            handledCount += 1
            return true
        } == .started)
        let oldBox = try! #require(runtime.boxes.last?.value)
        let staleKeyCallback = try! #require(oldBox.onKeyPress)
        let staleRecoveryCallback = try! #require(oldBox.onRecoveryNeeded)
        var pendingRecovery: (EventTapRecoveryAction, EventTapLifecycleSnapshot)?
        for now in [1000.0, 1001.0, 1002.0] {
            let decision = oldBox.recordTimeoutAndDecide(
                at: now,
                threadIdentity: "stopped-generation"
            )
            if decision.0 == .fullRecreation {
                pendingRecovery = decision
            }
        }
        let recovery = try! #require(pendingRecovery)

        manager.stop()
        #expect(manager.start { _ in
            handledCount += 1
            return true
        } == .started)
        let beforeStaleCallbacks = manager.ownershipSnapshot

        staleKeyCallback(
            KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command])
        )
        staleRecoveryCallback(recovery.0, recovery.1)
        await Task.yield()
        await Task.yield()
        await Task.yield()

        let afterStaleCallbacks = manager.ownershipSnapshot
        #expect(handledCount == 0)
        #expect(afterStaleCallbacks.generation == beforeStaleCallbacks.generation)
        #expect(afterStaleCallbacks.ownerCount == 1)
        #expect(afterStaleCallbacks.tapCreates == beforeStaleCallbacks.tapCreates)
        #expect(afterStaleCallbacks.sourceCreates == beforeStaleCallbacks.sourceCreates)
        #expect(afterStaleCallbacks.keyCallbackDeliveries == beforeStaleCallbacks.keyCallbackDeliveries)
        #expect(afterStaleCallbacks.staleCallbacksDiscarded == 2)

        manager.stop()
    }

    @Test @MainActor
    func directRestartTearsDownPartialOwnerBeforePublishingNewGeneration() {
        let runtime = RecordingEventTapRuntime()
        let manager = EventTapManager(runtimeFactory: runtime.factory)

        #expect(manager.start { _ in true } == .started)
        manager.setHyperKeyEnabled(true)
        let firstThread = runtime.threads[0]
        let firstBox = runtime.boxes[0]
        firstThread.simulateUnexpectedExit()
        #expect(manager.isRunning == false)

        #expect(manager.start { _ in true } == .started)
        let restarted = manager.ownershipSnapshot
        #expect(firstThread.hasExited)
        #expect(firstBox.value == nil)
        #expect(restarted.generation == 2)
        #expect(restarted.ownerCount == 1)
        #expect(restarted.threadCreates == 2)
        #expect(restarted.threadReleases == 1)
        #expect(restarted.boxCreates == 2)
        #expect(restarted.boxReleases == 1)
        #expect(restarted.tapOwned == 1)
        #expect(restarted.sourceOwned == 1)
        #expect(restarted.boxOwned == 1)
        #expect(restarted.threadOwned == 1)
        #expect(runtime.boxes[1].value?.hyperKeyEnabled == true)

        manager.stop()
    }

    @Test
    func inFlightReenableAndTapTeardownAreSerialized() {
        let box = EventTapBox()
        box.installTap(makeTestingMachPort())
        let reenableEntered = DispatchSemaphore(value: 0)
        let allowReenableToFinish = DispatchSemaphore(value: 0)
        let reenableFinished = DispatchSemaphore(value: 0)
        let teardownFinished = DispatchSemaphore(value: 0)
        let events = LockedValue<[String]>([])

        DispatchQueue.global(qos: .userInitiated).async {
            box.reenableTapIfNeeded { _ in
                events.value.append("reenable-begin")
                reenableEntered.signal()
                allowReenableToFinish.wait()
                events.value.append("reenable-end")
            }
            reenableFinished.signal()
        }
        let entered = reenableEntered.wait(timeout: .now() + 1)
        #expect(entered == .success)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = box.tearDownTap { tap in
                events.value.append("teardown")
                CFMachPortInvalidate(tap)
            }
            teardownFinished.signal()
        }
        let teardownWhileReenableBlocked = teardownFinished.wait(timeout: .now() + 0.05)
        #expect(teardownWhileReenableBlocked == .timedOut)

        allowReenableToFinish.signal()
        let reenableCompleted = reenableFinished.wait(timeout: .now() + 1)
        let teardownCompleted = teardownFinished.wait(timeout: .now() + 1)
        #expect(reenableCompleted == .success)
        #expect(teardownCompleted == .success)
        #expect(events.value == ["reenable-begin", "reenable-end", "teardown"])
        #expect(box.tearDownTap { _ in } == false)
    }
}

@MainActor
private final class RecordingEventTapRuntime {
    private let replacementTapFailuresPerGeneration: Int
    private let replacementSourceFailuresPerGeneration: Int
    private var initialTapFailuresRemaining: Int
    private var initialSourceFailuresRemaining: Int
    private var replacementTapFailures: [UInt64: Int] = [:]
    private var replacementSourceFailures: [UInt64: Int] = [:]
    private(set) var replacementTapAttempts = 0
    private(set) var replacementSourceAttempts = 0
    private(set) var boxes: [WeakEventTapBox] = []
    private(set) var threads: [RecordingEventTapRunLoopThread] = []

    init(
        initialTapFailures: Int = 0,
        initialSourceFailures: Int = 0,
        replacementTapFailuresPerGeneration: Int = 0,
        replacementSourceFailuresPerGeneration: Int = 0
    ) {
        initialTapFailuresRemaining = initialTapFailures
        initialSourceFailuresRemaining = initialSourceFailures
        self.replacementTapFailuresPerGeneration = replacementTapFailuresPerGeneration
        self.replacementSourceFailuresPerGeneration = replacementSourceFailuresPerGeneration
    }

    lazy var factory = EventTapRuntimeFactory(
        makeThread: { [unowned self] generation in
            let thread = RecordingEventTapRunLoopThread(generation: generation)
            threads.append(thread)
            return thread
        },
        makeTap: { [unowned self] context, _, _, userInfo in
            let box = Unmanaged<EventTapBox>.fromOpaque(userInfo).takeUnretainedValue()
            if boxes.last?.value !== box {
                boxes.append(WeakEventTapBox(box))
            }
            if context.phase == .initial, initialTapFailuresRemaining > 0 {
                initialTapFailuresRemaining -= 1
                return nil
            }
            if context.phase == .replacement {
                replacementTapAttempts += 1
                let failures = replacementTapFailures[context.generation, default: 0]
                if failures < replacementTapFailuresPerGeneration {
                    replacementTapFailures[context.generation] = failures + 1
                    return nil
                }
            }
            return makeTestingMachPort()
        },
        makeSource: { [unowned self] context, tap in
            if context.phase == .initial, initialSourceFailuresRemaining > 0 {
                initialSourceFailuresRemaining -= 1
                return nil
            }
            if context.phase == .replacement {
                replacementSourceAttempts += 1
                let failures = replacementSourceFailures[context.generation, default: 0]
                if failures < replacementSourceFailuresPerGeneration {
                    replacementSourceFailures[context.generation] = failures + 1
                    return nil
                }
            }
            return CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        },
        setTapEnabled: { _, _ in },
        invalidateTap: { tap in CFMachPortInvalidate(tap) },
        now: { CFAbsoluteTimeGetCurrent() }
    )

    func triggerRecreationThreshold() async {
        guard let box = boxes.last?.value else {
            Issue.record("expected the current EventTapBox owner")
            return
        }
        for now in [1000.0, 1001.0, 1002.0] {
            let (action, snapshot) = box.recordTimeoutAndDecide(
                at: now,
                threadIdentity: "recording-thread"
            )
            if action == .fullRecreation || action == .markDegraded {
                box.onRecoveryNeeded?(action, snapshot)
            }
        }
        await Task.yield()
        await Task.yield()
    }
}

private final class WeakEventTapBox {
    weak var value: EventTapBox?

    init(_ value: EventTapBox) {
        self.value = value
    }
}

private final class RecordingEventTapRunLoopThread: EventTapRunLoopThread {
    let identity: String
    let threadID: UInt64?
    private(set) var hasExited = false
    private(set) var isAlive = false

    init(generation: UInt64) {
        identity = "recording-event-tap-\(generation)"
        threadID = generation
    }

    func start() {
        isAlive = true
    }

    func addSource(_ source: CFRunLoopSource) {}

    func removeSource(_ source: CFRunLoopSource) {}

    func cancelAndWait() {
        isAlive = false
        hasExited = true
    }

    func simulateUnexpectedExit() {
        isAlive = false
        hasExited = true
    }
}

private func makeTestingMachPort() -> CFMachPort {
    var context = CFMachPortContext(
        version: 0,
        info: nil,
        retain: nil,
        release: nil,
        copyDescription: nil
    )
    return CFMachPortCreate(kCFAllocatorDefault, nil, &context, nil)!
}
