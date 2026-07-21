import AppKit
import ApplicationServices
import Testing
@testable import Wink

// MARK: - Helpers

@MainActor
private final class CycleTestClock {
    var time: CFAbsoluteTime

    init(time: CFAbsoluteTime) {
        self.time = time
    }
}

/// Mutable flag box: capturing a local `var` in the sendable observation
/// closure trips "mutated after capture by sendable closure"; a
/// main-actor box keeps the mutation warning-free.
@MainActor
private final class CycleTestFlag {
    var value = false
}

@MainActor
private final class CycleActionRecorder {
    var activatedWindowIDs: [CGWindowID?] = []
    var raisedWindowIDs: [CGWindowID] = []
    var unminimizedWindowIDs: [CGWindowID] = []
    var madeKeyWindowIDs: [CGWindowID] = []
    var hideCalls = 0
}

/// AXUIElement tokens are only used as identity keys by the injected
/// WindowCycleClient fakes — no AX IPC happens in these tests. Distinct pids
/// produce distinct, CFEqual-distinguishable tokens.
@MainActor
private struct CycleTestWindows {
    let elements: [AXUIElement]
    let idsByIndex: [CGWindowID]

    init(ids: [CGWindowID]) {
        self.idsByIndex = ids
        self.elements = (0..<ids.count).map { AXUIElementCreateApplication(pid_t(90_000 + $0)) }
    }

    func windowID(for element: AXUIElement) -> CGWindowID? {
        for (index, candidate) in elements.enumerated() where CFEqual(candidate, element) {
            return idsByIndex[index]
        }
        return nil
    }

    func element(for id: CGWindowID) -> AXUIElement? {
        guard let index = idsByIndex.firstIndex(of: id) else { return nil }
        return elements[index]
    }
}

@MainActor
private func makeCycleSwitcher(
    frontmostApp: NSRunningApplication,
    bundleIdentifier: String,
    windows: CycleTestWindows,
    minimizedIDs: [CGWindowID] = [],
    focusedWindowID: @escaping () -> CGWindowID?,
    recorder: CycleActionRecorder,
    clock: CycleTestClock,
    scheduler: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { _, _ in },
    trackerBundle: String? = nil,
    trackerApp: NSRunningApplication? = nil,
    windowsReadFails: @escaping @MainActor () -> Bool = { false },
    windowCycleCoordinator: WindowCycleCoordinator? = nil
) -> AppSwitcher {
    var psn = ProcessSerialNumber()
    psn.highLongOfPSN = 1
    psn.lowLongOfPSN = 2
    let minimizedElements = minimizedIDs.compactMap { windows.element(for: $0) }
    return AppSwitcher(
        frontmostTracker: FrontmostApplicationTracker(client: .init(
            currentFrontmostBundleIdentifier: { trackerBundle },
            currentFrontmostApplication: { trackerApp }
        )),
        applicationObservation: ApplicationObservation(client: .init(
            currentFrontmostBundleIdentifier: { bundleIdentifier },
            windowObservation: { _ in
                if windowsReadFails() {
                    // Failed windows read with surviving focused/main
                    // evidence keeps the snapshot stable-classified — the
                    // partial-AX-failure shape from the review.
                    return .init(
                        windows: nil,
                        visibleWindowCount: 0,
                        hasFocusedWindow: true,
                        hasMainWindow: true,
                        windowsReadSucceeded: false,
                        failureReason: "test_injected_failure"
                    )
                }
                return .init(
                    windows: windows.elements,
                    minimizedWindows: minimizedElements,
                    visibleWindowCount: windows.elements.count - minimizedElements.count,
                    hasFocusedWindow: true,
                    hasMainWindow: true,
                    windowsReadSucceeded: true,
                    failureReason: nil
                )
            },
            activationPolicy: { _ in .regular }
        )),
        activationClient: .init(activateFrontProcess: { _, windowID in
            recorder.activatedWindowIDs.append(windowID)
            return .success(psn)
        }),
        hideRequestClient: .init(hideApplication: { _ in
            recorder.hideCalls += 1
            return true
        }),
        appLookupClient: .init(
            runningApplications: { _ in [frontmostApp] },
            applicationURL: { _ in nil }
        ),
        confirmationClient: .init(
            now: { clock.time },
            schedule: { delay, operation in
                scheduler(delay, operation)
            }
        ),
        windowCycleClient: .init(
            windowID: { element in
                windows.windowID(for: element)
            },
            focusedWindowID: { _ in
                focusedWindowID()
            },
            raiseWindow: { element in
                if let id = windows.windowID(for: element) {
                    recorder.raisedWindowIDs.append(id)
                }
            },
            unminimizeWindow: { element in
                if let id = windows.windowID(for: element) {
                    recorder.unminimizedWindowIDs.append(id)
                }
            },
            makeKeyWindow: { _, windowID in
                recorder.madeKeyWindowIDs.append(windowID)
            }
        ),
        windowCycleCoordinator: windowCycleCoordinator
    )
}

