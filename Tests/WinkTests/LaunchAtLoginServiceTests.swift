import Foundation
import ServiceManagement
import Testing
@testable import Wink

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
func diagnosticNameKeepsRequiresApprovalAndNotFoundDistinctFromDisabled() {
    // `.requiresApproval` and `.notFound` both read as `isEnabled == false`,
    // but a diagnostics report must not collapse them into the same
    // "disabled" string — they point a support conversation at different
    // fixes (approve the login item vs. reinstall/re-register it).
    #expect(LaunchAtLoginStatus.enabled.diagnosticName == "enabled")
    #expect(LaunchAtLoginStatus.requiresApproval.diagnosticName == "requires_approval")
    #expect(LaunchAtLoginStatus.disabled.diagnosticName == "disabled")
    #expect(LaunchAtLoginStatus.notFound.diagnosticName == "not_found")

    let allNames = Set([
        LaunchAtLoginStatus.enabled,
        .requiresApproval,
        .disabled,
        .notFound,
    ].map(\.diagnosticName))
    #expect(allNames.count == 4)
}

@Test
func notFoundOutsideApplicationsRequiresAppInstallation() {
    let service = LaunchAtLoginService(client: .init(
        status: { .notFound },
        register: {},
        unregister: {},
        openSystemSettingsLoginItems: {},
        bundleURL: { URL(fileURLWithPath: "/tmp/Wink.app") },
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
        bundleURL: { URL(fileURLWithPath: "/Applications/Wink.app") },
        applicationDirectories: {
            [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/Users/yvan/Applications", isDirectory: true),
            ]
        }
    ))

    #expect(service.snapshot.availability == LaunchAtLoginAvailability.missingConfiguration)
}

@Test
func setEnabledReturnsNilWhenMutationSucceeds() {
    let service = LaunchAtLoginService(client: .init(
        status: { .notRegistered },
        register: {},
        unregister: {},
        openSystemSettingsLoginItems: {}
    ))

    #expect(service.setEnabled(true) == nil)
    #expect(service.setEnabled(false) == nil)
}

@Test
func setEnabledReturnsRegisterFailureWhenRegisterThrows() {
    let service = LaunchAtLoginService(client: .init(
        status: { .notRegistered },
        register: { throw MutationTestError.registerFailed },
        unregister: {},
        openSystemSettingsLoginItems: {}
    ))

    #expect(service.setEnabled(true) == LaunchAtLoginMutationFailure(
        mutation: .register,
        reason: MutationTestError.registerFailed.localizedDescription
    ))
}

@Test
func setEnabledReturnsUnregisterFailureWhenUnregisterThrows() {
    let service = LaunchAtLoginService(client: .init(
        status: { .enabled },
        register: {},
        unregister: { throw MutationTestError.unregisterFailed },
        openSystemSettingsLoginItems: {}
    ))

    #expect(service.setEnabled(false) == LaunchAtLoginMutationFailure(
        mutation: .unregister,
        reason: MutationTestError.unregisterFailed.localizedDescription
    ))
}

private enum MutationTestError: LocalizedError {
    case registerFailed
    case unregisterFailed

    var errorDescription: String? {
        switch self {
        case .registerFailed: "register denied by policy"
        case .unregisterFailed: "unregister denied by policy"
        }
    }
}
