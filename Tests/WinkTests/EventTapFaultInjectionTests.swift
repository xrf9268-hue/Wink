#if WINK_EVENT_TAP_FAULT_INJECTION
import AppKit
import Foundation
import Testing
@testable import Wink

@Suite("EventTap fault injection")
struct EventTapFaultInjectionTests {
    @Test
    func configurationRequiresOneExactValidationArgument() {
        #expect(EventTapFaultInjectionConfiguration(arguments: ["Wink"]) == nil)
        #expect(EventTapFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-event-tap-fault=unknown"
        ]) == nil)
        #expect(EventTapFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-event-tap-fault=replacement-tap-once",
            "--validation-event-tap-fault=cycle20"
        ]) == nil)

        let tap = EventTapFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-event-tap-fault=replacement-tap-once"
        ])
        #expect(tap?.mode == .replacementTapOnce)

        let source = EventTapFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-event-tap-fault=replacement-source-until-degraded"
        ])
        #expect(source?.mode == .replacementSourceUntilDegraded)

        let cycle = EventTapFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-event-tap-fault=cycle20"
        ])
        #expect(cycle?.mode == .cycle20)
    }

    @Test @MainActor
    func replacementTapModeFailsOnceThenRecoversOnTheSameThread() async {
        let runtime = FaultInjectionTestRuntime()
        let diagnostics = LockedValue<[String]>([])
        let configuration = EventTapFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-event-tap-fault=replacement-tap-once"
        ])!
        let driver = EventTapFaultInjectionDriver(
            configuration: configuration,
            baseRuntimeFactory: runtime.factory,
            diagnosticLog: { diagnostics.value.append($0) }
        )
        let manager = EventTapManager(runtimeFactory: driver.runtimeFactory)

        #expect(manager.start { _ in true } == .started)
        let originalThreadID = manager.ownershipSnapshot.threadID
        let passed = await driver.runScenario(manager: manager) { _ in true }

        #expect(passed)
        #expect(manager.lifecycleState == .running)
        #expect(manager.isRunning)
        #expect(manager.ownershipSnapshot.ownerCount == 1)
        #expect(manager.ownershipSnapshot.threadID == originalThreadID)
        #expect(diagnostics.value.contains {
            $0.contains("mode=replacement-tap-once") && $0.contains("event=scenario_complete")
        })
        manager.stop()
    }

    @Test @MainActor
    func replacementSourceModeReachesDegradedWithNoOwnedResources() async {
        let runtime = FaultInjectionTestRuntime()
        let diagnostics = LockedValue<[String]>([])
        let configuration = EventTapFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-event-tap-fault=replacement-source-until-degraded"
        ])!
        let driver = EventTapFaultInjectionDriver(
            configuration: configuration,
            baseRuntimeFactory: runtime.factory,
            diagnosticLog: { diagnostics.value.append($0) }
        )
        let manager = EventTapManager(runtimeFactory: driver.runtimeFactory)

        #expect(manager.start { _ in true } == .started)
        manager.setHyperKeyEnabled(true)
        let passed = await driver.runScenario(manager: manager) { _ in true }
        let degraded = manager.ownershipSnapshot

        #expect(passed)
        #expect(manager.lifecycleState == .degraded)
        #expect(manager.isRunning == false)
        #expect(degraded.ownerCount == 0)
        #expect(degraded.tapCreates == degraded.tapReleases)
        #expect(degraded.sourceCreates == degraded.sourceReleases)
        #expect(degraded.boxCreates == degraded.boxReleases)
        #expect(degraded.threadCreates == degraded.threadReleases)
        #expect(diagnostics.value.contains {
            $0.contains("mode=replacement-source-until-degraded") && $0.contains("event=scenario_complete")
        })
    }

    @Test @MainActor
    func cycle20ModeReleasesEveryGenerationAndRejectsStoppedCallbacks() async {
        let runtime = FaultInjectionTestRuntime()
        let diagnostics = LockedValue<[String]>([])
        let configuration = EventTapFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-event-tap-fault=cycle20"
        ])!
        let driver = EventTapFaultInjectionDriver(
            configuration: configuration,
            baseRuntimeFactory: runtime.factory,
            diagnosticLog: { diagnostics.value.append($0) }
        )
        let manager = EventTapManager(runtimeFactory: driver.runtimeFactory)

        #expect(manager.start { _ in true } == .started)
        manager.setHyperKeyEnabled(true)
        let passed = await driver.runScenario(manager: manager) { _ in true }
        let final = manager.ownershipSnapshot

        #expect(passed)
        #expect(final.lifecycleState == .stopped)
        #expect(final.ownerCount == 0)
        #expect(final.tapCreates == final.tapReleases)
        #expect(final.sourceCreates == final.sourceReleases)
        #expect(final.boxCreates == final.boxReleases)
        #expect(final.threadCreates == final.threadReleases)
        #expect(final.keyCallbackDeliveries == 0)
        #expect(final.staleCallbacksDiscarded == 40)
        #expect(diagnostics.value.filter { $0.contains("event=cycle_complete") }.count == 20)
        #expect(diagnostics.value.contains {
            $0.contains("mode=cycle20") && $0.contains("event=scenario_complete")
        })
    }
}

@MainActor
private final class FaultInjectionTestRuntime {
    private(set) var threads: [FaultInjectionTestThread] = []

    lazy var factory = EventTapRuntimeFactory(
        makeThread: { [unowned self] generation in
            let thread = FaultInjectionTestThread(generation: generation)
            threads.append(thread)
            return thread
        },
        makeTap: { _, _, _, _ in makeFaultInjectionTestingMachPort() },
        makeSource: { _, tap in
            CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        },
        setTapEnabled: { _, _ in },
        invalidateTap: { CFMachPortInvalidate($0) },
        now: { CFAbsoluteTimeGetCurrent() }
    )
}

private final class FaultInjectionTestThread: EventTapRunLoopThread {
    let identity: String
    let threadID: UInt64?
    private(set) var hasExited = false
    private(set) var isAlive = false

    init(generation: UInt64) {
        identity = "fault-injection-test-\(generation)"
        threadID = generation
    }

    func start() { isAlive = true }
    func addSource(_ source: CFRunLoopSource) {}
    func removeSource(_ source: CFRunLoopSource) {}
    func cancelAndWait() {
        isAlive = false
        hasExited = true
    }
}

private func makeFaultInjectionTestingMachPort() -> CFMachPort {
    var context = CFMachPortContext(
        version: 0,
        info: nil,
        retain: nil,
        release: nil,
        copyDescription: nil
    )
    return CFMachPortCreate(kCFAllocatorDefault, nil, &context, nil)!
}
#endif