// MARK: - Tests

@Test @MainActor
func cycleBehaviorFocusesNextWindowInsteadOfHiding() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for cycle test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.activatedWindowIDs == [102])
    #expect(recorder.madeKeyWindowIDs == [102])
    #expect(recorder.raisedWindowIDs == [102])
    #expect(recorder.hideCalls == 0)
    #expect(switcher.pendingDeactivationState == nil)
}

@Test @MainActor
func cycleRepeatPressesRotateThroughAllWindowsDespiteStaleFocus() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for cycle rotation test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102, 103])
    // AX focus keeps reporting 101 (lags rapid presses); the session cursor
    // must still visit every window and wrap.
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        trackerBundle: bundleIdentifier
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)
    clock.time += 0.2
    #expect(switcher.toggleApplication(for: shortcut) == true)
    clock.time += 0.2
    #expect(switcher.toggleApplication(for: shortcut) == true)

    #expect(recorder.raisedWindowIDs == [102, 103, 101])
    #expect(recorder.hideCalls == 0)
}

@Test @MainActor
func cycleUnminimizesMinimizedTargetWindow() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for cycle unminimize test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        minimizedIDs: [102],
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.unminimizedWindowIDs == [102])
    #expect(recorder.raisedWindowIDs == [102])
}

@Test @MainActor
func cycleWithSingleWindowFallsBackToToggleSemantics() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for cycle fallback test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101])
    var scheduled: [@MainActor () -> Void] = []
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        scheduler: { _, operation in
            scheduled.append(operation)
        }
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    // One window: no cycle. The untracked-frontmost toggle lane takes over
    // and requests a hide, exactly as .toggle would.
    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.raisedWindowIDs.isEmpty)
    #expect(switcher.pendingDeactivationState?.activationPath == .hideUntracked)

    for operation in scheduled {
        operation()
    }
    #expect(recorder.hideCalls == 1)
}

@Test @MainActor
func cyclePressesUseShorterCooldownThanStandardToggle() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for cycle cooldown test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        trackerBundle: bundleIdentifier
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)

    // 0.2s later: inside the standard 0.4s cooldown but past the 0.15s
    // cycle cooldown — the press must go through.
    clock.time = 100.2
    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.raisedWindowIDs == [102, 101])

    // 0.1s later: still inside the cycle cooldown — blocked.
    clock.time = 100.3
    #expect(switcher.toggleApplication(for: shortcut) == false)
    #expect(recorder.raisedWindowIDs == [102, 101])
}

@Test @MainActor
func cycleSingleWindowRepeatPressStaysBehindStandardCooldown() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for single-window cooldown test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101])
    var scheduled: [@MainActor () -> Void] = []
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        scheduler: { _, operation in
            scheduled.append(operation)
        },
        trackerBundle: bundleIdentifier
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    // Single window: no cycle session is ever created, so the relaxed
    // 150ms cooldown must not apply — a quick second press stays blocked
    // exactly as it would under .toggle/.hide (issue #347 AC: "no behavior
    // change" for single-window targets).
    #expect(switcher.toggleApplication(for: shortcut) == true)
    clock.time = 100.2
    #expect(switcher.toggleApplication(for: shortcut) == false)
}

@Test @MainActor
func cycleWindowsReadFailureMidGestureSwallowsPressInsteadOfHiding() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for read-failure swallow test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    let readFails = CycleTestFlag()
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        trackerBundle: bundleIdentifier,
        windowsReadFails: { readFails.value }
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.raisedWindowIDs == [102])

    // Mid-gesture the AX windows read starts failing transiently: the
    // press must be swallowed, never fall through to the hide lanes.
    readFails.value = true
    clock.time = 100.2
    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.raisedWindowIDs == [102])
    #expect(recorder.hideCalls == 0)
    #expect(switcher.pendingDeactivationState == nil)
}

@Test @MainActor
func cycleWindowsReadFailureWithStaleSessionFallsBackToToggle() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for stale-session read-failure test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    let readFails = CycleTestFlag()
    var scheduled: [@MainActor () -> Void] = []
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        scheduler: { _, operation in
            scheduled.append(operation)
        },
        trackerBundle: bundleIdentifier,
        windowsReadFails: { readFails.value }
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.raisedWindowIDs == [102])

    // The gesture went idle past the session expiry; a later press that
    // hits a transient read failure is NOT mid-gesture and must fall
    // through to standard toggle semantics rather than being swallowed.
    readFails.value = true
    clock.time = 104
    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.raisedWindowIDs == [102])
    #expect(switcher.pendingDeactivationState?.activationPath == .hideUntracked)
}

