import Foundation
import Testing
@testable import Wink

@MainActor
private final class FirstShortcutOnboardingClientSpy {
    var readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: true,
        accessibilityGranted: false,
        inputMonitoringGranted: false,
        routeReady: false,
        shortcutsPaused: false,
        secureInputActive: false
    )
    var requestedShortcutIDs: [UUID] = []
    var openedDestinations: [FirstShortcutOnboardingState.SystemSettingsDestination] = []
    var scheduledTimeouts: [@MainActor () -> Void] = []
    var scheduledTimeoutDurations: [Duration] = []
    var automaticPromptSuppressionValues: [Bool] = []
    var readinessRequestedShortcutIDs: [UUID] = []

    var client: FirstShortcutOnboardingState.Client {
        FirstShortcutOnboardingState.Client(
            readiness: { [weak self] shortcut in
                self?.readinessRequestedShortcutIDs.append(shortcut.id)
                return self?.readiness ?? FirstShortcutOnboardingReadiness(
                    route: .standard,
                    shortcutAvailable: false,
                    accessibilityGranted: false,
                    inputMonitoringGranted: false,
                    routeReady: false,
                    shortcutsPaused: false,
                    secureInputActive: false
                )
            },
            requestPermissions: { [weak self] shortcut in
                self?.requestedShortcutIDs.append(shortcut.id)
            },
            openSystemSettings: { [weak self] destination in
                self?.openedDestinations.append(destination)
            },
            setAutomaticPermissionPromptSuppressed: { [weak self] suppressed in
                self?.automaticPromptSuppressionValues.append(suppressed)
            },
            scheduleVerificationTimeout: { [weak self] duration, operation in
                self?.scheduledTimeoutDurations.append(duration)
                self?.scheduledTimeouts.append(operation)
            },
            log: { _ in }
        )
    }
}

@MainActor
private struct FirstShortcutOnboardingTestContext {
    let suiteName: String
    let defaults: UserDefaults
    let spy: FirstShortcutOnboardingClientSpy
    let state: FirstShortcutOnboardingState

    init() throws {
        suiteName = "FirstShortcutOnboardingStateTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        spy = FirstShortcutOnboardingClientSpy()
        state = FirstShortcutOnboardingState(
            userDefaults: defaults,
            legacyCompletionDefaultsKey: AppController.firstLaunchCompletedDefaultsKey,
            client: spy.client
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private func onboardingShortcut(id: UUID = UUID()) -> AppShortcut {
    AppShortcut(
        id: id,
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )
}

private func activationAttempt(
    for shortcut: AppShortcut,
    attemptID: UUID = UUID(),
    generation: Int = 1,
    isConfirmed: Bool = false
) -> AppActivationAttemptSnapshot {
    AppActivationAttemptSnapshot(
        identity: AppActivationAttemptIdentity(
            bundleIdentifier: shortcut.bundleIdentifier,
            attemptID: attemptID,
            generation: generation
        ),
        isConfirmed: isConfirmed
    )
}

@Test @MainActor
func freshInstallShowsIntroductionWithoutPersistingCompletion() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }

    #expect(context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false))
    #expect(context.state.phase == .introduction)
    #expect(!context.state.allowsShortcutComposition)
    #expect(!context.state.allowsFrontmostTargetSelection)
    #expect(!context.state.allowsAggregatePermissionRequests)
    #expect(context.state.completion == nil)
    #expect(!context.defaults.bool(forKey: AppController.firstLaunchCompletedDefaultsKey))
    #expect(context.defaults.bool(forKey: FirstShortcutOnboardingState.inProgressDefaultsKey))
    #expect(context.spy.automaticPromptSuppressionValues == [true])

    context.state.continueFromIntroduction()
    #expect(context.state.allowsShortcutComposition)
    #expect(!context.state.allowsFrontmostTargetSelection)
}

@Test @MainActor
func existingShortcutUserIsExemptFromOnboarding() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }

    #expect(!context.state.prepareForLaunch(
        shortcuts: [onboardingShortcut()],
        hasLegacyCompletion: false
    ))
    #expect(context.state.phase == .hidden)
    #expect(context.state.completion == nil)
    #expect(context.defaults.bool(forKey: AppController.firstLaunchCompletedDefaultsKey))
}

@Test @MainActor
func skipIsTheOnlyPreVerificationPathThatPersistsCompletion() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    #expect(context.state.completion == nil)

    context.state.skip()
    #expect(context.state.phase == .hidden)
    #expect(context.state.completion == .skipped)
    #expect(!context.defaults.bool(forKey: FirstShortcutOnboardingState.inProgressDefaultsKey))
    #expect(context.spy.automaticPromptSuppressionValues.last == false)

    let relaunched = FirstShortcutOnboardingState(
        userDefaults: context.defaults,
        legacyCompletionDefaultsKey: AppController.firstLaunchCompletedDefaultsKey,
        client: context.spy.client
    )
    #expect(!relaunched.prepareForLaunch(shortcuts: [], hasLegacyCompletion: true))
    #expect(relaunched.phase == .hidden)
}

