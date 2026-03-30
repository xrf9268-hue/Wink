import AppKit
import Carbon.HIToolbox
import Testing
@testable import Quickey

@Test @MainActor
func restoreContextCapturesGenerationAndPreviousBundle() {
    var psn = ProcessSerialNumber()
    psn.highLongOfPSN = 7
    psn.lowLongOfPSN = 9

    let context = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 42,
        previousPSNHint: psn,
        previousWindowIDHint: 314,
        previousBundleURL: URL(fileURLWithPath: "/Applications/Terminal.app"),
        capturedAt: 123.0,
        generation: 5
    )

    #expect(context.targetBundleIdentifier == "com.apple.Safari")
    #expect(context.previousBundleIdentifier == "com.apple.Terminal")
    #expect(context.previousPID == 42)
    #expect(context.previousPSNHint?.highLongOfPSN == 7)
    #expect(context.previousPSNHint?.lowLongOfPSN == 9)
    #expect(context.previousWindowIDHint == 314)
    #expect(context.previousBundleURL?.path == "/Applications/Terminal.app")
    #expect(context.capturedAt == 123.0)
    #expect(context.generation == 5)
}

@Test @MainActor
func toggleRuntimeConfigurationDefaultsToLegacyMode() {
    let configuration = ToggleRuntimeConfiguration()

    #expect(configuration.executionMode == .legacyOnly)
    #expect(configuration.fastConfirmationWindow == 0.075)
    #expect(configuration.contextPreparationConcurrencyLimit == 2)
    #expect(configuration.fastLaneMissThreshold == 3)
    #expect(configuration.fastLaneMissWindow == 600)
    #expect(configuration.temporaryCompatibilityWindow == 300)
}

@Test @MainActor
func shadowModeReturnsShadowDecisionWithLaneInfo() {
    let runtime = ToggleRuntime(
        configuration: ToggleRuntimeConfiguration(executionMode: .shadowMode)
    )

    let decision = runtime.decision(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        classification: .regularWindowed,
        attemptStartedAt: 100.0
    )

    if case .shadow(let shadowDecision) = decision {
        #expect(shadowDecision.selectedLane == "fast")
        #expect(shadowDecision.wouldUseHideTarget == false)
        #expect(shadowDecision.previousBundleIdentifier == "com.apple.Terminal")
    } else {
        Issue.record("Expected shadow decision, got \(decision)")
    }
}

@Test @MainActor
func shadowModeSelectsCompatibilityLaneWhenNoPreviousBundle() {
    let runtime = ToggleRuntime(
        configuration: ToggleRuntimeConfiguration(executionMode: .shadowMode)
    )

    let decision = runtime.decision(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: nil,
        classification: .regularWindowed,
        attemptStartedAt: 100.0
    )

    if case .shadow(let shadowDecision) = decision {
        #expect(shadowDecision.selectedLane == "compatibility")
        #expect(shadowDecision.wouldUseHideTarget == true)
        #expect(shadowDecision.previousBundleIdentifier == nil)
    } else {
        Issue.record("Expected shadow decision, got \(decision)")
    }
}

@Test @MainActor
func shadowModeSelectsCompatibilityLaneForNonRegularApp() {
    let runtime = ToggleRuntime(
        configuration: ToggleRuntimeConfiguration(executionMode: .shadowMode)
    )

    let decision = runtime.decision(
        targetBundleIdentifier: "com.apple.systempreferences",
        previousBundleIdentifier: "com.apple.Terminal",
        classification: .windowlessOrAccessory,
        attemptStartedAt: 100.0
    )

    if case .shadow(let shadowDecision) = decision {
        #expect(shadowDecision.selectedLane == "compatibility")
        #expect(shadowDecision.wouldUseHideTarget == true)
    } else {
        Issue.record("Expected shadow decision, got \(decision)")
    }
}

@Test @MainActor
func legacyModeReturnsUseLegacy() {
    let runtime = ToggleRuntime(
        configuration: ToggleRuntimeConfiguration(executionMode: .legacyOnly)
    )

    let decision = runtime.decision(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        classification: .regularWindowed,
        attemptStartedAt: 100.0
    )

    #expect(decision == .useLegacy)
}

@Test @MainActor
func runtimeInvariantsRejectSelfReferencingPreviousBundle() {
    #expect(
        normalizedPreviousBundle(
            targetBundleIdentifier: "com.apple.Safari",
            previousBundleIdentifier: "com.apple.Safari"
        ) == nil
    )
    #expect(
        normalizedPreviousBundle(
            targetBundleIdentifier: "com.apple.Safari",
            previousBundleIdentifier: "com.apple.Terminal"
        ) == "com.apple.Terminal"
    )
    #expect(
        normalizedPreviousBundle(
            targetBundleIdentifier: "com.apple.Safari",
            previousBundleIdentifier: nil
        ) == nil
    )
}