@Test @MainActor
func cycleWindowsReadFailureWithoutGestureFallsBackToToggle() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for read-failure fallback test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    var scheduled: [@MainActor () -> Void] = []
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        scheduler: { _, operation in
            scheduled.append(operation)
        },
        windowsReadFails: { true }
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    // No gesture in flight: a failed windows read declines the cycle and
    // the press falls through to the untracked hide lane as before.
    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.raisedWindowIDs.isEmpty)
    #expect(switcher.pendingDeactivationState?.activationPath == .hideUntracked)
}

@Test @MainActor
func invalidateWindowCycleSessionDropsLiveCursor() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for invalidation test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    let coordinator = WindowCycleCoordinator(now: { clock.time })
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        windowCycleCoordinator: coordinator
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(coordinator.session != nil)

    // Shortcut configuration changed (e.g. an override edited): the
    // in-flight cursor must not survive to steer the next gesture.
    switcher.invalidateWindowCycleSession(reason: "shortcut_configuration_changed")
    #expect(coordinator.session == nil)
}

@Test @MainActor
func changingBehaviorAwayFromCycleInvalidatesLiveSession() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for behavior-change test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    let coordinator = WindowCycleCoordinator(now: { clock.time })
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        windowCycleCoordinator: coordinator
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(coordinator.session != nil)

    switcher.setFrontmostTargetBehavior(.toggle)
    #expect(coordinator.session == nil)
}

@Test @MainActor
func changingGlobalBehaviorToCycleAlsoInvalidatesOverrideCreatedSession() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for global-to-cycle invalidation test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    let coordinator = WindowCycleCoordinator(now: { clock.time })
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        windowCycleCoordinator: coordinator
    )
    switcher.setFrontmostTargetBehavior(.toggle)

    // An override-Cycle shortcut creates a live session while the global
    // behavior is Toggle.
    let overrideShortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"],
        frontmostBehaviorOverride: .cycleWindows
    )
    #expect(switcher.toggleApplication(for: overrideShortcut) == true)
    #expect(coordinator.session != nil)

    // Switching the global TO Cycle must also drop the cursor: a second
    // shortcut on the same bundle following the new global would
    // otherwise inherit the stale cursor and the relaxed cooldown.
    switcher.setFrontmostTargetBehavior(.cycleWindows)
    #expect(coordinator.session == nil)
}

@Test @MainActor
func cycleRotationUnminimizesOnlyTheMinimizedStop() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for minimized rotation test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102, 103])
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        minimizedIDs: [102],
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        trackerBundle: bundleIdentifier
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)
    clock.time += 0.2
    #expect(switcher.toggleApplication(for: shortcut) == true)
    clock.time += 0.2
    #expect(switcher.toggleApplication(for: shortcut) == true)

    // Full rotation including the minimized stop; only that stop is
    // unminimized.
    #expect(recorder.raisedWindowIDs == [102, 103, 101])
    #expect(recorder.unminimizedWindowIDs == [102])
    #expect(recorder.hideCalls == 0)
}

@Test @MainActor
func cycleWorksWhenAllWindowsAreMinimized() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for all-minimized test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        minimizedIDs: [101, 102],
        focusedWindowID: { nil },
        recorder: recorder,
        clock: clock
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.raisedWindowIDs == [101])
    #expect(recorder.unminimizedWindowIDs == [101])
}

@Test @MainActor
func cycleBehaviorWithTargetNotFrontmostKeepsStandardCooldown() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for not-frontmost cooldown test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    // AX-driven lane sees the target frontmost (cycles, creates a session),
    // but the workspace tracker disagrees — the cooldown's third arm must
    // then keep the standard 400ms.
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        trackerBundle: nil
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"]
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.raisedWindowIDs == [102])

    clock.time = 100.2
    #expect(switcher.toggleApplication(for: shortcut) == false)
    #expect(recorder.raisedWindowIDs == [102])
}

@Test @MainActor
func perShortcutOverrideCyclesWhenGlobalBehaviorIsToggle() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for override-cycle test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        trackerBundle: bundleIdentifier
    )
    switcher.setFrontmostTargetBehavior(.toggle)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "c",
        modifierFlags: ["command", "option"],
        frontmostBehaviorOverride: .cycleWindows
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.raisedWindowIDs == [102])
    #expect(recorder.hideCalls == 0)
    #expect(switcher.pendingDeactivationState == nil)

    // The override also earns the established-cycle cooldown: a second
    // press 0.2s later goes through even though the global behavior would
    // have used the 0.4s gate.
    clock.time = 100.2
    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.raisedWindowIDs == [102, 101])
}

