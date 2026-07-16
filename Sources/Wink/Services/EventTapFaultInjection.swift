#if WINK_EVENT_TAP_FAULT_INJECTION
import AppKit
import Foundation

/// Compile-time-only packaged runtime validation profile for EventTap
/// ownership and recovery. None of these declarations or marker strings are
/// present in production builds.
struct EventTapFaultInjectionConfiguration: Equatable, Sendable {
    enum Mode: String, Sendable {
        case replacementTapOnce = "replacement-tap-once"
        case replacementSourceUntilDegraded = "replacement-source-until-degraded"
        case cycle20
    }

    private static let argumentPrefix = "--validation-event-tap-fault="

    let mode: Mode

    init?(arguments: [String]) {
        let values = arguments.compactMap { argument -> String? in
            guard argument.hasPrefix(Self.argumentPrefix) else { return nil }
            return String(argument.dropFirst(Self.argumentPrefix.count))
        }
        guard values.count == 1, let mode = Mode(rawValue: values[0]) else {
            return nil
        }
        self.mode = mode
    }
}

struct EventTapStoppedGenerationProbe: Sendable {
    let generation: UInt64
    let keyCallback: @Sendable (KeyPress) -> Void
    let recoveryCallback: @Sendable (EventTapRecoveryAction, EventTapLifecycleSnapshot) -> Void
    let recoverySnapshot: EventTapLifecycleSnapshot
}

/// Wraps the real EventTap factories at the two precise replacement failure
/// points and drives the same timeout decision entry used by the C callback.
/// The class exists only in validation-profile binaries.
final class EventTapFaultInjectionDriver: @unchecked Sendable {
    private let configuration: EventTapFaultInjectionConfiguration
    private let baseRuntimeFactory: EventTapRuntimeFactory
    private let diagnosticLog: @Sendable (String) -> Void
    private let failureLock = NSLock()
    private var replacementTapFailuresByGeneration: [UInt64: Int] = [:]
    private var replacementSourceFailuresByGeneration: [UInt64: Int] = [:]

    @MainActor private var scenarioScheduled = false
    @MainActor private(set) var suppressFurtherStarts = false

    init(
        configuration: EventTapFaultInjectionConfiguration,
        baseRuntimeFactory: EventTapRuntimeFactory,
        diagnosticLog: @escaping @Sendable (String) -> Void = DiagnosticLog.log
    ) {
        self.configuration = configuration
        self.baseRuntimeFactory = baseRuntimeFactory
        self.diagnosticLog = diagnosticLog
        log(event: "configured")
    }

    @MainActor
    var runtimeFactory: EventTapRuntimeFactory {
        let base = baseRuntimeFactory
        return EventTapRuntimeFactory(
            makeThread: base.makeThread,
            makeTap: { [self] context, mask, callback, userInfo in
                if shouldFailReplacementTap(context) {
                    log(
                        event: "replacement_tap_failed",
                        details: "generation=\(context.generation) attempt=\(context.attempt)"
                    )
                    return nil
                }
                return base.makeTap(context, mask, callback, userInfo)
            },
            makeSource: { [self] context, tap in
                if shouldFailReplacementSource(context) {
                    log(
                        event: "replacement_source_failed",
                        details: "generation=\(context.generation) attempt=\(context.attempt)"
                    )
                    return nil
                }
                return base.makeSource(context, tap)
            },
            setTapEnabled: base.setTapEnabled,
            invalidateTap: base.invalidateTap,
            now: base.now
        )
    }

    @MainActor
    func scheduleScenario(
        manager: EventTapManager,
        handler: @escaping EventTapManager.ShortcutHandler
    ) {
        guard !scenarioScheduled else { return }
        scenarioScheduled = true
        Task { @MainActor [weak self, weak manager] in
            guard let self, let manager else { return }
            _ = await self.runScenario(manager: manager, handler: handler)
        }
    }

