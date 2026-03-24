import AppKit
import ApplicationServices
import Testing
@testable import Quickey

@Test @MainActor
func activateProcessFallsBackWhenProcessLookupFails() {
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForAppSwitcherTests(),
        activationClient: .init(activateFrontProcess: { _, _ in
            .processLookupFailed(-600)
        })
    )
    var fallbackCallCount = 0

    let result = switcher.activateProcess(pid: 42, windowID: 11) {
        fallbackCallCount += 1
        return true
    }

    if case .fallback(let activated) = result {
        #expect(activated == true)
    } else {
        Issue.record("Expected fallback activation when process lookup fails")
    }
    #expect(fallbackCallCount == 1)
}

@Test @MainActor
func activateProcessFallsBackWhenSkyLightActivationFails() {
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForAppSwitcherTests(),
        activationClient: .init(activateFrontProcess: { _, _ in
            .activationFailed(.failure)
        })
    )
    var fallbackCallCount = 0

    let result = switcher.activateProcess(pid: 42, windowID: 11) {
        fallbackCallCount += 1
        return false
    }

    if case .fallback(let activated) = result {
        #expect(activated == false)
    } else {
        Issue.record("Expected fallback activation when SkyLight activation fails")
    }
    #expect(fallbackCallCount == 1)
}

@Test @MainActor
func activateProcessReturnsSkyLightResultWhenActivationSucceeds() {
    var psn = ProcessSerialNumber()
    psn.highLongOfPSN = 1
    psn.lowLongOfPSN = 2
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForAppSwitcherTests(),
        activationClient: .init(activateFrontProcess: { _, _ in
            .success(psn)
        })
    )
    var fallbackCallCount = 0

    let result = switcher.activateProcess(pid: 42, windowID: nil) {
        fallbackCallCount += 1
        return false
    }

    if case .skyLight(let receivedPSN) = result {
        #expect(receivedPSN.highLongOfPSN == 1)
        #expect(receivedPSN.lowLongOfPSN == 2)
    } else {
        Issue.record("Expected SkyLight activation result")
    }
    #expect(fallbackCallCount == 0)
}

@Test @MainActor
func requestFallbackActivationReopensApplicationViaWorkspaceWhenBundleURLExists() {
    let recorder = FallbackActivationRecorder()
    let bundleURL = URL(fileURLWithPath: "/Applications/Terminal.app")
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForAppSwitcherTests(),
        fallbackActivationClient: .init(openApplication: { url, configuration, completion in
            recorder.openedURLs.append(url)
            recorder.activatesFlags.append(configuration.activates)
            completion(nil)
        })
    )
    var plainActivateCalls = 0

    let result = switcher.requestFallbackActivation(
        bundleURL: bundleURL,
        bundleIdentifier: "com.apple.Terminal"
    ) {
        plainActivateCalls += 1
        return false
    }

    #expect(result == true)
    #expect(recorder.openedURLs == [bundleURL])
    #expect(recorder.activatesFlags == [true])
    #expect(plainActivateCalls == 0)
}

@Test @MainActor
func requestFallbackActivationUsesPlainActivationWhenBundleURLIsMissing() {
    let recorder = FallbackActivationRecorder()
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForAppSwitcherTests(),
        fallbackActivationClient: .init(openApplication: { url, configuration, completion in
            recorder.openedURLs.append(url)
            recorder.activatesFlags.append(configuration.activates)
            completion(nil)
        })
    )
    var plainActivateCalls = 0

    let result = switcher.requestFallbackActivation(
        bundleURL: nil,
        bundleIdentifier: "com.apple.Terminal"
    ) {
        plainActivateCalls += 1
        return true
    }

    #expect(result == true)
    #expect(recorder.openedURLs.isEmpty)
    #expect(plainActivateCalls == 1)
}

