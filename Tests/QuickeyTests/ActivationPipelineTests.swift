import Foundation
import os
import Testing
@testable import Quickey

@Test
func latestGenerationDropsQueuedMutatingCommandsBeforeExecution() async {
    let store = LatestGenerationStore()
    let executedCommands = OSAllocatedUnfairLock<[Int]>(initialState: [])

    let pipeline = ActivationPipeline(
        timeouts: ActivationTimeoutBudget(),
        client: .init(
            prepareRestoreContext: { _ in .completed("prepared") },
            runMutatingCommand: { command in
                // Extract generation from the command's restore context
                let gen: Int
                switch command {
                case .restorePreviousFast(let ctx):
                    gen = ctx.generation
                case .restorePreviousCompatible(let ctx):
                    gen = ctx.generation
                default:
                    gen = -1
                }
                executedCommands.withLock { $0.append(gen) }
                return .completed("done")
            }
        )
    )

    // Submit generation 1
    let ctx1 = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 42,
        previousPSNHint: nil,
        previousWindowIDHint: nil,
        previousBundleURL: nil,
        capturedAt: 100,
        generation: 1
    )

    // Submit generation 2
    let ctx2 = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 42,
        previousPSNHint: nil,
        previousWindowIDHint: nil,
        previousBundleURL: nil,
        capturedAt: 101,
        generation: 2
    )

    // Advance store to generation 2 before gen 1 executes
    store.write(2)

    let result1 = await withCheckedContinuation { continuation in
        pipeline.submit(
            .restorePreviousFast(ctx1),
            generation: 1,
            latestGeneration: { store.read() },
            completion: { result in continuation.resume(returning: result) }
        )
    }

    // Generation 1 should be cancelled because store already has 2
    #expect(result1 == .cancelledByNewerGeneration(1))

    let result2 = await withCheckedContinuation { continuation in
        pipeline.submit(
            .restorePreviousFast(ctx2),
            generation: 2,
            latestGeneration: { store.read() },
            completion: { result in continuation.resume(returning: result) }
        )
    }

    // Generation 2 should execute normally
    #expect(result2 == .completed("done"))

    // Only generation 2 should have actually executed
    executedCommands.withLock { #expect($0 == [2]) }
}

@Test
func restoreFastTimeoutMapsToNeedsFallback() async {
    let pipeline = ActivationPipeline(
        timeouts: ActivationTimeoutBudget(restorePreviousFast: 0.01),
        client: .init(
            prepareRestoreContext: { _ in .completed("prepared") },
            runMutatingCommand: { _ in
                // Simulate slow command that exceeds timeout — 300ms
                // is well above 10ms timeout to avoid CI flakiness
                Thread.sleep(forTimeInterval: 0.3)
                return .completed("done")
            }
        )
    )

    let store = LatestGenerationStore()
    store.write(1)

    let ctx = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 42,
        previousPSNHint: nil,
        previousWindowIDHint: nil,
        previousBundleURL: nil,
        capturedAt: 100,
        generation: 1
    )

    let result = await withCheckedContinuation { continuation in
        pipeline.submit(
            .restorePreviousFast(ctx),
            generation: 1,
            latestGeneration: { store.read() },
            completion: { result in continuation.resume(returning: result) }
        )
    }

    #expect(result == .needsFallback("timeout_restore_fast"))
}

@Test
func contextPreparationUsesBoundedConcurrency() async {
    let concurrentCount = OSAllocatedUnfairLock(initialState: 0)
    let maxObserved = OSAllocatedUnfairLock(initialState: 0)

    let pipeline = ActivationPipeline(
        timeouts: ActivationTimeoutBudget(prepareRestoreContext: 5.0),
        client: .init(
            prepareRestoreContext: { _ in
                let current = concurrentCount.withLock { val -> Int in
                    val += 1
                    return val
                }
                maxObserved.withLock { val in
                    if current > val { val = current }
                }
                // Hold long enough to guarantee overlap in CI — must be shorter
                // than prepareRestoreContext timeout (5s). Previous 50ms was too
                // tight under CI load, causing false concurrency overshoot (#105).
                Thread.sleep(forTimeInterval: 0.3)
                concurrentCount.withLock { val in val -= 1 }
                return .completed("prepared")
            },
            runMutatingCommand: { _ in .completed("done") }
        )
    )

    let store = LatestGenerationStore()
    store.write(3)

    // Submit 3 prepare commands concurrently
    await withTaskGroup(of: ActivationCommandResult.self) { group in
        for _ in 1...3 {
            group.addTask {
                await withCheckedContinuation { continuation in
                    pipeline.submitPrepare(
                        .prepareRestoreContext(
                            targetBundleIdentifier: "com.apple.Safari",
                            previousBundleIdentifier: "com.apple.Terminal"
                        ),
                        completion: { result in continuation.resume(returning: result) }
                    )
                }
            }
        }
        for await _ in group {}
    }

    let max = maxObserved.withLock { $0 }
    // Should be bounded to 2 concurrent
    #expect(max <= 2)
}

