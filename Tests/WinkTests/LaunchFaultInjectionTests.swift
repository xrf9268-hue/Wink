#if WINK_LAUNCH_FAULT_INJECTION
import AppKit
import Testing
@testable import Wink

@Suite("Launch fault injection")
struct LaunchFaultInjectionTests {
    @Test
    func configurationRequiresAnExactValidationArgument() {
        #expect(LaunchFaultInjectionConfiguration(arguments: ["Wink"]) == nil)
        #expect(LaunchFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-launch-fault=unknown:com.apple.TextEdit"
        ]) == nil)
        #expect(LaunchFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-launch-fault=stale-error:"
        ]) == nil)
        #expect(LaunchFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-launch-fault=stale-error:com.apple.TextEdit",
            "--validation-launch-fault=current-error-once:com.apple.TextEdit"
        ]) == nil)

        let stale = LaunchFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-launch-fault=stale-error:com.apple.TextEdit"
        ])
        #expect(stale?.mode == .staleError)
        #expect(stale?.targetBundleIdentifier == "com.apple.TextEdit")

        let current = LaunchFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-launch-fault=current-error-once:com.apple.TextEdit"
        ])
        #expect(current?.mode == .currentErrorOnce)
        #expect(current?.targetBundleIdentifier == "com.apple.TextEdit")
    }

    @Test @MainActor
    func staleErrorModeDeliversHeldFirstErrorAfterSecondRequestSupersedesIt() {
        let targetURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let configuration = LaunchFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-launch-fault=stale-error:com.apple.TextEdit"
        ])!
        let workspaceCompletions = LockedValue<[@Sendable (NSRunningApplication?, Error?) -> Void]>([])
        let downstreamEvents = LockedValue<[String]>([])
        let diagnostics = LockedValue<[String]>([])
        let injector = LaunchFaultInjector(
            configuration: configuration,
            workspaceOpen: { _, _, completion in
                workspaceCompletions.value.append(completion)
            },
            diagnosticLog: { diagnostics.value.append($0) }
        )
        let client = injector.client

        client.openApplication(targetURL, .init()) { _, error in
            downstreamEvents.value.append(error == nil ? "first-success" : "first-error")
        }
        #expect(workspaceCompletions.value.isEmpty)

        client.openApplication(targetURL, .init()) { _, error in
            downstreamEvents.value.append(error == nil ? "second-success" : "second-error")
        }
        #expect(workspaceCompletions.value.count == 1)
        #expect(downstreamEvents.value == ["first-error"])

        workspaceCompletions.value[0](NSRunningApplication.current, nil)

        #expect(downstreamEvents.value == ["first-error", "second-success"])
        #expect(diagnostics.value.contains { $0.contains("event=first_request_held") })
        #expect(diagnostics.value.contains { $0.contains("event=second_success_delivered") })
        #expect(diagnostics.value.contains { $0.contains("event=stale_error_delivered") })
    }

    @Test @MainActor
    func currentErrorOnceModeFailsOnlyTheFirstMatchingRequest() {
        let targetURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let configuration = LaunchFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-launch-fault=current-error-once:com.apple.TextEdit"
        ])!
        let workspaceCompletions = LockedValue<[@Sendable (NSRunningApplication?, Error?) -> Void]>([])
        let downstreamEvents = LockedValue<[String]>([])
        let diagnostics = LockedValue<[String]>([])
        let injector = LaunchFaultInjector(
            configuration: configuration,
            workspaceOpen: { _, _, completion in
                workspaceCompletions.value.append(completion)
            },
            diagnosticLog: { diagnostics.value.append($0) }
        )
        let client = injector.client

        client.openApplication(targetURL, .init()) { _, error in
            downstreamEvents.value.append(error == nil ? "first-success" : "first-error")
        }
        #expect(downstreamEvents.value == ["first-error"])
        #expect(workspaceCompletions.value.isEmpty)

        client.openApplication(targetURL, .init()) { _, error in
            downstreamEvents.value.append(error == nil ? "second-success" : "second-error")
        }
        #expect(workspaceCompletions.value.count == 1)
        workspaceCompletions.value[0](NSRunningApplication.current, nil)

        #expect(downstreamEvents.value == ["first-error", "second-success"])
        #expect(diagnostics.value.contains { $0.contains("event=current_error_delivered") })
        #expect(diagnostics.value.contains { $0.contains("event=passthrough_after_injection") })
    }
}
#endif