@Test
func togglePostActionStateLogDetailsIncludesFrontmostAndTargetFlags() {
    let state = TogglePostActionState(
        frontmostBundleIdentifier: "com.openai.codex",
        targetBundleIdentifier: "com.apple.Safari",
        targetFrontmost: false,
        targetHidden: true,
        targetVisibleWindows: false
    )

    #expect(
        state.logDetails ==
        "postFrontmost=com.openai.codex, targetBundle=com.apple.Safari, targetFrontmost=false, targetHidden=true, targetVisibleWindows=false"
    )
}

@Test @MainActor
func postActionLogMessageUsesObservationSnapshotForFrontmostState() {
    let switcher = AppSwitcher(frontmostTracker: makeTrackerForAppSwitcherTests())
    let shortcut = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command"]
    )
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
        classificationReason: "visible window but frontmost mismatch"
    )

    let message = switcher.postActionLogMessage(
        for: shortcut,
        phase: "POST_ACTIVATE_STATE",
        snapshot: snapshot
    )

    #expect(message.contains("postFrontmost=com.openai.codex"))
    #expect(message.contains("targetFrontmost=false"))
}

@Test @MainActor
func postActionLogMessageUsesEffectiveStableOverride() {
    let switcher = AppSwitcher(frontmostTracker: makeTrackerForAppSwitcherTests())
    let shortcut = AppShortcut(
        appName: "Home",
        bundleIdentifier: "com.apple.Home",
        keyEquivalent: "h",
        modifierFlags: ["command"]
    )
    let snapshot = ActivationObservationSnapshot(
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

    let message = switcher.postActionLogMessage(
        for: shortcut,
        phase: "POST_ACTIVATE_STATE",
        snapshot: snapshot,
        effectiveStable: false
    )

    #expect(message.contains("stable=false"))
}

@Test @MainActor
func toggleLifecycleLogMessageIncludesStructuredObservationFields() {
    let switcher = AppSwitcher(frontmostTracker: makeTrackerForAppSwitcherTests())
    let shortcut = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command"]
    )
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
        classificationReason: "visible window but frontmost mismatch"
    )

    let message = switcher.toggleLifecycleLogMessage(
        for: shortcut,
        lifecycle: "TOGGLE_CONFIRMATION",
        previousBundle: "com.openai.codex",
        activationPath: "activate",
        snapshot: snapshot,
        elapsedMilliseconds: 75
    )

    #expect(message.contains("TOGGLE_CONFIRMATION"))
    #expect(message.contains("previous=com.openai.codex"))
    #expect(message.contains("activationPath=activate"))
    #expect(message.contains("elapsedMs=75"))
    #expect(message.contains("classification=\"regularWindowed\""))
}

@Test @MainActor
func secondTriggerDuringPendingActivationDoesNotToggleOff() {
    let switcher = AppSwitcher(frontmostTracker: makeTrackerForAppSwitcherTests())

    let first = switcher.acceptPendingActivation(
        for: "com.apple.Safari",
        previousBundleIdentifier: "com.openai.codex",
        startedAt: 10
    )

    #expect(switcher.shouldToggleOff(bundleIdentifier: "com.apple.Safari", runningAppIsActive: true) == false)

    let second = switcher.acceptPendingActivation(
        for: "com.apple.Safari",
        previousBundleIdentifier: "com.openai.codex",
        startedAt: 11
    )

    #expect(first.generation == 1)
    #expect(second.generation == 2)
    #expect(switcher.pendingActivationState == second)
    #expect(switcher.stableActivationState == nil)
}

