import AppKit
import Testing
@testable import Wink

@Test @MainActor
func launchPathCreatesOwnedPendingStateForNotRunningTarget() {
    let clock = ToggleLaunchLifecycleClock(time: 100)
    let appURL = URL(fileURLWithPath: "/Applications/TestTarget.app")
    var openedURLs: [URL] = []
    let coordinator = ToggleSessionCoordinator(now: { clock.time })
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForToggleLaunchLifecycleTests(currentFrontmost: "com.apple.Terminal"),
        fallbackActivationClient: .init(openApplication: { url, _, completion in
            openedURLs.append(url)
            completion(nil, nil)
        }),
        appLookupClient: .init(
            runningApplications: { _ in [] },
            applicationURL: { _ in appURL }
        ),
        confirmationClient: .init(
            now: { clock.time },
            schedule: { _, _ in }
        ),
        sessionCoordinator: coordinator
    )
    let shortcut = AppShortcut(
        appName: "TestTarget",
        bundleIdentifier: "com.test.Target",
        keyEquivalent: "t",
        modifierFlags: ["command"]
    )

    let accepted = switcher.toggleApplication(for: shortcut)

    #expect(accepted == true)
    #expect(openedURLs == [appURL])
    #expect(switcher.pendingActivationState?.bundleIdentifier == shortcut.bundleIdentifier)
    #expect(coordinator.session(for: shortcut.bundleIdentifier)?.phase == .launching)
}

@Test @MainActor
func launchCompletionAttachesOwnedSessionToConfirmationPipeline() async {
    guard let launchedApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = launchedApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for launch lifecycle test")
        return
    }

    let clock = ToggleLaunchLifecycleClock(time: 150)
    let scheduler = ToggleLaunchLifecycleScheduler()
    let appURL = URL(fileURLWithPath: "/Applications/TestTarget.app")
    let coordinator = ToggleSessionCoordinator(now: { clock.time })
    var isRunning = false
    var windowObservations = [
        ApplicationObservation.WindowObservation(
            windows: nil,
            visibleWindowCount: 0,
            hasFocusedWindow: false,
            hasMainWindow: false,
            windowsReadSucceeded: true,
            failureReason: nil
        ),
        ApplicationObservation.WindowObservation(
            windows: nil,
            visibleWindowCount: 1,
            hasFocusedWindow: true,
            hasMainWindow: true,
            windowsReadSucceeded: true,
            failureReason: nil
        )
    ]
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForToggleLaunchLifecycleTests(currentFrontmost: "com.apple.Terminal"),
        applicationObservation: ApplicationObservation(client: .init(
            currentFrontmostBundleIdentifier: { bundleIdentifier },
            windowObservation: { _ in
                if windowObservations.count > 1 {
                    return windowObservations.removeFirst()
                }
                return windowObservations[0]
            },
            activationPolicy: { _ in .regular }
        )),
        fallbackActivationClient: .init(openApplication: { _, _, completion in
            isRunning = true
            completion(launchedApp, nil)
        }),
        appLookupClient: .init(
            runningApplications: { _ in
                isRunning ? [launchedApp] : []
            },
            applicationURL: { _ in appURL }
        ),
        confirmationClient: .init(
            now: { clock.time },
            schedule: { delay, operation in
                scheduler.schedule(after: delay, operation)
            }
        ),
        sessionCoordinator: coordinator
    )
    let shortcut = AppShortcut(
        appName: "TestTarget",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "t",
        modifierFlags: ["command"]
    )

    let accepted = switcher.toggleApplication(for: shortcut)
    await Task.yield()

    #expect(accepted == true)
    #expect(coordinator.session(for: bundleIdentifier)?.phase == .activating)

    scheduler.runNext()

    #expect(switcher.stableActivationState?.bundleIdentifier == bundleIdentifier)
    #expect(coordinator.session(for: bundleIdentifier)?.phase == .activeStable)
}

