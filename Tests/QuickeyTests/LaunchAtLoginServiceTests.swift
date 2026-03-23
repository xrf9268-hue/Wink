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

    #expect(service.status == .requiresApproval)
}

@Test
func requiresApprovalIsNotTreatedAsFullyEnabled() {
    #expect(LaunchAtLoginStatus.requiresApproval.isEnabled == false)
}
