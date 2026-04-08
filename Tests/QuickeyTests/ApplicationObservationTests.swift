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
        classification: .windowlessOrAccessory,
        classificationReason: "no visible windows"
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
        classification: .nonStandardWindowed,
        classificationReason: "window appeared during confirmation"
    )

    #expect(firstAttempt.classification == .windowlessOrAccessory)
    #expect(secondAttempt.classification == .nonStandardWindowed)
    #expect(firstAttempt.classification != secondAttempt.classification)
}

@Test
func nonStandardFrontmostWindowWithoutFocusIsNotStable() {
    let snapshot = ActivationObservationSnapshot(
        targetBundleIdentifier: "dev.zed.Zed",
        observedFrontmostBundleIdentifier: "dev.zed.Zed",
        targetIsActive: true,
        targetIsHidden: false,
        visibleWindowCount: 1,
        hasFocusedWindow: false,
        hasMainWindow: false,
        windowObservationSucceeded: true,
        windowObservationFailureReason: nil,
        classification: .nonStandardWindowed,
        classificationReason: "window evidence is incomplete for dev.zed.Zed"
    )

    #expect(snapshot.isStableActivation == false)
}

@Test
func nonStandardFrontmostWindowWithFocusAndMainWindowCanBeStable() {
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