@Test @MainActor
func deniedPermissionAndRelaunchResumeTheExactCreatedShortcut() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)

    #expect(context.state.phase == .permissions)
    #expect(context.state.activeShortcut?.id == shortcut.id)
    #expect(context.state.completion == nil)

    context.state.requestPermissions()
    #expect(context.spy.requestedShortcutIDs == [shortcut.id])
    #expect(context.state.phase == .permissions)

    let relaunched = FirstShortcutOnboardingState(
        userDefaults: context.defaults,
        legacyCompletionDefaultsKey: AppController.firstLaunchCompletedDefaultsKey,
        client: context.spy.client
    )
    #expect(relaunched.prepareForLaunch(shortcuts: [shortcut], hasLegacyCompletion: false))
    #expect(relaunched.phase == .permissions)
    #expect(relaunched.activeShortcut?.id == shortcut.id)

    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: false
    )
    relaunched.refreshReadiness()
    #expect(relaunched.phase == .verification(waitingForActivation: false))
}

@Test @MainActor
func restoredPendingShortcutWaitsForLiveCaptureBeforeCheckingAvailability() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)
    context.spy.readinessRequestedShortcutIDs.removeAll()
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: false,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: false
    )

    let relaunched = FirstShortcutOnboardingState(
        userDefaults: context.defaults,
        legacyCompletionDefaultsKey: AppController.firstLaunchCompletedDefaultsKey,
        client: context.spy.client
    )
    #expect(relaunched.prepareForLaunch(shortcuts: [shortcut], hasLegacyCompletion: true))
    #expect(relaunched.phase == .permissions)
    #expect(context.spy.readinessRequestedShortcutIDs.isEmpty)

    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: false
    )
    relaunched.refreshReadiness()

    #expect(context.spy.readinessRequestedShortcutIDs == [shortcut.id])
    #expect(relaunched.phase == .verification(waitingForActivation: false))
}

@Test @MainActor
func synchronizingThePendingShortcutReconcilesAMissedReadinessChange() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)
    #expect(context.state.phase == .permissions)

    // Models a permission/capture transition that landed while the Shortcuts
    // tab was unmounted. Its onAppear synchronization must re-read the exact
    // route even though the persisted shortcut itself did not change.
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: false
    )
    context.state.synchronize(shortcuts: [shortcut])

    #expect(context.state.phase == .verification(waitingForActivation: false))
    #expect(context.spy.readinessRequestedShortcutIDs.last == shortcut.id)
}

@Test @MainActor
func inProgressMarkerOutranksCompletionAndNonemptyStoreWithoutAPendingUUID() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let existingShortcut = onboardingShortcut()

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.skip()
    context.state.startManually()
    #expect(context.defaults.bool(forKey: FirstShortcutOnboardingState.inProgressDefaultsKey))

    let relaunched = FirstShortcutOnboardingState(
        userDefaults: context.defaults,
        legacyCompletionDefaultsKey: AppController.firstLaunchCompletedDefaultsKey,
        client: context.spy.client
    )
    #expect(relaunched.prepareForLaunch(
        shortcuts: [existingShortcut],
        hasLegacyCompletion: true
    ))
    #expect(relaunched.phase == .introduction)
    #expect(relaunched.completion == .skipped)
    #expect(context.defaults.bool(forKey: FirstShortcutOnboardingState.inProgressDefaultsKey))
}

@Test @MainActor
func pendingManualRunOutranksAnOlderCompletionAcrossRelaunch() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.skip()
    #expect(context.state.completion == .skipped)

    context.state.startManually()
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)

    let relaunched = FirstShortcutOnboardingState(
        userDefaults: context.defaults,
        legacyCompletionDefaultsKey: AppController.firstLaunchCompletedDefaultsKey,
        client: context.spy.client
    )
    #expect(relaunched.prepareForLaunch(shortcuts: [shortcut], hasLegacyCompletion: true))
    #expect(relaunched.activeShortcut?.id == shortcut.id)
    #expect(relaunched.phase == .permissions)
}

@Test @MainActor
func startingTheGuideAgainCannotOrphanAnActiveShortcutAttempt() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)
    let phaseBefore = context.state.phase
    let attemptBefore = context.state.verificationAttemptID
    let pendingBefore = context.defaults.string(
        forKey: FirstShortcutOnboardingState.pendingShortcutIDDefaultsKey
    )

    context.state.startManually()

    #expect(context.state.phase == phaseBefore)
    #expect(context.state.activeShortcut?.id == shortcut.id)
    #expect(context.state.verificationAttemptID == attemptBefore)
    #expect(context.defaults.string(
        forKey: FirstShortcutOnboardingState.pendingShortcutIDDefaultsKey
    ) == pendingBefore)
}