@Test @MainActor
func terminationImmediatelyClearsStableActivationState() {
    let clock = ToggleLaunchLifecycleClock(time: 200)
    let coordinator = ToggleSessionCoordinator(now: { clock.time })
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForToggleLaunchLifecycleTests(),
        confirmationClient: .init(
            now: { clock.time },
            schedule: { _, _ in }
        ),
        sessionCoordinator: coordinator
    )

    let pending = switcher.acceptPendingActivation(
        for: "com.apple.Safari",
        startedAt: clock.time
    )
    clock.time = 201
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
    #expect(switcher.stableActivationState?.bundleIdentifier == "com.apple.Safari")

    coordinator.handleTermination(bundleIdentifier: "com.apple.Safari")

    #expect(coordinator.session(for: "com.apple.Safari") == nil)
    #expect(switcher.stableActivationState == nil)
}

@Test @MainActor
func secondPressAfterOwnedLaunchUsesTrackedHideInsteadOfHideUntracked() async {
    guard let launchedApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = launchedApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for second-press launch lifecycle test")
        return
    }

    let clock = ToggleLaunchLifecycleClock(time: 300)
    let scheduler = ToggleLaunchLifecycleScheduler()
    let appURL = URL(fileURLWithPath: "/Applications/TestTarget.app")
    let coordinator = ToggleSessionCoordinator(now: { clock.time })
    var isRunning = false
    var hideCalls = 0
    var windowObservations = [
        ApplicationObservation.WindowObservation(
            windows: nil,
            visibleWindowCount: 0,
            hasFocusedWindow: false,
            hasMainWindow: false,
            windowsReadSucceeded: true,
            failureReason: nil
        ),
        ApplicationObservation.WindowObservation(
            windows: nil,
            visibleWindowCount: 1,
            hasFocusedWindow: true,
            hasMainWindow: true,
            windowsReadSucceeded: true,
            failureReason: nil
        ),
        ApplicationObservation.WindowObservation(
            windows: nil,
            visibleWindowCount: 1,
            hasFocusedWindow: true,
            hasMainWindow: true,
            windowsReadSucceeded: true,
            failureReason: nil
        )
    ]
    let switcher = AppSwitcher(
        frontmostTracker: makeTrackerForToggleLaunchLifecycleTests(currentFrontmost: "com.apple.Terminal"),
        applicationObservation: ApplicationObservation(client: .init(
            currentFrontmostBundleIdentifier: { bundleIdentifier },
            windowObservation: { _ in
                if windowObservations.count > 1 {
                    return windowObservations.removeFirst()
                }
                return windowObservations[0]
            },
            activationPolicy: { _ in .regular }
        )),
        fallbackActivationClient: .init(openApplication: { _, _, completion in
            isRunning = true
            completion(launchedApp, nil)
        }),
        hideRequestClient: .init(hideApplication: { _ in
            hideCalls += 1
            return true
        }),
        appLookupClient: .init(
            runningApplications: { _ in
                isRunning ? [launchedApp] : []
            },
            applicationURL: { _ in appURL }
        ),
        confirmationClient: .init(
            now: { clock.time },
            schedule: { delay, operation in
                scheduler.schedule(after: delay, operation)
            }
        ),
        sessionCoordinator: coordinator
    )
    let shortcut = AppShortcut(
        appName: "TestTarget",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "t",
        modifierFlags: ["command"]
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)
    await Task.yield()
    scheduler.runNext()
    #expect(switcher.stableActivationState?.bundleIdentifier == bundleIdentifier)

    clock.time += 0.5
    #expect(switcher.toggleApplication(for: shortcut) == true)

    #expect(switcher.pendingDeactivationState?.activationPath == .hide)
    scheduler.runNext()
    #expect(hideCalls == 1)
}

@MainActor
private func makeTrackerForToggleLaunchLifecycleTests(currentFrontmost: String? = nil) -> FrontmostApplicationTracker {
    FrontmostApplicationTracker(client: .init(
        currentFrontmostBundleIdentifier: { currentFrontmost }
    ))
}

@MainActor
private final class ToggleLaunchLifecycleClock {
    var time: CFAbsoluteTime

    init(time: CFAbsoluteTime) {
        self.time = time
    }
}

@MainActor
private final class ToggleLaunchLifecycleScheduler {
    private var operations: [@MainActor () -> Void] = []

    func schedule(after _: TimeInterval, _ operation: @escaping @MainActor () -> Void) {
        operations.append(operation)
    }

    func runNext() {
        guard !operations.isEmpty else {
            Issue.record("Expected a scheduled launch confirmation operation")
            return
        }
        let operation = operations.removeFirst()
        operation()
    }
}
