import Foundation
import Testing
@testable import Wink

@Test @MainActor
func settingsLauncherPersistsSelectedTabAndReplaysPendingOpen() {
    let suiteName = "SettingsLauncherTests.pending.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let launcher = SettingsLauncher(userDefaults: defaults)
    var openCount = 0

    launcher.open(tab: .insights)
    #expect(defaults.string(forKey: SettingsLauncher.selectedTabDefaultsKey) == SettingsTab.insights.rawValue)

    launcher.installOpenSettingsHandler {
        openCount += 1
    }

    #expect(openCount == 1)
    #expect(launcher.selectedTab == .insights)
}

@Test @MainActor
func settingsLauncherUsesInstalledHandlerImmediately() {
    let suiteName = "SettingsLauncherTests.immediate.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let launcher = SettingsLauncher(userDefaults: defaults)
    var openCount = 0
    launcher.installOpenSettingsHandler {
        openCount += 1
    }

    launcher.open(tab: .general)

    #expect(openCount == 1)
    #expect(launcher.selectedTab == .general)
}

@Test @MainActor
func settingsLauncherImmediateOpenDoesNotQueueOrMutateWhenHandlerIsMissing() {
    let suiteName = "SettingsLauncherTests.noqueue.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let launcher = SettingsLauncher(userDefaults: defaults)
    var openCount = 0

    #expect(!launcher.openIfReady(tab: .insights))
    #expect(launcher.selectedTab == .shortcuts)

    launcher.installOpenSettingsHandler {
        openCount += 1
    }

    #expect(openCount == 0)
}

@Test @MainActor
func settingsLauncherWaitsForAnObservedVisibleWindow() async throws {
    let suiteName = "SettingsLauncherTests.visibility.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let launcher = SettingsLauncher(userDefaults: defaults)
    var observationCount = 0
    launcher.installSettingsPresentationObserver {
        observationCount += 1
        return observationCount >= 2
    }
    let appeared = try await launcher.waitForSettingsPresentation(
        timeout: .milliseconds(200),
        pollInterval: .milliseconds(5)
    )

    #expect(appeared)
    #expect(observationCount == 2)
}

@Test @MainActor
func settingsLauncherTimesOutWhenNoVisibleWindowIsObserved() async throws {
    let suiteName = "SettingsLauncherTests.timeout.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let launcher = SettingsLauncher(userDefaults: defaults)
    launcher.installSettingsPresentationObserver { false }

    let appeared = try await launcher.waitForSettingsPresentation(
        timeout: .milliseconds(20),
        pollInterval: .milliseconds(5)
    )

    #expect(!appeared)
}
