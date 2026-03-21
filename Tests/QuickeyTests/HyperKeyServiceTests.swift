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
