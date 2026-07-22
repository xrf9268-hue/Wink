import Foundation
import Testing
@testable import Wink

@Test @MainActor
func enableDoesNotPersistWhenHidutilFails() {
    let suiteName = "HyperKeyServiceTests.enable.failure"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let service = HyperKeyService(
        runner: { _ in false },
        defaults: defaults
    )

    service.enable()

    #expect(service.isEnabled == false)
}

@Test @MainActor
func disableDoesNotClearPersistedStateWhenHidutilFails() {
    let suiteName = "HyperKeyServiceTests.disable.failure"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "hyperKeyEnabled")

    let service = HyperKeyService(
        runner: { _ in false },
        defaults: defaults
    )

    service.disable()

    #expect(service.isEnabled == true)
}

@Test @MainActor
func reapplyFailurePreservesPreferenceButReportsMappingUnavailable() {
    let suiteName = "HyperKeyServiceTests.reapply.failure"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "hyperKeyEnabled")

    let service = HyperKeyService(
        runner: { _ in false },
        defaults: defaults
    )

    let didApply = service.reapplyIfNeeded()

    #expect(didApply == false)
    #expect(service.isEnabled == true)
}

@Test @MainActor
func disableRestoresCapsLockDelayOverrideDefault() {
    let suiteName = "HyperKeyServiceTests.disable.capsLockDelay"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "hyperKeyEnabled")

    let recorder = HidutilRunnerRecorder(returns: true)
    let service = HyperKeyService(
        runner: recorder.run,
        defaults: defaults
    )

    service.disable()

    #expect(service.isEnabled == false)
    #expect(recorder.invocations.count == 1)
    let args = recorder.invocations.first ?? []
    #expect(args.prefix(2) == ["property", "--set"])
    let json = args.last ?? ""
    // Without this reset, applyMapping's CapsLockDelayOverride=0 would leak
    // into system-wide Caps Lock behavior until reboot.
    #expect(json.contains("\"CapsLockDelayOverride\":100"))
    #expect(json.contains("\"UserKeyMapping\":[]"))
}

private final class HidutilRunnerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let returnValue: Bool
    private var _invocations: [[String]] = []

    init(returns: Bool) {
        self.returnValue = returns
    }

    var invocations: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _invocations
    }

    func run(_ arguments: [String]) -> Bool {
        lock.lock()
        _invocations.append(arguments)
        lock.unlock()
        return returnValue
    }
}

// MARK: - Pause suspension (#375)

@Test @MainActor
func suspendClearsMappingAndResumeRestoresItWithoutTouchingPersistence() {
    let suiteName = "HyperKeyServiceTests.suspend.roundTrip"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "hyperKeyEnabled")

    let recorder = HidutilRunnerRecorder(returns: true)
    let service = HyperKeyService(runner: recorder.run, defaults: defaults)

    service.suspendMappingForPause()
    #expect(service.isSuspended == true)
    #expect(service.isEnabled == true, "suspension must never touch the persisted bit")
    #expect(recorder.invocations.count == 1)
    #expect(recorder.invocations.first?.last?.contains("\"UserKeyMapping\":[]") == true)
    #expect(recorder.invocations.first?.last?.contains("\"CapsLockDelayOverride\":100") == true)

    // Idempotent while suspended.
    service.suspendMappingForPause()
    #expect(recorder.invocations.count == 1)

    service.resumeMappingAfterPause()
    #expect(service.isSuspended == false)
    #expect(recorder.invocations.count == 2)
    #expect(recorder.invocations.last?.last?.contains("HIDKeyboardModifierMappingSrc") == true)
}

@Test @MainActor
func suspendIsANoOpWhenHyperIsDisabled() {
    let suiteName = "HyperKeyServiceTests.suspend.disabled"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let recorder = HidutilRunnerRecorder(returns: true)
    let service = HyperKeyService(runner: recorder.run, defaults: defaults)

    service.suspendMappingForPause()
    service.resumeMappingAfterPause()

    #expect(recorder.invocations.isEmpty, "no mapping exists to lift or restore")
}

@Test @MainActor
func reapplyDuringSuspensionDoesNotUndoTheSuspension() {
    // Launching into a persisted pause suspends during AppPreferences init,
    // BEFORE the startup sequence's reapplyIfNeeded runs; re-applying there
    // would hand the paused foreground app a consumer-less F19 again.
    let suiteName = "HyperKeyServiceTests.suspend.reapply"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "hyperKeyEnabled")

    let recorder = HidutilRunnerRecorder(returns: true)
    let service = HyperKeyService(runner: recorder.run, defaults: defaults)

    service.suspendMappingForPause()
    let applied = service.reapplyIfNeeded()

    #expect(applied == false)
    #expect(recorder.invocations.count == 1, "only the suspension's clear may run")
    #expect(service.isSuspended == true)
}

@Test @MainActor
func enableDuringSuspensionDefersTheMappingToResume() {
    let suiteName = "HyperKeyServiceTests.suspend.enable"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "hyperKeyEnabled")

    let recorder = HidutilRunnerRecorder(returns: true)
    let service = HyperKeyService(runner: recorder.run, defaults: defaults)

    service.suspendMappingForPause()
    service.enable()

    #expect(service.isEnabled == true)
    #expect(recorder.invocations.count == 1, "enable during a pause must not apply the mapping yet")

    service.resumeMappingAfterPause()
    #expect(recorder.invocations.count == 2)
    #expect(recorder.invocations.last?.last?.contains("HIDKeyboardModifierMappingSrc") == true)
}

@Test @MainActor
func disableDuringSuspensionClearsTheSuspendedFlag() {
    let suiteName = "HyperKeyServiceTests.suspend.disable"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "hyperKeyEnabled")

    let recorder = HidutilRunnerRecorder(returns: true)
    let service = HyperKeyService(runner: recorder.run, defaults: defaults)

    service.suspendMappingForPause()
    service.disable()

    #expect(service.isEnabled == false)
    #expect(service.isSuspended == false)

    // A later resume must not resurrect the mapping the user disabled.
    service.resumeMappingAfterPause()
    #expect(recorder.invocations.count == 2, "suspend clear + disable clear only")
}