    @MainActor
    @discardableResult
    func runScenario(
        manager: EventTapManager,
        handler: @escaping EventTapManager.ShortcutHandler
    ) async -> Bool {
        log(event: "scenario_started")
        switch configuration.mode {
        case .replacementTapOnce:
            return await runSingleRecoveryScenario(
                manager: manager,
                expectRecovered: true
            )
        case .replacementSourceUntilDegraded:
            let passed = await runSingleRecoveryScenario(
                manager: manager,
                expectRecovered: false
            )
            suppressFurtherStarts = true
            return passed
        case .cycle20:
            let passed = await runCycleScenario(manager: manager, handler: handler)
            suppressFurtherStarts = true
            return passed
        }
    }

    private func shouldFailReplacementTap(_ context: EventTapCreationContext) -> Bool {
        guard context.phase == .replacement else { return false }
        failureLock.lock()
        defer { failureLock.unlock() }

        let count = replacementTapFailuresByGeneration[context.generation, default: 0]
        let shouldFail: Bool
        switch configuration.mode {
        case .replacementTapOnce:
            shouldFail = replacementTapFailuresByGeneration.values.reduce(0, +) == 0
        case .replacementSourceUntilDegraded:
            shouldFail = false
        case .cycle20:
            shouldFail = count < EventTapLifecycleTracker.recreationFailuresBeforeDegraded
        }
        if shouldFail {
            replacementTapFailuresByGeneration[context.generation] = count + 1
        }
        return shouldFail
    }

    private func shouldFailReplacementSource(_ context: EventTapCreationContext) -> Bool {
        guard context.phase == .replacement,
              configuration.mode == .replacementSourceUntilDegraded else {
            return false
        }
        failureLock.lock()
        defer { failureLock.unlock() }
        let count = replacementSourceFailuresByGeneration[context.generation, default: 0]
        guard count < EventTapLifecycleTracker.recreationFailuresBeforeDegraded else {
            return false
        }
        replacementSourceFailuresByGeneration[context.generation] = count + 1
        return true
    }

    @MainActor
    private func runSingleRecoveryScenario(
        manager: EventTapManager,
        expectRecovered: Bool
    ) async -> Bool {
        let before = manager.ownershipSnapshot
        let startedAt = CFAbsoluteTimeGetCurrent()
        manager.validationTriggerTimeoutThreshold()
        let reachedExpectedState = await waitUntil {
            expectRecovered
                ? manager.lifecycleState == .running
                    && manager.ownershipSnapshot.tapCreates > before.tapCreates
                : manager.lifecycleState == .degraded
        }
        let elapsedMilliseconds = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        let after = manager.ownershipSnapshot
        let resourcesValid: Bool
        if expectRecovered {
            resourcesValid = after.ready
                && after.ownerCount == 1
                && after.tapOwned == 1
                && after.sourceOwned == 1
                && after.boxOwned == 1
                && after.threadOwned == 1
                && after.threadID == before.threadID
        } else {
            resourcesValid = !after.ready
                && after.ownerCount == 0
                && after.tapOwned == 0
                && after.sourceOwned == 0
                && after.boxOwned == 0
                && after.threadOwned == 0
        }
        let passed = reachedExpectedState && elapsedMilliseconds <= 1_000 && resourcesValid
        diagnosticLog(after.logMessage(event: "scenario_snapshot", scenario: configuration.mode.rawValue))
        log(
            event: "scenario_complete",
            details: "result=\(passed ? "PASS" : "FAIL") elapsedMs=\(elapsedMilliseconds) deadlineMs=1000"
        )
        return passed
    }