@Test @MainActor
func staleConfirmationGenerationCannotPromoteState() {
    let switcher = AppSwitcher(frontmostTracker: makeTrackerForAppSwitcherTests())
    let first = switcher.acceptPendingActivation(
        for: "com.apple.Safari",
        previousBundleIdentifier: "com.openai.codex",
        startedAt: 20
    )
    let second = switcher.acceptPendingActivation(
        for: "com.apple.Safari",
        previousBundleIdentifier: "com.openai.codex",
        startedAt: 21
    )
    let stableSnapshot = ActivationObservationSnapshot(
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

    let promoted = switcher.promotePendingActivationIfCurrent(
        bundleIdentifier: "com.apple.Safari",
        generation: first.generation,
        snapshot: stableSnapshot
    )

    #expect(promoted == false)
    #expect(switcher.pendingActivationState == second)
    #expect(switcher.stableActivationState == nil)
}

@Test @MainActor
func confirmationWithoutVisibleWindowEvidenceDoesNotPromoteStable() {
    let switcher = AppSwitcher(frontmostTracker: makeTrackerForAppSwitcherTests())
    let pending = switcher.acceptPendingActivation(
        for: "com.apple.Home",
        previousBundleIdentifier: "com.openai.codex",
        startedAt: 25
    )
    let windowlessSnapshot = ActivationObservationSnapshot(
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

    let promoted = switcher.promotePendingActivationIfCurrent(
        bundleIdentifier: "com.apple.Home",
        generation: pending.generation,
        snapshot: windowlessSnapshot
    )

    #expect(promoted == false)
    #expect(switcher.pendingActivationState == pending)
    #expect(switcher.stableActivationState == nil)
}

@Test @MainActor
func acceptedTriggerStillReturnsTrueWhileConfirmationIsPending() {
    let switcher = AppSwitcher(frontmostTracker: makeTrackerForAppSwitcherTests())

    let accepted = switcher.recordAcceptedTrigger(
        bundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.openai.codex",
        startedAt: 30
    )

    #expect(accepted == true)
    #expect(switcher.pendingActivationState?.bundleIdentifier == "com.apple.Safari")
    #expect(switcher.stableActivationState == nil)
}

@Test @MainActor
func recoverWindowlessAppStageCompletionHappensBeforeNextConfirmation() {
    let scheduler = ManualConfirmationScheduler()
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForAppSwitcherTests(),
        confirmationClient: .init(
            now: { 40 },
            schedule: { delay, operation in
                scheduler.schedule(after: delay, operation)
            }
        )
    )
    let state = switcher.acceptPendingActivation(
        for: "com.apple.Home",
        previousBundleIdentifier: "com.openai.codex",
        startedAt: 40
    )
    let shortcut = AppShortcut(
        appName: "Home",
        bundleIdentifier: "com.apple.Home",
        keyEquivalent: "h",
        modifierFlags: ["command"]
    )
    var snapshots = [
        ActivationObservationSnapshot(
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
            classificationReason: "no visible windows yet"
        ),
        ActivationObservationSnapshot(
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
            classificationReason: "window appeared after staged recovery"
        )
    ]
    var events: [String] = []

    switcher.schedulePendingConfirmation(
        state: state,
        shortcut: shortcut,
        activationPath: "activate",
        observe: {
            let snapshot = snapshots.removeFirst()
            events.append("confirm:\(snapshot.visibleWindowCount)")
            return snapshot
        },
        recoverIfNeeded: { stage, completion in
            events.append("recover:\(stage.rawValue)")
            completion()
        }
    )

    scheduler.runNext()
    scheduler.runNext()

    #expect(events == ["confirm:0", "recover:axRaise", "confirm:1"])
    #expect(switcher.stableActivationState?.bundleIdentifier == "com.apple.Home")
}

// MARK: - Coordinator integration tests

@Test @MainActor
func acceptPendingActivationNotifiesCoordinator() {
    let coordinator = ToggleSessionCoordinator(now: { 100 })
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForAppSwitcherTests(),
        sessionCoordinator: coordinator
    )

    switcher.acceptPendingActivation(
        for: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        startedAt: 100
    )

    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .activating)
    #expect(coordinator.previousBundle(for: "com.apple.Safari") == "com.apple.Terminal")
}

