import AppKit
import Foundation
import Testing
@testable import Wink

@Test @MainActor
func startupSequenceAppliesPersistedHyperStateBeforeStartingShortcutManager() {
    var events: [String] = []

    AppController.runStartupSequence(
        startUpdateService: {
            events.append("startUpdateService")
        },
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
        "startUpdateService",
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

@Test @MainActor
func startupSequenceStartsUpdateServiceBeforeShortcutManager() {
    var events: [String] = []

    AppController.runStartupSequence(
        startUpdateService: {
            events.append("startUpdateService")
        },
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
            return false
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

    let startUpdateIndex = events.firstIndex(of: "startUpdateService")
    let startShortcutIndex = events.firstIndex(of: "startShortcutManager")

    #expect(startUpdateIndex != nil)
    #expect(startShortcutIndex != nil)
    #expect(startUpdateIndex! < startShortcutIndex!)
}

@Test @MainActor
func openPrimarySettingsWindowUsesInstalledSettingsLauncherHandler() throws {
    ensureAppKitApplication()

    let suiteName = "AppControllerTests.openPrimarySettingsWindow.installed.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let controller = AppController(userDefaults: defaults)
    var openCount = 0
    controller.settingsLauncherService.installOpenSettingsHandler {
        openCount += 1
    }

    controller.openPrimarySettingsWindow()

    #expect(openCount == 1)
}

@Test @MainActor
func openPrimarySettingsWindowQueuesPendingOpenUntilHandlerInstalls() throws {
    ensureAppKitApplication()

    let suiteName = "AppControllerTests.openPrimarySettingsWindow.pending.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let controller = AppController(userDefaults: defaults)

    controller.openPrimarySettingsWindow()

    var openCount = 0
    controller.settingsLauncherService.installOpenSettingsHandler {
        openCount += 1
    }

    #expect(openCount == 1)
}

@MainActor
private func ensureAppKitApplication() {
    _ = NSApplication.shared
}