@Test
func hideTargetTimeoutMapsToNeedsFallback() async {
    let pipeline = ActivationPipeline(
        timeouts: ActivationTimeoutBudget(hideTarget: 0.01),
        client: .init(
            prepareRestoreContext: { _ in .completed("prepared") },
            runMutatingCommand: { _ in
                Thread.sleep(forTimeInterval: 0.3)
                return .completed("done")
            }
        )
    )

    let store = LatestGenerationStore()
    store.write(1)

    let result = await withCheckedContinuation { continuation in
        pipeline.submit(
            .hideTarget(bundleIdentifier: "com.apple.Safari", pid: 42),
            generation: 1,
            latestGeneration: { store.read() },
            completion: { result in continuation.resume(returning: result) }
        )
    }

    #expect(result == .needsFallback("timeout_hide_target"))
}

@Test
func restoreCompatibleTimeoutMapsToDegraded() async {
    let pipeline = ActivationPipeline(
        timeouts: ActivationTimeoutBudget(restorePreviousCompatible: 0.01),
        client: .init(
            prepareRestoreContext: { _ in .completed("prepared") },
            runMutatingCommand: { _ in
                Thread.sleep(forTimeInterval: 0.3)
                return .completed("done")
            }
        )
    )

    let store = LatestGenerationStore()
    store.write(1)

    let ctx = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 42,
        previousPSNHint: nil,
        previousWindowIDHint: nil,
        previousBundleURL: nil,
        capturedAt: 100,
        generation: 1
    )

    let result = await withCheckedContinuation { continuation in
        pipeline.submit(
            .restorePreviousCompatible(ctx),
            generation: 1,
            latestGeneration: { store.read() },
            completion: { result in continuation.resume(returning: result) }
        )
    }

    #expect(result == .degraded("timeout_restore_compatible"))
}

@Test
func raiseWindowTimeoutMapsToDegraded() async {
    let pipeline = ActivationPipeline(
        timeouts: ActivationTimeoutBudget(raiseWindow: 0.01),
        client: .init(
            prepareRestoreContext: { _ in .completed("prepared") },
            runMutatingCommand: { _ in
                Thread.sleep(forTimeInterval: 0.3)
                return .completed("done")
            }
        )
    )

    let store = LatestGenerationStore()
    store.write(1)

    let result = await withCheckedContinuation { continuation in
        pipeline.submit(
            .raiseWindow(bundleIdentifier: "com.apple.Safari", pid: 42, windowID: 314),
            generation: 1,
            latestGeneration: { store.read() },
            completion: { result in continuation.resume(returning: result) }
        )
    }

    #expect(result == .degraded("timeout_raise_window"))
}

@Test
func prepareRestoreContextTimeoutMapsToDegraded() async {
    let pipeline = ActivationPipeline(
        timeouts: ActivationTimeoutBudget(prepareRestoreContext: 0.01),
        client: .init(
            prepareRestoreContext: { _ in
                Thread.sleep(forTimeInterval: 0.3)
                return .completed("prepared")
            },
            runMutatingCommand: { _ in .completed("done") }
        )
    )

    let result = await withCheckedContinuation { continuation in
        pipeline.submitPrepare(
            .prepareRestoreContext(
                targetBundleIdentifier: "com.apple.Safari",
                previousBundleIdentifier: "com.apple.Terminal"
            ),
            completion: { result in continuation.resume(returning: result) }
        )
    }

    #expect(result == .degraded("timeout_prepare_restore_context"))
}

@Test
func latestGenerationStoreIsThreadSafe() async {
    let store = LatestGenerationStore()

    await withTaskGroup(of: Void.self) { group in
        for i in 0..<100 {
            group.addTask {
                store.write(i)
                _ = store.read()
            }
        }
    }

    let finalValue = store.read()
    #expect(finalValue >= 0 && finalValue < 100)
}
