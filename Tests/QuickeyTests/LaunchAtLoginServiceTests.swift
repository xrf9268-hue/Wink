import ServiceManagement
import Testing
@testable import Quickey

@Test
func requiresApprovalMapsToApprovalNeededState() {
    let service = LaunchAtLoginService(client: .init(
        status: { .requiresApproval },
        register: {},
        unregister: {},
        openSystemSettingsLoginItems: {}
    ))

    #expect(service.status == LaunchAtLoginStatus.requiresApproval)
}

@Test
func requiresApprovalIsNotTreatedAsFullyEnabled() {
    #expect(LaunchAtLoginStatus.requiresApproval.isEnabled == false)
}

@Test
func notFoundOutsideApplicationsRequiresAppInstallation() {
    let service = LaunchAtLoginService(client: .init(
        status: { .notFound },
        register: {},
        unregister: {},
        openSystemSettingsLoginItems: {},
        bundleURL: { URL(fileURLWithPath: "/Users/yvan/developer/Quickey/build/Quickey.app") },
        applicationDirectories: {
            [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/Users/yvan/Applications", isDirectory: true),
            ]
        }
    ))

    #expect(service.snapshot.status == LaunchAtLoginStatus.notFound)
    #expect(service.snapshot.availability == LaunchAtLoginAvailability.requiresAppInApplicationsFolder)
}

@Test
func notFoundInsideApplicationsStaysConfigurationMissing() {
    let service = LaunchAtLoginService(client: .init(
        status: { .notFound },
        register: {},
        unregister: {},
        openSystemSettingsLoginItems: {},
        bundleURL: { URL(fileURLWithPath: "/Applications/Quickey.app") },
        applicationDirectories: {
            [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/Users/yvan/Applications", isDirectory: true),
            ]
        }
    ))

    #expect(service.snapshot.availability == LaunchAtLoginAvailability.missingConfiguration)
}
