import CoreFoundation
import Testing
@testable import Quickey

// MARK: - Cheap confirmation

@Test @MainActor
func cheapConfirmationSucceedsFromFrontmostChangeWithoutEscalation() {
    let broker = ObservationBroker(client: .init(
        frontmostBundleIdentifier: { "com.apple.Terminal" },
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
func cheapConfirmationTimesOutAndEscalates() {
    var time: CFAbsoluteTime = 100.0
    let escalatedSnapshot = ActivationObservationSnapshot(
        targetBundleIdentifier: "com.apple.Safari",
        observedFrontmostBundleIdentifier: "com.apple.Safari",
        targetIsActive: true,
        targetIsHidden: false,
        visibleWindowCount: 1,
        hasFocusedWindow: true,
        hasMainWindow: true,
        windowObservationSucceeded: true,
        windowObservationFailureReason: nil,
        classification: .regularWindowed,
        classificationReason: "visible focused main window"
    )

    let broker = ObservationBroker(client: .init(
        frontmostBundleIdentifier: { "com.apple.Safari" },
        targetClassification: { .regularWindowed },
        escalatedSnapshot: { escalatedSnapshot },
        now: { time },
        pollOnce: { interval in time += interval }
    ))

    let result = broker.confirmFastRestore(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal"
    )

    // Timeout now escalates to observation instead of returning unconfirmed
    #expect(result.confirmed == false)
    #expect(result.usedEscalatedObservation == true)
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
