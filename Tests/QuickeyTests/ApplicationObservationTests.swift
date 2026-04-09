import AppKit
import Testing
@testable import Quickey

@Test
func observationMarksFrontmostMismatchAsNotStable() {
    let snapshot = ActivationObservationSnapshot(
        targetBundleIdentifier: "com.apple.Safari",
        observedFrontmostBundleIdentifier: "com.openai.codex",
        targetIsActive: true,
        targetIsHidden: false,
        visibleWindowCount: 1,
        hasFocusedWindow: false,
        hasMainWindow: true,
        windowObservationSucceeded: true,
        windowObservationFailureReason: nil,
        classification: .regularWindowed,
        classificationReason: "visible main window"
    )

    #expect(snapshot.isStableActivation == false)
}

@Test
func observationReevaluatesClassificationPerAttempt() {
    let firstAttempt = ActivationObservationSnapshot(
        targetBundleIdentifier: "com.apple.Home",
        observedFrontmostBundleIdentifier: "com.apple.Home",
        targetIsActive: true,
        targetIsHidden: false,
        visibleWindowCount: 0,
        hasFocusedWindow: false,
        hasMainWindow: false,
        windowObservationSucceeded: true,
        windowObservationFailureReason: nil,
        classification: .nonStandardWindowed,
        classificationReason: "regular app has no visible, focused, or main window evidence"
    )
    let secondAttempt = ActivationObservationSnapshot(
        targetBundleIdentifier: "com.apple.Home",
        observedFrontmostBundleIdentifier: "com.apple.Home",
        targetIsActive: true,
        targetIsHidden: false,
        visibleWindowCount: 1,
        hasFocusedWindow: true,
        hasMainWindow: true,
        windowObservationSucceeded: true,
        windowObservationFailureReason: nil,
        classification: .regularWindowed,
        classificationReason: "window appeared during confirmation"
    )

    #expect(firstAttempt.classification == .nonStandardWindowed)
    #expect(secondAttempt.classification == .regularWindowed)
    #expect(firstAttempt.classification != secondAttempt.classification)
}

@Test
func regularAppWithoutUsableWindowEvidenceIsNotStable() {
    let snapshot = ActivationObservationSnapshot(
        targetBundleIdentifier: "dev.zed.Zed",
        observedFrontmostBundleIdentifier: "dev.zed.Zed",
        targetIsActive: true,
        targetIsHidden: false,
        visibleWindowCount: 0,
        hasFocusedWindow: false,
        hasMainWindow: false,
        windowObservationSucceeded: true,
        windowObservationFailureReason: nil,
        classification: .nonStandardWindowed,
        classificationReason: "regular app has no visible, focused, or main window evidence"
    )

    #expect(snapshot.isStableActivation == false)
}

@Test
func regularAppWithAnyUsableWindowEvidenceCanBeStable() {
    let snapshot = ActivationObservationSnapshot(
        targetBundleIdentifier: "dev.zed.Zed",
        observedFrontmostBundleIdentifier: "dev.zed.Zed",
        targetIsActive: true,
        targetIsHidden: false,
        visibleWindowCount: 1,
        hasFocusedWindow: true,
        hasMainWindow: true,
        windowObservationSucceeded: true,
        windowObservationFailureReason: nil,
        classification: .nonStandardWindowed,
        classificationReason: "window became focused after recovery"
    )

    #expect(snapshot.isStableActivation == true)
}

@Test
func observationCanRepresentCurrentTogglePostActionFields() {
    let snapshot = ActivationObservationSnapshot(
        targetBundleIdentifier: "com.apple.Safari",
        observedFrontmostBundleIdentifier: "com.apple.Safari",
        targetIsActive: true,
        targetIsHidden: true,
        visibleWindowCount: 0,
        hasFocusedWindow: false,
        hasMainWindow: false,
        windowObservationSucceeded: true,
        windowObservationFailureReason: nil,
        classification: .regularWindowed,
        classificationReason: "hidden app"
    )

    let state = TogglePostActionState(snapshot: snapshot)

    #expect(state.frontmostBundleIdentifier == "com.apple.Safari")
    #expect(state.targetBundleIdentifier == "com.apple.Safari")
    #expect(state.targetFrontmost == true)
    #expect(state.targetHidden == true)
    #expect(state.targetVisibleWindows == false)
}

