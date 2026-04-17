import Foundation
import Testing
@testable import Quickey

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
