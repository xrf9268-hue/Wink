import Testing
@testable import Wink

@Test
func bannerDetailMentionsSystemSettingsLagWhenHyperCaptureIsActive() {
    let status = ShortcutCaptureStatus(
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        inputMonitoringRequired: true,
        carbonHotKeysRegistered: true,
        eventTapActive: true,
        standardShortcutsReady: true,
        hyperShortcutsReady: true
    )

    #expect(status.bannerDetail == "Standard and Hyper shortcuts are active.")
    #expect(
        status.systemSettingsGuidance
            == "System Settings > Input Monitoring can lag behind live access. If Hyper shortcuts work here, Quickey already has the permission it needs."
    )
}

@Test
func bannerDetailKeepsMissingInputMonitoringWarningWithoutGuidance() {
    let status = ShortcutCaptureStatus(
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        inputMonitoringRequired: true,
        carbonHotKeysRegistered: false,
        eventTapActive: false,
        standardShortcutsReady: true,
        hyperShortcutsReady: false
    )

    #expect(status.bannerDetail == "Hyper shortcuts need Input Monitoring.")
    #expect(status.systemSettingsGuidance == nil)
}

@Test
func bannerDetailForStandardOnlyCaptureHasNoSystemSettingsGuidance() {
    let status = ShortcutCaptureStatus(
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        inputMonitoringRequired: false,
        carbonHotKeysRegistered: true,
        eventTapActive: false,
        standardShortcutsReady: true,
        hyperShortcutsReady: true
    )

    #expect(status.bannerDetail == "Input Monitoring is only required for Hyper shortcuts.")
    #expect(status.systemSettingsGuidance == nil)
}

@Test
func systemSettingsGuidanceIsSuppressedWhenStandardRegistrationWarningIsPresent() {
    let status = ShortcutCaptureStatus(
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        inputMonitoringRequired: true,
        carbonHotKeysRegistered: false,
        eventTapActive: true,
        standardShortcutsReady: false,
        hyperShortcutsReady: true,
        standardShortcutCount: 2,
        registeredStandardShortcutCount: 1
    )

    #expect(status.bannerDetail == "1 standard shortcut binding failed to register. Check logs for the blocked key combination.")
    #expect(status.systemSettingsGuidance == nil)
}
