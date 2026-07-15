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
            == "System Settings > Input Monitoring can lag behind live access. If the affected shortcuts work here, Wink already has the permission it needs."
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

    #expect(status.bannerDetail == "Some shortcuts need Input Monitoring.")
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

    #expect(status.bannerDetail == "Input Monitoring is not required for the current shortcuts.")
    #expect(status.systemSettingsGuidance == nil)
}

@Test
func bannerDetailReportsAnInactiveHyperEventTapAfterPermissionIsGranted() {
    let status = ShortcutCaptureStatus(
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        inputMonitoringRequired: true,
        carbonHotKeysRegistered: false,
        eventTapActive: false,
        standardShortcutsReady: true,
        hyperShortcutsReady: false
    )

    #expect(
        status.bannerDetail
            == "Hyper shortcuts are configured, but shortcut capture is not active."
    )
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