@Test @MainActor
func unrelatedSwitchAndWrongShortcutCannotCompleteVerification() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: false
    )

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)
    #expect(context.state.phase == .verification(waitingForActivation: false))
    #expect(context.state.isAwaitingPhysicalVerification(for: shortcut.id))
    #expect(!context.state.isAwaitingPhysicalVerification(for: UUID()))

    let exactActivation = activationAttempt(for: shortcut)
    let wrongShortcut = onboardingShortcut()
    context.state.capturedShortcutTriggered(
        wrongShortcut,
        accepted: true,
        activationAttempt: activationAttempt(for: wrongShortcut)
    )
    #expect(context.state.phase == .verification(waitingForActivation: false))
    #expect(context.state.completion == nil)

    context.state.capturedShortcutTriggered(
        shortcut,
        accepted: true,
        activationAttempt: exactActivation
    )
    #expect(context.state.phase == .verification(waitingForActivation: true))
    #expect(!context.state.isAwaitingPhysicalVerification(for: shortcut.id))
    #expect(context.state.isWaitingForFrontmostConfirmation)

    // Same target bundle is insufficient: a Dock/Cmd-Tab switch carries no
    // matching AppSwitcher attempt ID/generation.
    let unrelatedIdentity = activationAttempt(for: shortcut).identity
    context.state.activationAttemptDidConfirm(unrelatedIdentity)
    #expect(context.state.phase == .verification(waitingForActivation: true))

    context.state.activationAttemptDidConfirm(exactActivation.identity)
    #expect(context.state.phase == .success)
    #expect(context.state.completion == .verified)
}

@Test @MainActor
func readinessRefreshPreservesTheMatchedVerificationAttempt() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: false
    )

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)
    let attemptID = try #require(context.state.verificationAttemptID)
    let activation = activationAttempt(for: shortcut)
    context.state.capturedShortcutTriggered(
        shortcut,
        accepted: true,
        activationAttempt: activation
    )

    context.state.refreshReadiness()

    #expect(context.state.verificationAttemptID == attemptID)
    #expect(context.state.phase == .verification(waitingForActivation: true))

    // The selected target can itself be an enabled exception rule. Its
    // didActivate notification auto-pauses capture before AppSwitcher's
    // confirmation callback; that transient readiness loss must not erase the
    // exact activation session already owned by the physical match.
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: false,
        shortcutsPaused: true,
        secureInputActive: false
    )
    context.state.refreshReadiness()
    #expect(context.state.phase == .verification(waitingForActivation: true))

    context.state.activationAttemptDidConfirm(activation.identity)
    #expect(context.state.completion == .verified)

    context.state.refreshReadiness()
    #expect(context.state.phase == .success)
}

@Test @MainActor
func mutatingTheMatchedBindingInvalidatesItsOwnedActivationProof() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: false
    )

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)
    let activation = activationAttempt(for: shortcut)
    context.state.capturedShortcutTriggered(
        shortcut,
        accepted: true,
        activationAttempt: activation
    )
    #expect(context.state.phase == .verification(waitingForActivation: true))

    let disabled = AppShortcut(
        id: shortcut.id,
        appName: shortcut.appName,
        bundleIdentifier: shortcut.bundleIdentifier,
        keyEquivalent: shortcut.keyEquivalent,
        modifierFlags: shortcut.modifierFlags,
        isEnabled: false
    )
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: false,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: false,
        shortcutsPaused: false,
        secureInputActive: false
    )
    context.state.synchronize(shortcuts: [disabled])

    #expect(context.state.phase == .failure(.shortcutUnavailable))
    #expect(context.state.verificationAttemptID == nil)
    context.state.activationAttemptDidConfirm(activation.identity)
    #expect(context.state.completion == nil)
}

@Test @MainActor
func alreadyConfirmedActivationSnapshotClosesTheCallbackRace() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .hyper,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: false
    )

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)

    context.state.capturedShortcutTriggered(
        shortcut,
        accepted: true,
        targetWasFrontmost: false,
        activationAttempt: activationAttempt(for: shortcut, isConfirmed: true)
    )

    #expect(context.state.phase == .success)
    #expect(context.state.completion == .verified)
    #expect(context.spy.scheduledTimeouts.isEmpty)
}

@Test @MainActor
func aPressThatStartedWithTheTargetFrontmostCannotVerifyAHide() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: false
    )

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)

    context.state.capturedShortcutTriggered(
        shortcut,
        accepted: true,
        targetWasFrontmost: true
    )

    #expect(context.state.phase == .failure(.targetAlreadyFrontmost))
    #expect(context.state.completion == nil)
    #expect(context.spy.scheduledTimeouts.isEmpty)
}