    @MainActor
    private func runCycleScenario(
        manager: EventTapManager,
        handler: @escaping EventTapManager.ShortcutHandler
    ) async -> Bool {
        var allPassed = true

        for cycle in 1...20 {
            guard let probe = manager.validationCaptureStoppedGenerationProbe() else {
                log(event: "cycle_complete", details: "cycle=\(cycle) result=FAIL reason=missing_probe")
                allPassed = false
                break
            }
            let beforeFailure = manager.ownershipSnapshot
            manager.validationTriggerTimeoutThreshold()
            let degradedInTime = await waitUntil {
                manager.lifecycleState == .degraded
            }
            let degraded = manager.ownershipSnapshot
            let releasedFailedGeneration = degraded.ownerCount == 0
                && degraded.tapOwned == 0
                && degraded.sourceOwned == 0
                && degraded.boxOwned == 0
                && degraded.threadOwned == 0
                && degraded.threadReleases == beforeFailure.threadReleases + 1

            manager.stop()
            manager.stop()
            let restartResult = manager.start(onKeyPress: handler)
            let restarted = manager.ownershipSnapshot
            let restartedWithOneOwner = restartResult == .started
                && restarted.ready
                && restarted.ownerCount == 1
                && restarted.tapOwned == 1
                && restarted.sourceOwned == 1
                && restarted.boxOwned == 1
                && restarted.threadOwned == 1

            let deliveriesBeforeProbe = restarted.keyCallbackDeliveries
            let tapCreatesBeforeProbe = restarted.tapCreates
            let sourceCreatesBeforeProbe = restarted.sourceCreates
            let staleDiscardsBeforeProbe = restarted.staleCallbacksDiscarded
            probe.keyCallback(KeyPress(keyCode: 0, modifiers: [.command]))
            probe.recoveryCallback(.fullRecreation, probe.recoverySnapshot)
            let staleCallbacksRejected = await waitUntil {
                manager.ownershipSnapshot.staleCallbacksDiscarded
                    >= staleDiscardsBeforeProbe + 2
            }
            let afterProbe = manager.ownershipSnapshot
            let noStoppedGenerationDelivery = staleCallbacksRejected
                && afterProbe.keyCallbackDeliveries == deliveriesBeforeProbe
                && afterProbe.tapCreates == tapCreatesBeforeProbe
                && afterProbe.sourceCreates == sourceCreatesBeforeProbe
                && afterProbe.ownerCount == 1

            let cyclePassed = degradedInTime
                && releasedFailedGeneration
                && restartedWithOneOwner
                && noStoppedGenerationDelivery
            allPassed = allPassed && cyclePassed
            diagnosticLog(
                afterProbe.logMessage(
                    event: "cycle_snapshot_\(cycle)",
                    scenario: configuration.mode.rawValue
                )
            )
            log(
                event: "cycle_complete",
                details: "cycle=\(cycle) generation=\(probe.generation) previousThreadId=\(beforeFailure.threadID.map(String.init) ?? "nil") previousThreadReleased=\(releasedFailedGeneration) result=\(cyclePassed ? "PASS" : "FAIL")"
            )
        }

        let recovered = manager.ownershipSnapshot
        let recoveredWithOneOwner = recovered.ready
            && recovered.ownerCount == 1
            && recovered.tapOwned == 1
            && recovered.sourceOwned == 1
            && recovered.boxOwned == 1
            && recovered.threadOwned == 1
        diagnosticLog(recovered.logMessage(event: "cycle_recovered", scenario: configuration.mode.rawValue))

        manager.stop()
        let final = manager.ownershipSnapshot
        let finalNetZero = final.ownerCount == 0
            && final.tapOwned == 0
            && final.sourceOwned == 0
            && final.boxOwned == 0
            && final.threadOwned == 0
            && final.keyCallbackDeliveries == 0
            && final.staleCallbacksDiscarded == 40
        diagnosticLog(final.logMessage(event: "cycle_final_stop", scenario: configuration.mode.rawValue))

        let passed = allPassed && recoveredWithOneOwner && finalNetZero
        log(event: "scenario_complete", details: "result=\(passed ? "PASS" : "FAIL") cycles=20")
        return passed
    }

    @MainActor
    private func waitUntil(
        timeoutMilliseconds: Int = 1_000,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + Double(timeoutMilliseconds) / 1_000
        while !predicate() {
            guard CFAbsoluteTimeGetCurrent() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }

    private func log(event: String, details: String? = nil) {
        var message = "EVENT_TAP_FAULT_INJECTION mode=\(configuration.mode.rawValue) event=\(event)"
        if let details {
            message += " \(details)"
        }
        diagnosticLog(message)
    }
}
#endif
