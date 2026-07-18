#if WINK_AX_WINDOW_OBSERVATION_FAULT_INJECTION
import AppKit
import Testing
@testable import Wink

@Suite("AX window observation fault injection")
struct AXWindowObservationFaultInjectionTests {
    @Test
    func configurationRequiresExactlyOneValidArgument() throws {
        #expect(AXWindowObservationFaultInjectionConfiguration(arguments: ["Wink"]) == nil)
        #expect(AXWindowObservationFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-ax-window-observation-fault=unknown:com.apple.Calculator",
        ]) == nil)
        #expect(AXWindowObservationFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-ax-window-observation-fault=deactivation-once:",
        ]) == nil)
        #expect(AXWindowObservationFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-ax-window-observation-fault=deactivation-once:com.apple.Calculator",
            "--validation-ax-window-observation-fault=deactivation-once:com.apple.TextEdit",
        ]) == nil)

        let configuration = try #require(AXWindowObservationFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-ax-window-observation-fault=deactivation-once:com.apple.Calculator",
        ]))
        #expect(configuration.mode == .deactivationOnce)
        #expect(configuration.targetBundleIdentifier == "com.apple.Calculator")

        let activationConfiguration = try #require(AXWindowObservationFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-ax-window-observation-fault=activation-persistent:com.apple.Calculator",
        ]))
        #expect(activationConfiguration.mode == .activationPersistent)
        #expect(activationConfiguration.targetBundleIdentifier == "com.apple.Calculator")
    }

    @Test @MainActor
    func driverSuppressesOneHideAndInjectsOneFailedReadOnlyAfterFrontmostLoss() throws {
        let app = try #require(NSWorkspace.shared.frontmostApplication)
        let bundleIdentifier = try #require(app.bundleIdentifier)
        let configuration = try #require(AXWindowObservationFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-ax-window-observation-fault=deactivation-once:\(bundleIdentifier)",
        ]))
        var frontmostBundleIdentifier: String? = bundleIdentifier
        var baseHideCalls = 0
        var baseObservationCalls = 0
        var logs: [String] = []
        let driver = AXWindowObservationFaultInjectionDriver(
            configuration: configuration,
            currentFrontmostBundleIdentifier: { frontmostBundleIdentifier },
            diagnosticLog: { logs.append($0) }
        )
        let baseObservation: (NSRunningApplication) -> ApplicationObservation.WindowObservation = { _ in
            baseObservationCalls += 1
            return ApplicationObservation.WindowObservation(
                windows: nil,
                visibleWindowCount: 1,
                hasFocusedWindow: true,
                hasMainWindow: true,
                windowsReadSucceeded: true,
                failureReason: nil
            )
        }

        let beforeHide = driver.windowObservation(for: app, base: baseObservation)
        #expect(beforeHide.windowsReadSucceeded == true)
        #expect(baseObservationCalls == 1)

        let suppressedResult = driver.hideApplication(app, base: { _ in
            baseHideCalls += 1
            return false
        })
        #expect(suppressedResult == true)
        #expect(baseHideCalls == 0)

        frontmostBundleIdentifier = "com.apple.finder"
        let injected = driver.windowObservation(for: app, base: baseObservation)
        #expect(injected.windowsReadSucceeded == false)
        #expect(injected.visibleWindowCount == 0)
        #expect(injected.failureReason == "validationInjectedAXWindowsReadFailure")
        #expect(baseObservationCalls == 1)

        let afterInjection = driver.windowObservation(for: app, base: baseObservation)
        #expect(afterInjection.windowsReadSucceeded == true)
        #expect(baseObservationCalls == 2)

        let forwardedResult = driver.hideApplication(app, base: { _ in
            baseHideCalls += 1
            return false
        })
        #expect(forwardedResult == false)
        #expect(baseHideCalls == 1)
        #expect(logs.contains { $0.contains("event=hide_suppressed") })
        #expect(logs.contains {
            $0.contains("event=window_read_failed") && $0.contains("windowsReadSucceeded=false")
        })
    }

    @Test @MainActor
    func activationPersistentModeWithholdsEveryMatchingObservationAndForwardsHide() throws {
        let app = try #require(NSWorkspace.shared.frontmostApplication)
        let bundleIdentifier = try #require(app.bundleIdentifier)
        let configuration = try #require(AXWindowObservationFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-ax-window-observation-fault=activation-persistent:\(bundleIdentifier)",
        ]))
        var baseObservationCalls = 0
        var baseHideCalls = 0
        var logs: [String] = []
        let driver = AXWindowObservationFaultInjectionDriver(
            configuration: configuration,
            currentFrontmostBundleIdentifier: { bundleIdentifier },
            diagnosticLog: { logs.append($0) }
        )
        let baseObservation: (NSRunningApplication) -> ApplicationObservation.WindowObservation = { _ in
            baseObservationCalls += 1
            return ApplicationObservation.WindowObservation(
                windows: nil,
                visibleWindowCount: 1,
                hasFocusedWindow: true,
                hasMainWindow: true,
                windowsReadSucceeded: true,
                failureReason: nil
            )
        }

        let first = driver.windowObservation(for: app, base: baseObservation)
        let second = driver.windowObservation(for: app, base: baseObservation)
        let hideResult = driver.hideApplication(app, base: { _ in
            baseHideCalls += 1
            return false
        })

        #expect(first.windowsReadSucceeded == false)
        #expect(first.failureReason == "validationInjectedActivationWindowEvidenceFailure")
        #expect(second.windowsReadSucceeded == false)
        #expect(second.failureReason == "validationInjectedActivationWindowEvidenceFailure")
        #expect(baseObservationCalls == 0)
        #expect(hideResult == false)
        #expect(baseHideCalls == 1)
        #expect(logs.contains { $0.contains("event=window_evidence_withheld") && $0.contains("ordinal=1") })
        #expect(logs.contains { $0.contains("event=window_evidence_withheld") && $0.contains("ordinal=2") })
    }

    @Test @MainActor
    func activationPersistentModeLeavesNonMatchingApplicationsOnBaseObservation() throws {
        let app = try #require(NSWorkspace.shared.frontmostApplication)
        let bundleIdentifier = try #require(app.bundleIdentifier)
        let configuration = try #require(AXWindowObservationFaultInjectionConfiguration(arguments: [
            "Wink",
            "--validation-ax-window-observation-fault=activation-persistent:com.example.different-target",
        ]))
        let driver = AXWindowObservationFaultInjectionDriver(
            configuration: configuration,
            currentFrontmostBundleIdentifier: { bundleIdentifier },
            diagnosticLog: { _ in }
        )
        var baseObservationCalls = 0

        let observation = driver.windowObservation(for: app, base: { _ in
            baseObservationCalls += 1
            return ApplicationObservation.WindowObservation(
                windows: nil,
                visibleWindowCount: 1,
                hasFocusedWindow: true,
                hasMainWindow: true,
                windowsReadSucceeded: true,
                failureReason: nil
            )
        })

        #expect(observation.windowsReadSucceeded == true)
        #expect(baseObservationCalls == 1)
    }
}
#endif
