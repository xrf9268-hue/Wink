import Testing
@testable import Wink

@Test
func menuBarLaunchAtLoginPresentation_mapsEnabledToCheckedToggleOffAction() {
    let presentation = MenuBarLaunchAtLoginPresentation(
        snapshot: LaunchAtLoginSnapshot(status: .enabled, availability: .available)
    )

    #expect(presentation.title == "Launch at Login")
    #expect(presentation.state == .on)
    #expect(presentation.isEnabled == true)
    #expect(presentation.action == .disable)
}

@Test
func menuBarLaunchAtLoginPresentation_mapsRequiresApprovalToMixedOpenSettingsAction() {
    let presentation = MenuBarLaunchAtLoginPresentation(
        snapshot: LaunchAtLoginSnapshot(status: .requiresApproval, availability: .available)
    )

    #expect(presentation.title == "Approve Launch at Login...")
    #expect(presentation.state == .mixed)
    #expect(presentation.isEnabled == true)
    #expect(presentation.action == .openLoginItemsSettings)
}

@Test
func menuBarLaunchAtLoginPresentation_mapsNotFoundOutsideApplicationsToInstallGuidanceTitle() {
    let presentation = MenuBarLaunchAtLoginPresentation(
        snapshot: LaunchAtLoginSnapshot(
            status: .notFound,
            availability: .requiresAppInApplicationsFolder
        )
    )

    #expect(presentation.title == "Launch at Login (Move App to Applications)")
    #expect(presentation.state == .off)
    #expect(presentation.isEnabled == false)
    #expect(presentation.action == .unavailable)
}

@Test
func menuBarLaunchAtLoginPresentation_mapsNotFoundInsideApplicationsToConfigurationErrorTitle() {
    let presentation = MenuBarLaunchAtLoginPresentation(
        snapshot: LaunchAtLoginSnapshot(
            status: .notFound,
            availability: .missingConfiguration
        )
    )

    #expect(presentation.title == "Launch at Login (Configuration Missing)")
    #expect(presentation.state == .off)
    #expect(presentation.isEnabled == false)
    #expect(presentation.action == .unavailable)
}