@Test
func structuredLogFieldsQuoteStringValues() {
    let snapshot = ActivationObservationSnapshot(
        targetBundleIdentifier: "com.apple.Safari",
        observedFrontmostBundleIdentifier: "com.openai.codex",
        targetIsActive: true,
        targetIsHidden: false,
        visibleWindowCount: 1,
        hasFocusedWindow: true,
        hasMainWindow: true,
        windowObservationSucceeded: true,
        windowObservationFailureReason: nil,
        classification: .regularWindowed,
        classificationReason: "visible focused \"main\" window"
    )

    #expect(snapshot.structuredLogFields.contains("frontmost=\"com.openai.codex\""))
    #expect(snapshot.structuredLogFields.contains("target=\"com.apple.Safari\""))
    #expect(snapshot.structuredLogFields.contains("classification=\"regularWindowed\""))
    #expect(snapshot.structuredLogFields.contains("classificationReason=\"visible focused \\\"main\\\" window\""))
    #expect(snapshot.structuredLogFields.contains("allowsWindowlessStableActivation=false"))
}

@Test
func structuredLogFieldsIncludeWindowObservationFailureSignal() {
    let snapshot = ActivationObservationSnapshot(
        targetBundleIdentifier: "com.apple.Home",
        observedFrontmostBundleIdentifier: "com.apple.Home",
        targetIsActive: true,
        targetIsHidden: false,
        visibleWindowCount: 0,
        hasFocusedWindow: false,
        hasMainWindow: false,
        windowObservationSucceeded: false,
        windowObservationFailureReason: "axWindowsReadFailed=-25204",
        classification: .nonStandardWindowed,
        classificationReason: "axWindowsReadFailed=-25204"
    )

    #expect(snapshot.structuredLogFields.contains("windowObservationSucceeded=false"))
    #expect(snapshot.structuredLogFields.contains("windowObservationFailureReason=\"axWindowsReadFailed=-25204\""))
    #expect(snapshot.structuredLogFields.contains("classification=\"nonStandardWindowed\""))
}

@Test @MainActor
func regularAppWithoutWindowEvidenceDoesNotClassifyAsWindowlessAccessory() {
    let currentApp = NSRunningApplication.current
    let observation = ApplicationObservation(client: .init(
        currentFrontmostBundleIdentifier: {
            currentApp.bundleIdentifier
        },
        windowObservation: { _ in
            .init(
                windows: nil,
                visibleWindowCount: 0,
                hasFocusedWindow: false,
                hasMainWindow: false,
                windowsReadSucceeded: true,
                failureReason: nil
            )
        },
        activationPolicy: { _ in
            .regular
        }
    ))

    let snapshot = observation.snapshot(for: currentApp)

    #expect(snapshot.classification == .nonStandardWindowed)
    #expect(snapshot.allowsWindowlessStableActivation == false)
}

@Test @MainActor
func nonRegularAppWithoutWindowEvidenceCanRemainStable() {
    let currentApp = NSRunningApplication.current
    let observation = ApplicationObservation(client: .init(
        currentFrontmostBundleIdentifier: {
            currentApp.bundleIdentifier
        },
        windowObservation: { _ in
            .init(
                windows: nil,
                visibleWindowCount: 0,
                hasFocusedWindow: false,
                hasMainWindow: false,
                windowsReadSucceeded: true,
                failureReason: nil
            )
        },
        activationPolicy: { _ in
            .accessory
        }
    ))

    let snapshot = observation.snapshot(for: currentApp)

    #expect(snapshot.classification == .systemUtility)
    #expect(snapshot.allowsWindowlessStableActivation == true)
}