@Test @MainActor
func promotionToStableNotifiesCoordinator() {
    let clock = MutableClock(time: 100)
    let coordinator = ToggleSessionCoordinator(now: { clock.time })
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForAppSwitcherTests(),
        confirmationClient: .init(now: { clock.time }, schedule: { _, _ in }),
        sessionCoordinator: coordinator
    )

    let pending = switcher.acceptPendingActivation(
        for: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        startedAt: clock.time
    )
    clock.time = 101
    let stableSnapshot = ActivationObservationSnapshot(
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

    let promoted = switcher.promotePendingActivationIfCurrent(
        bundleIdentifier: "com.apple.Safari",
        generation: pending.generation,
        snapshot: stableSnapshot
    )

    #expect(promoted == true)
    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .activeStable)
}

@Test @MainActor
func shouldToggleOffReturnsFalseWhenCoordinatorInvalidatesSession() {
    let clock = MutableClock(time: 100)
    let coordinator = ToggleSessionCoordinator(now: { clock.time })
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForAppSwitcherTests(),
        confirmationClient: .init(now: { clock.time }, schedule: { _, _ in }),
        sessionCoordinator: coordinator
    )

    let pending = switcher.acceptPendingActivation(
        for: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        startedAt: clock.time
    )
    clock.time = 101
    let stableSnapshot = ActivationObservationSnapshot(
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
    switcher.promotePendingActivationIfCurrent(
        bundleIdentifier: "com.apple.Safari",
        generation: pending.generation,
        snapshot: stableSnapshot
    )

    // Coordinator invalidates via frontmost change
    coordinator.handleFrontmostChange(newFrontmostBundle: "com.apple.Terminal")

    #expect(switcher.shouldToggleOff(bundleIdentifier: "com.apple.Safari", runningAppIsActive: true) == false)
    #expect(switcher.stableActivationState == nil)
}

@Test @MainActor
func clearActivationTrackingResetsCoordinatorSession() {
    let coordinator = ToggleSessionCoordinator(now: { 100 })
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForAppSwitcherTests(),
        sessionCoordinator: coordinator
    )

    switcher.acceptPendingActivation(
        for: "com.apple.Safari",
        previousBundleIdentifier: nil,
        startedAt: 100
    )
    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .activating)

    // recordAcceptedTrigger for a different app clears the previous one
    switcher.recordAcceptedTrigger(
        bundleIdentifier: "com.apple.Terminal",
        previousBundleIdentifier: nil,
        startedAt: 100
    )

    // recordAcceptedTrigger calls acceptPendingActivation which doesn't call
    // clearActivationTracking directly — that happens inside toggleApplication
    // for different-bundle conflicts. Verify coordinator's resetSession works.
    coordinator.resetSession(for: "com.apple.Safari")
    #expect(coordinator.session(for: "com.apple.Safari")?.phase == .idle)
}

@MainActor
private func makeTrackerForAppSwitcherTests() -> FrontmostApplicationTracker {
    FrontmostApplicationTracker(client: .init(
        currentFrontmostBundleIdentifier: { nil },
        processIdentifierForRunningApplication: { _ in nil },
        activateRunningApplication: { _ in false },
        setFrontProcess: { _ in false }
    ))
}

@MainActor
private final class MutableClock {
    var time: CFAbsoluteTime

    init(time: CFAbsoluteTime) {
        self.time = time
    }
}

private final class FallbackActivationRecorder: @unchecked Sendable {
    var openedURLs: [URL] = []
    var activatesFlags: [Bool] = []
}

@MainActor
private final class ManualConfirmationScheduler {
    private var operations: [@MainActor () -> Void] = []

    func schedule(after _: TimeInterval, _ operation: @escaping @MainActor () -> Void) {
        operations.append(operation)
    }

    func runNext() {
        guard !operations.isEmpty else {
            Issue.record("Expected a scheduled confirmation operation")
            return
        }
        let operation = operations.removeFirst()
        operation()
    }
}