@Test @MainActor
func acceptedTriggerWithoutAnOwnedActivationSessionFailsClosed() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: false
    )

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)
    context.state.capturedShortcutTriggered(shortcut, accepted: true)

    #expect(context.state.phase == .failure(.activationRejected))
    #expect(context.state.completion == nil)
    #expect(context.spy.scheduledTimeouts.isEmpty)
}

@Test @MainActor
func systemSettingsDestinationFollowsTheSelectedCaptureRoute() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)
    context.state.openSystemSettings()

    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .hyper,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: false,
        shortcutsPaused: false,
        secureInputActive: false
    )
    context.state.refreshReadiness()
    context.state.openSystemSettings()

    #expect(context.spy.openedDestinations == [.accessibility, .inputMonitoring])
}

@Test @MainActor
func secureInputBlocksOnlyTapDependentOnboardingRoutes() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: true
    )
    context.state.shortcutWasAdded(shortcut)
    #expect(!context.state.selectedRouteIsBlockedBySecureInput)

    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .hyper,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        routeReady: false,
        shortcutsPaused: false,
        secureInputActive: true
    )
    context.state.refreshReadiness()
    #expect(context.state.selectedRouteIsBlockedBySecureInput)
}

@Test @MainActor
func unavailableSavedShortcutFailsClosed() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: false,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: false,
        shortcutsPaused: false,
        secureInputActive: false
    )

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)

    #expect(context.state.phase == .failure(.shortcutUnavailable))
    #expect(context.state.completion == nil)
}

@Test @MainActor
func rejectedAndTimedOutAttemptsStayIncompleteAndCanRetry() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .hyper,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: false
    )

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)
    let firstAttempt = try #require(context.state.verificationAttemptID)

    context.state.capturedShortcutTriggered(shortcut, accepted: false)
    #expect(context.state.phase == .failure(.activationRejected))
    #expect(context.state.completion == nil)

    context.state.retry()
    let secondAttempt = try #require(context.state.verificationAttemptID)
    #expect(secondAttempt != firstAttempt)
    let activation = activationAttempt(for: shortcut)
    context.state.capturedShortcutTriggered(
        shortcut,
        accepted: true,
        activationAttempt: activation
    )
    #expect(context.spy.scheduledTimeouts.count == 1)
    #expect(context.spy.scheduledTimeoutDurations == [.seconds(6)])
    context.spy.scheduledTimeouts[0]()
    #expect(context.state.phase == .failure(.activationTimedOut))
    #expect(context.state.completion == nil)

    context.state.activationAttemptDidConfirm(activation.identity)
    #expect(context.state.phase == .failure(.activationTimedOut))
    context.state.retry()
    #expect(context.state.verificationAttemptID != secondAttempt)
}

@Test @MainActor
func skipAfterFailureEndsTheOptionalGuideAndClearsThePendingAttempt() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: false
    )

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)
    context.state.capturedShortcutTriggered(shortcut, accepted: false)
    #expect(context.state.phase == .failure(.activationRejected))

    context.state.skip()

    #expect(context.state.phase == .hidden)
    #expect(context.state.completion == .skipped)
    #expect(context.defaults.string(
        forKey: FirstShortcutOnboardingState.pendingShortcutIDDefaultsKey
    ) == nil)
}

@Test @MainActor
func deletingTheInProgressShortcutReturnsToConfiguration() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)
    context.state.synchronize(shortcuts: [])

    #expect(context.state.phase == .configure)
    #expect(context.state.activeShortcut == nil)
    #expect(context.state.completion == nil)
}

@Test @MainActor
func deletingTheVerifiedShortcutBeforeFinishKeepsSuccessTerminal() throws {
    let context = try FirstShortcutOnboardingTestContext()
    defer { context.cleanup() }
    let shortcut = onboardingShortcut()
    context.spy.readiness = FirstShortcutOnboardingReadiness(
        route: .standard,
        shortcutAvailable: true,
        accessibilityGranted: true,
        inputMonitoringGranted: false,
        routeReady: true,
        shortcutsPaused: false,
        secureInputActive: false
    )

    _ = context.state.prepareForLaunch(shortcuts: [], hasLegacyCompletion: false)
    context.state.continueFromIntroduction()
    context.state.shortcutWasAdded(shortcut)
    context.state.capturedShortcutTriggered(
        shortcut,
        accepted: true,
        activationAttempt: activationAttempt(for: shortcut, isConfirmed: true)
    )
    #expect(context.state.phase == .success)
    #expect(context.state.completion == .verified)

    context.state.synchronize(shortcuts: [])

    #expect(context.state.phase == .success)
    #expect(context.state.activeShortcut?.id == shortcut.id)
    #expect(context.state.completion == .verified)
}
