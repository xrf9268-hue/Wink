import Foundation

// MARK: - LatestGenerationStore

/// Thread-safe store for tracking the latest accepted generation.
/// Used by the pipeline to implement latest-wins dropping: commands from
/// older generations are cancelled before execution.
final class LatestGenerationStore: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)

    func read() -> Int {
        storage.withLock { $0 }
    }

    func write(_ newValue: Int) {
        storage.withLock { $0 = newValue }
    }
}

// MARK: - ActivationPipeline

/// Two-lane executor for activation commands.
///
/// - `contextPreparationLane`: bounded low concurrency (max 2), read-only operations
/// - `activationCommandLane`: global serial, mutating commands with latest-wins dropping
///
/// Mutating commands check the latest generation before execution. If the command's
/// generation is stale, it returns `.cancelledByNewerGeneration` without executing.
/// Timeout results map to spec-defined error strings per command type.
final class ActivationPipeline: @unchecked Sendable {

    // MARK: - Client

    struct Client: Sendable {
        let prepareRestoreContext: @Sendable (ActivationCommand) -> ActivationCommandResult
        let runMutatingCommand: @Sendable (ActivationCommand) -> ActivationCommandResult
    }

    // MARK: - Properties

    private let timeouts: ActivationTimeoutBudget
    private let client: Client

    private let contextPreparationQueue: OperationQueue
    private let activationCommandQueue: OperationQueue
    // Shared work queue for timeout execution to avoid per-call allocation overhead.
    private let timeoutWorkQueue = DispatchQueue(
        label: "com.quickey.pipeline.work",
        qos: .userInteractive,
        attributes: .concurrent
    )

    // MARK: - Init

    init(timeouts: ActivationTimeoutBudget, client: Client) {
        self.timeouts = timeouts
        self.client = client

        self.contextPreparationQueue = OperationQueue()
        contextPreparationQueue.name = "com.quickey.pipeline.contextPreparation"
        contextPreparationQueue.maxConcurrentOperationCount = 2
        contextPreparationQueue.qualityOfService = .userInteractive

        self.activationCommandQueue = OperationQueue()
        activationCommandQueue.name = "com.quickey.pipeline.activationCommand"
        activationCommandQueue.maxConcurrentOperationCount = 1
        activationCommandQueue.qualityOfService = .userInteractive
    }

    // MARK: - Prepare (bounded concurrency)

    /// Submit a prepare command to the bounded concurrency lane.
    func submitPrepare(
        _ command: ActivationCommand,
        completion: @escaping @Sendable (ActivationCommandResult) -> Void
    ) {
        let client = self.client
        let timeout = timeouts.prepareRestoreContext

        contextPreparationQueue.addOperation {
            let result = self.executeWithTimeout(timeout: timeout) {
                client.prepareRestoreContext(command)
            }

            // prepareRestoreContext timeout does not directly report failure,
            // it only degrades fast-lane eligibility. Map timeout to degraded.
            let mapped: ActivationCommandResult
            if case .timedOut = result {
                mapped = .degraded("timeout_prepare_restore_context")
            } else {
                mapped = result.value
            }
            completion(mapped)
        }
    }

    // MARK: - Submit mutating (serial + latest-wins)

    /// Submit a mutating command to the serial lane with latest-wins dropping.
    /// Before execution, checks `latestGeneration()` against the provided `generation`.
    /// If stale, returns `.cancelledByNewerGeneration` without executing.
    func submit(
        _ command: ActivationCommand,
        generation: Int,
        latestGeneration: @escaping @Sendable () -> Int,
        completion: @escaping @Sendable (ActivationCommandResult) -> Void
    ) {
        let client = self.client
        let timeout = self.timeout(for: command)

        activationCommandQueue.addOperation {
            // Latest-wins gate: check generation before execution
            let latest = latestGeneration()
            if generation < latest {
                completion(.cancelledByNewerGeneration(generation))
                return
            }

            let result = self.executeWithTimeout(timeout: timeout) {
                client.runMutatingCommand(command)
            }

            let mapped: ActivationCommandResult
            if case .timedOut = result {
                mapped = Self.timeoutResult(for: command)
            } else {
                mapped = result.value
            }
            completion(mapped)
        }
    }

    // MARK: - Timeout mapping

    /// Returns the timeout budget for a given command type.
    private func timeout(for command: ActivationCommand) -> TimeInterval {
        switch command {
        case .prepareRestoreContext:
            return timeouts.prepareRestoreContext
        case .restorePreviousFast:
            return timeouts.restorePreviousFast
        case .hideTarget:
            return timeouts.hideTarget
        case .restorePreviousCompatible:
            return timeouts.restorePreviousCompatible
        case .raiseWindow:
            return timeouts.raiseWindow
        }
    }

    /// Maps a timeout to the spec-defined result per command type.
    /// These strings are fixed by the spec and must not be changed.
    private static func timeoutResult(for command: ActivationCommand) -> ActivationCommandResult {
        switch command {
        case .prepareRestoreContext:
            return .degraded("timeout_prepare_restore_context")
        case .restorePreviousFast:
            return .needsFallback("timeout_restore_fast")
        case .hideTarget:
            return .needsFallback("timeout_hide_target")
        case .restorePreviousCompatible:
            return .degraded("timeout_restore_compatible")
        case .raiseWindow:
            return .degraded("timeout_raise_window")
        }
    }

    // MARK: - Timeout execution

    private enum TimedResult {
        case completed(ActivationCommandResult)
        case timedOut

        var value: ActivationCommandResult {
            switch self {
            case .completed(let result): return result
            case .timedOut: return .degraded("timeout_unknown")
            }
        }
    }

    /// Execute a block with a timeout on the shared work queue.
    /// Returns `.timedOut` if the block doesn't complete within the budget.
    private func executeWithTimeout(
        timeout: TimeInterval,
        block: @escaping @Sendable () -> ActivationCommandResult
    ) -> TimedResult {
        let lock = OSAllocatedUnfairLock(initialState: (result: ActivationCommandResult?.none, didTimeout: false))

        let semaphore = DispatchSemaphore(value: 0)

        timeoutWorkQueue.async {
            let result = block()
            lock.withLock { state in
                if !state.didTimeout {
                    state.result = result
                }
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)

        return lock.withLock { state in
            if waitResult == .timedOut {
                state.didTimeout = true
                return .timedOut
            } else {
                guard let result = state.result else {
                    return .timedOut
                }
                return .completed(result)
            }
        }
    }
}
