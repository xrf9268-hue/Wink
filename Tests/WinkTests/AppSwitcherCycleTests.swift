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

@MainActor
private final class CycleActionRecorder {
    var activatedWindowIDs: [CGWindowID?] = []
    var raisedWindowIDs: [CGWindowID] = []
    var unminimizedWindowIDs: [CGWindowID] = []
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
    trackerBundle: String? = nil
) -> AppSwitcher {
    var psn = ProcessSerialNumber()
    psn.highLongOfPSN = 1
    psn.lowLongOfPSN = 2
    let minimizedElements = minimizedIDs.compactMap { windows.element(for: $0) }
    return AppSwitcher(
        frontmostTracker: FrontmostApplicationTracker(client: .init(
            currentFrontmostBundleIdentifier: { trackerBundle }
        )),
        applicationObservation: ApplicationObservation(client: .init(
            currentFrontmostBundleIdentifier: { bundleIdentifier },
            windowObservation: { _ in
                .init(
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
            }
        )
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
