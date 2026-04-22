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