@Test @MainActor
func perShortcutOverrideHidesWhenGlobalBehaviorIsCycle() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for override-hide test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    var scheduled: [@MainActor () -> Void] = []
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        scheduler: { _, operation in
            scheduled.append(operation)
        }
    )
    switcher.setFrontmostTargetBehavior(.cycleWindows)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "h",
        modifierFlags: ["command", "option"],
        frontmostBehaviorOverride: .hide
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)
    #expect(recorder.raisedWindowIDs.isEmpty)
    #expect(switcher.pendingDeactivationState?.activationPath == .hideUntracked)

    for operation in scheduled {
        operation()
    }
    #expect(recorder.hideCalls == 1)
}

@Test @MainActor
func standardCooldownStillAppliesWhenBehaviorIsNotCycle() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for standard cooldown test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    var scheduled: [@MainActor () -> Void] = []
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        scheduler: { _, operation in
            scheduled.append(operation)
        },
        trackerBundle: bundleIdentifier
    )
    switcher.setFrontmostTargetBehavior(.hide)

    let shortcut = AppShortcut(
        appName: frontmostApp.localizedName ?? "Frontmost",
        bundleIdentifier: bundleIdentifier,
        keyEquivalent: "h",
        modifierFlags: ["command", "option"]
    )

    #expect(switcher.toggleApplication(for: shortcut) == true)

    // 0.2s later: inside the standard 0.4s cooldown and the behavior is not
    // Cycle, so the press stays blocked.
    clock.time = 100.2
    #expect(switcher.toggleApplication(for: shortcut) == false)
}

// MARK: - Frontmost-app pseudo-target

@MainActor
private func makeFrontmostTargetShortcut() -> AppShortcut {
    AppShortcut(
        appName: AppShortcut.frontmostTargetDisplayName,
        bundleIdentifier: AppShortcut.frontmostTargetSentinelBundleIdentifier,
        keyEquivalent: "`",
        modifierFlags: ["command", "option"],
        target: .frontmostApp
    )
}

@Test @MainActor
func frontmostPseudoTargetCyclesTheResolvedApp() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for pseudo-target test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        trackerBundle: bundleIdentifier,
        trackerApp: frontmostApp
    )
    // Global behavior is Toggle: the pseudo-target must still cycle
    // (resolution defaults its behavior to Cycle).
    switcher.setFrontmostTargetBehavior(.toggle)

    #expect(switcher.toggleApplication(for: makeFrontmostTargetShortcut()) == true)
    #expect(recorder.raisedWindowIDs == [102])
    #expect(recorder.hideCalls == 0)
    #expect(switcher.pendingDeactivationState == nil)

    // Established cycling gets the relaxed cooldown keyed on the RESOLVED
    // bundle, so a rapid second press rotates onward.
    clock.time = 100.2
    #expect(switcher.toggleApplication(for: makeFrontmostTargetShortcut()) == true)
    #expect(recorder.raisedWindowIDs == [102, 101])
}

@Test @MainActor
func frontmostPseudoTargetWithoutResolvableFrontmostIsRejected() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for pseudo-target rejection test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101, 102])
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        trackerApp: nil
    )
    switcher.setFrontmostTargetBehavior(.toggle)

    #expect(switcher.toggleApplication(for: makeFrontmostTargetShortcut()) == false)
    #expect(recorder.raisedWindowIDs.isEmpty)
    #expect(recorder.hideCalls == 0)
}

@Test @MainActor
func frontmostPseudoTargetSingleWindowIsANoOpNotAHide() {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleIdentifier = frontmostApp.bundleIdentifier else {
        Issue.record("Expected a frontmost application with a bundle identifier for pseudo-target no-op test")
        return
    }

    let clock = CycleTestClock(time: 100)
    let recorder = CycleActionRecorder()
    let windows = CycleTestWindows(ids: [101])
    var scheduled: [@MainActor () -> Void] = []
    let switcher = makeCycleSwitcher(
        frontmostApp: frontmostApp,
        bundleIdentifier: bundleIdentifier,
        windows: windows,
        focusedWindowID: { 101 },
        recorder: recorder,
        clock: clock,
        scheduler: { _, operation in
            scheduled.append(operation)
        },
        trackerBundle: bundleIdentifier,
        trackerApp: frontmostApp
    )
    switcher.setFrontmostTargetBehavior(.toggle)

    // "Cycle the current app" must never hide the app the user is in.
    #expect(switcher.toggleApplication(for: makeFrontmostTargetShortcut()) == true)
    #expect(recorder.raisedWindowIDs.isEmpty)
    #expect(switcher.pendingDeactivationState == nil)
    for operation in scheduled {
        operation()
    }
    #expect(recorder.hideCalls == 0)
}
