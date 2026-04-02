import CoreFoundation
import Testing
@testable import Quickey

// MARK: - Cheap confirmation

@Test @MainActor
func cheapConfirmationSucceedsFromFrontmostChangeWithoutEscalation() {
    let broker = ObservationBroker(client: .init(
        frontmostBundleIdentifier: { "com.apple.Terminal" },
        targetIsHidden: { false },
        targetIsActive: { false },
        targetClassification: { .regularWindowed },
        escalatedSnapshot: { fatalError("should not escalate") },
        now: { 100 },
        pollOnce: { _ in }
    ))

    let result = broker.confirmFastRestore(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal"
    )

    #expect(result.confirmed == true)
    #expect(result.usedEscalatedObservation == false)
    #expect(result.frontmostBundleAfterRestore == "com.apple.Terminal")
}

@Test @MainActor
func cheapConfirmationTimesOutWhenTargetRemainsFrontmost() {
    var time: CFAbsoluteTime = 100.0
    let broker = ObservationBroker(client: .init(
        frontmostBundleIdentifier: { "com.apple.Safari" },
        targetIsHidden: { false },
        targetIsActive: { true },
        targetClassification: { .regularWindowed },
        escalatedSnapshot: { fatalError("should not escalate") },
        now: { time },
        pollOnce: { interval in time += interval }
    ))

    let result = broker.confirmFastRestore(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal"
    )

    #expect(result.confirmed == false)
    #expect(result.usedEscalatedObservation == false)
    #expect(result.frontmostBundleAfterRestore == "com.apple.Safari")
}

@Test @MainActor
func cheapConfirmationSucceedsDuringPollingWindow() {
    var time: CFAbsoluteTime = 100.0
    var pollCount = 0
    let broker = ObservationBroker(client: .init(
        frontmostBundleIdentifier: {
            // After 3 polls, frontmost changes
            pollCount > 3 ? "com.apple.Terminal" : "com.apple.Safari"
        },
        targetIsHidden: { false },
        targetIsActive: { pollCount <= 3 },
        targetClassification: { .regularWindowed },
        escalatedSnapshot: { fatalError("should not escalate") },
        now: { time },
        pollOnce: { interval in
            time += interval
            pollCount += 1
        }
    ))

    let result = broker.confirmFastRestore(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal"
    )

    #expect(result.confirmed == true)
    #expect(result.usedEscalatedObservation == false)
    #expect(result.frontmostBundleAfterRestore == "com.apple.Terminal")
    #expect(pollCount == 4)
}

// MARK: - Contradiction escalation

@Test @MainActor
func contradictoryStateEscalatesToWindowObservation() {
    var time: CFAbsoluteTime = 100.0
    let escalatedSnapshot = ActivationObservationSnapshot(
        targetBundleIdentifier: "com.apple.Safari",
        observedFrontmostBundleIdentifier: "com.apple.Terminal",
        targetIsActive: false,
        targetIsHidden: true,
        visibleWindowCount: 0,
        hasFocusedWindow: false,
        hasMainWindow: false,
        windowObservationSucceeded: true,
        windowObservationFailureReason: nil,
        classification: .regularWindowed,
        classificationReason: "visible focused main window"
    )

    let broker = ObservationBroker(client: .init(
        frontmostBundleIdentifier: { "com.apple.Safari" },
        targetIsHidden: { true },
        targetIsActive: { true },
        targetClassification: { .regularWindowed },
        escalatedSnapshot: { escalatedSnapshot },
        now: { time },
        pollOnce: { interval in time += interval }
    ))

    let result = broker.confirmFastRestore(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal"
    )

    #expect(result.confirmed == true)
    #expect(result.usedEscalatedObservation == true)
    #expect(result.frontmostBundleAfterRestore == "com.apple.Terminal")
}

// MARK: - Classification-based escalation

