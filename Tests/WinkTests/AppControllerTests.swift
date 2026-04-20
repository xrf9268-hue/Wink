import Foundation
import Testing
@testable import Wink

@Test @MainActor
func startupSequenceAppliesPersistedHyperStateBeforeStartingShortcutManager() {
    var events: [String] = []

    AppController.runStartupSequence(
        loadShortcuts: {
            events.append("load")
            return []
        },
        replaceShortcuts: { _ in
            events.append("replace")
        },
        reapplyHyperIfNeeded: {
            events.append("reapplyHyper")
        },
        isHyperEnabled: {
            events.append("readHyperEnabled")
            return true
        },
        setHyperKeyEnabled: { enabled in
            events.append("setHyper:\(enabled)")
        },
        startShortcutManager: {
            events.append("startShortcutManager")
        },
        installMenuBar: {
            events.append("installMenuBar")
        }
    )

    #expect(events == [
        "load",
        "replace",
        "reapplyHyper",
        "readHyperEnabled",
        "setHyper:true",
        "startShortcutManager",
        "installMenuBar"
    ])
}

@Test @MainActor
func consumeFirstLaunchFlagReturnsTrueOnceForFreshInstall() throws {
    let suiteName = "AppControllerTests.firstLaunch.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(AppController.consumeFirstLaunchFlag(userDefaults: defaults, hasExistingShortcuts: false) == true)
    #expect(AppController.consumeFirstLaunchFlag(userDefaults: defaults, hasExistingShortcuts: false) == false)
}

@Test @MainActor
func consumeFirstLaunchFlagSilentlyMarksMigratingUsersOnboarded() throws {
    let suiteName = "AppControllerTests.firstLaunch.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(AppController.consumeFirstLaunchFlag(userDefaults: defaults, hasExistingShortcuts: true) == false)
    #expect(AppController.consumeFirstLaunchFlag(userDefaults: defaults, hasExistingShortcuts: false) == false)
}
