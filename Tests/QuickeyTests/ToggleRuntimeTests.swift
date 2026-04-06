import AppKit
import Testing
@testable import Quickey

@Test @MainActor
func restoreContextCapturesGenerationAndPreviousBundle() {
    let context = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 42,
        previousBundleURL: URL(fileURLWithPath: "/Applications/Terminal.app"),
        capturedAt: 123.0,
        generation: 5
    )

    #expect(context.targetBundleIdentifier == "com.apple.Safari")
    #expect(context.previousBundleIdentifier == "com.apple.Terminal")
    #expect(context.previousPID == 42)
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

// MARK: - Pipeline mode

@Test @MainActor
func pipelineEnabledSelectsFastLaneForEligibleRegularApp() {
    let runtime = ToggleRuntime(
        configuration: ToggleRuntimeConfiguration(executionMode: .pipelineEnabled)
    )

    let decision = runtime.decision(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        classification: .regularWindowed,
        attemptStartedAt: 100.0
    )

    if case .execute(.fastLane(let context)) = decision {
        #expect(context.targetBundleIdentifier == "com.apple.Safari")
        #expect(context.previousBundleIdentifier == "com.apple.Terminal")
    } else {
        Issue.record("Expected fastLane decision, got \(decision)")
    }
}

@Test @MainActor
func pipelineEnabledSelectsCompatibilityLaneWhenNoPreviousBundle() {
    let runtime = ToggleRuntime(
        configuration: ToggleRuntimeConfiguration(executionMode: .pipelineEnabled)
    )

    let decision = runtime.decision(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: nil,
        classification: .regularWindowed,
        attemptStartedAt: 100.0
    )

    if case .execute(.compatibilityLane) = decision {
        // expected
    } else {
        Issue.record("Expected compatibilityLane decision, got \(decision)")
    }
}

@Test @MainActor
func pipelineEnabledSelectsCompatibilityLaneForNonRegularApp() {
    let runtime = ToggleRuntime(
        configuration: ToggleRuntimeConfiguration(executionMode: .pipelineEnabled)
    )

    let decision = runtime.decision(
        targetBundleIdentifier: "com.apple.systempreferences",
        previousBundleIdentifier: "com.apple.Terminal",
        classification: .systemUtility,
        attemptStartedAt: 100.0
    )

    if case .execute(.compatibilityLane) = decision {
        // expected
    } else {
        Issue.record("Expected compatibilityLane decision, got \(decision)")
    }
}

@Test @MainActor
func pipelineEnabledRespectsQuarantinedCacheEntry() {
    let cache = TapContextCache()
    let runtime = ToggleRuntime(
        configuration: ToggleRuntimeConfiguration(executionMode: .pipelineEnabled),
        tapContextCache: cache
    )

    // Set up a cache entry then quarantine it
    let restoreContext = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 42,
        previousBundleURL: nil,
        capturedAt: 100,
        generation: 1
    )
    cache.upsert(
        targetBundleIdentifier: "com.apple.Safari",
        coordinatorPreviousBundle: "com.apple.Terminal",
        restoreContext: restoreContext
    )
    // 3 misses → quarantine
    for t in stride(from: 100.0, through: 140.0, by: 20.0) {
        cache.markFastLaneMiss(for: "com.apple.Safari", now: t, threshold: 3, window: 600, quarantine: 300)
    }

    let decision = runtime.decision(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        classification: .regularWindowed,
        attemptStartedAt: 141.0
    )

    if case .execute(.compatibilityLane) = decision {
        // expected: quarantined, so not fast-lane eligible
    } else {
        Issue.record("Expected compatibilityLane for quarantined app, got \(decision)")
    }
}

@Test @MainActor
func pipelineEnabledRecoversFastLaneAfterQuarantineExpires() {
    let cache = TapContextCache()
    let runtime = ToggleRuntime(
        configuration: ToggleRuntimeConfiguration(executionMode: .pipelineEnabled),
        tapContextCache: cache
    )

    let restoreContext = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 42,
        previousBundleURL: nil,
        capturedAt: 100,
        generation: 1
    )
    cache.upsert(
        targetBundleIdentifier: "com.apple.Safari",
        coordinatorPreviousBundle: "com.apple.Terminal",
        restoreContext: restoreContext
    )
    for t in stride(from: 100.0, through: 140.0, by: 20.0) {
        cache.markFastLaneMiss(for: "com.apple.Safari", now: t, threshold: 3, window: 600, quarantine: 300)
    }

    // After quarantine expires (140 + 300 = 440)
    let decision = runtime.decision(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        classification: .regularWindowed,
        attemptStartedAt: 441.0
    )

    if case .execute(.fastLane) = decision {
        // expected: quarantine expired, fast lane recovered
    } else {
        Issue.record("Expected fastLane after quarantine expired, got \(decision)")
    }
}

@Test @MainActor
func pipelineEnabledDropsStaleHintsWhenPreviousBundleChanges() {
    let cache = TapContextCache()
    let runtime = ToggleRuntime(
        configuration: ToggleRuntimeConfiguration(executionMode: .pipelineEnabled),
        tapContextCache: cache
    )

    // Cache entry has Terminal as previous with specific PID/URL hints
    let cachedContext = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 100,
        previousBundleURL: URL(fileURLWithPath: "/Applications/Terminal.app"),
        capturedAt: 50,
        generation: 1
    )
    cache.upsert(
        targetBundleIdentifier: "com.apple.Safari",
        coordinatorPreviousBundle: "com.apple.Terminal",
        restoreContext: cachedContext
    )

    // Now call with a DIFFERENT previous bundle (Finder instead of Terminal)
    let decision = runtime.decision(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Finder",
        classification: .regularWindowed,
        attemptStartedAt: 100.0
    )

    if case .execute(.fastLane(let context)) = decision {
        #expect(context.previousBundleIdentifier == "com.apple.Finder")
        // Hints from Terminal cache entry must NOT leak into Finder context
        #expect(context.previousPID == nil)
        #expect(context.previousBundleURL == nil)
    } else {
        Issue.record("Expected fastLane decision, got \(decision)")
    }
}

@Test @MainActor
func pipelineEnabledKeepsHintsWhenPreviousBundleMatches() {
    let cache = TapContextCache()
    let runtime = ToggleRuntime(
        configuration: ToggleRuntimeConfiguration(executionMode: .pipelineEnabled),
        tapContextCache: cache
    )

    let cachedContext = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 100,
        previousBundleURL: URL(fileURLWithPath: "/Applications/Terminal.app"),
        capturedAt: 50,
        generation: 1
    )
    cache.upsert(
        targetBundleIdentifier: "com.apple.Safari",
        coordinatorPreviousBundle: "com.apple.Terminal",
        restoreContext: cachedContext
    )

    // Same previous bundle as cached — hints should be preserved
    let decision = runtime.decision(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        classification: .regularWindowed,
        attemptStartedAt: 100.0
    )

    if case .execute(.fastLane(let context)) = decision {
        #expect(context.previousBundleIdentifier == "com.apple.Terminal")
        #expect(context.previousPID == 100)
        #expect(context.previousBundleURL?.path == "/Applications/Terminal.app")
    } else {
        Issue.record("Expected fastLane decision, got \(decision)")
    }
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