@Test @MainActor
func systemUtilitySkipsCheapConfirmationAndEscalates() {
    let escalatedSnapshot = ActivationObservationSnapshot(
        targetBundleIdentifier: "com.apple.systempreferences",
        observedFrontmostBundleIdentifier: "com.apple.Terminal",
        targetIsActive: false,
        targetIsHidden: false,
        visibleWindowCount: 0,
        hasFocusedWindow: false,
        hasMainWindow: false,
        windowObservationSucceeded: true,
        windowObservationFailureReason: nil,
        classification: .systemUtility,
        classificationReason: "activation policy is accessory"
    )

    let broker = ObservationBroker(client: .init(
        frontmostBundleIdentifier: { "com.apple.systempreferences" },
        targetIsHidden: { false },
        targetIsActive: { true },
        targetClassification: { .systemUtility },
        escalatedSnapshot: { escalatedSnapshot },
        now: { 100 },
        pollOnce: { _ in fatalError("should not poll") }
    ))

    let result = broker.confirmFastRestore(
        targetBundleIdentifier: "com.apple.systempreferences",
        previousBundleIdentifier: "com.apple.Terminal"
    )

    #expect(result.confirmed == true)
    #expect(result.usedEscalatedObservation == true)
}

@Test @MainActor
func windowlessOrAccessoryEscalatesImmediately() {
    let escalatedSnapshot = ActivationObservationSnapshot(
        targetBundleIdentifier: "com.apple.Home",
        observedFrontmostBundleIdentifier: "com.apple.Home",
        targetIsActive: true,
        targetIsHidden: false,
        visibleWindowCount: 0,
        hasFocusedWindow: false,
        hasMainWindow: false,
        windowObservationSucceeded: true,
        windowObservationFailureReason: nil,
        classification: .windowlessOrAccessory,
        classificationReason: "no visible windows"
    )

    let broker = ObservationBroker(client: .init(
        frontmostBundleIdentifier: { "com.apple.Home" },
        targetIsHidden: { false },
        targetIsActive: { true },
        targetClassification: { .windowlessOrAccessory },
        escalatedSnapshot: { escalatedSnapshot },
        now: { 100 },
        pollOnce: { _ in fatalError("should not poll") }
    ))

    let result = broker.confirmFastRestore(
        targetBundleIdentifier: "com.apple.Home",
        previousBundleIdentifier: "com.apple.Terminal"
    )

    // Not confirmed because escalated snapshot shows target is still frontmost
    #expect(result.confirmed == false)
    #expect(result.usedEscalatedObservation == true)
}

// MARK: - Compatibility lane

@Test @MainActor
func compatibilityLaneAlwaysUsesEscalatedObservation() {
    let escalatedSnapshot = ActivationObservationSnapshot(
        targetBundleIdentifier: "com.apple.Safari",
        observedFrontmostBundleIdentifier: "com.apple.Terminal",
        targetIsActive: false,
        targetIsHidden: true,
        visibleWindowCount: 0,
        hasFocusedWindow: false,
        hasMainWindow: false,
        windowObservationSucceeded: true,
        windowObservationFailureReason: nil,
        classification: .regularWindowed,
        classificationReason: "visible focused main window"
    )

    let broker = ObservationBroker(client: .init(
        frontmostBundleIdentifier: { "com.apple.Terminal" },
        targetIsHidden: { true },
        targetIsActive: { false },
        targetClassification: { .regularWindowed },
        escalatedSnapshot: { escalatedSnapshot },
        now: { 100 },
        pollOnce: { _ in }
    ))

    let result = broker.confirmCompatibilityRestore(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal"
    )

    #expect(result.confirmed == true)
    #expect(result.usedEscalatedObservation == true)
    #expect(result.frontmostBundleAfterRestore == "com.apple.Terminal")
}

// MARK: - Nil previous bundle

@Test @MainActor
func nilPreviousBundleHandledGracefully() {
    let broker = ObservationBroker(client: .init(
        frontmostBundleIdentifier: { "com.apple.Finder" },
        targetIsHidden: { false },
        targetIsActive: { false },
        targetClassification: { .regularWindowed },
        escalatedSnapshot: { fatalError("should not escalate") },
        now: { 100 },
        pollOnce: { _ in }
    ))

    let result = broker.confirmFastRestore(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: nil
    )

    #expect(result.confirmed == true)
    #expect(result.frontmostBundleAfterRestore == "com.apple.Finder")
}
