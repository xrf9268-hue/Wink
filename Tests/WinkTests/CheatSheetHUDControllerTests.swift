import Foundation
import Testing
@testable import Wink

@MainActor
private final class CheatSheetHarness {
    var rows: [CheatSheetRow] = [
        CheatSheetRow(id: UUID(), appName: "Safari", bundleIdentifier: "com.apple.Safari", keyDisplay: "⌃⌥⇧⌘S")
    ]
    var enabled = true
    var presented: [[CheatSheetRow]] = []
    var dismissals = 0
    var scheduled: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []

    lazy var controller = CheatSheetHUDController(
        rowsProvider: { [unowned self] in self.rows },
        isEnabled: { [unowned self] in self.enabled },
        present: { [unowned self] rows in self.presented.append(rows) },
        dismiss: { [unowned self] in self.dismissals += 1 },
        schedule: { [unowned self] delay, fire in self.scheduled.append((delay, fire)) }
    )

    func fireTimer(_ index: Int = 0) {
        scheduled[index].fire()
    }
}

@Test @MainActor
func idleHoldPresentsAfterThresholdOnly() {
    let harness = CheatSheetHarness()
    harness.controller.handle(.began)
    #expect(harness.presented.isEmpty)
    #expect(harness.scheduled.count == 1)
    #expect(harness.scheduled[0].delay == CheatSheetHUDController.holdThreshold)

    harness.fireTimer()
    #expect(harness.presented.count == 1)
    #expect(harness.controller.isPresented)

    harness.controller.handle(.ended)
    #expect(harness.dismissals == 1)
    #expect(!harness.controller.isPresented)
}

@Test @MainActor
func chordBeforeThresholdCancelsWithoutPresenting() {
    let harness = CheatSheetHarness()
    harness.controller.handle(.began)
    harness.controller.handle(.chordConsumed)
    harness.fireTimer()
    #expect(harness.presented.isEmpty)
    #expect(harness.dismissals == 0)
}

@Test @MainActor
func autorepeatBeganDoesNotStackTimers() {
    let harness = CheatSheetHarness()
    harness.controller.handle(.began)
    harness.controller.handle(.began)
    harness.controller.handle(.began)
    #expect(harness.scheduled.count == 1)
}

@Test @MainActor
func staleTimerFromPreviousGestureNeverFires() {
    let harness = CheatSheetHarness()
    harness.controller.handle(.began)
    harness.controller.handle(.ended)
    // A new gesture starts before the old timer fires.
    harness.controller.handle(.began)
    harness.fireTimer(0)
    #expect(harness.presented.isEmpty)
    harness.fireTimer(1)
    #expect(harness.presented.count == 1)
}

@Test @MainActor
func disabledPreferenceAndEmptyRowsShowNothing() {
    let harness = CheatSheetHarness()
    harness.enabled = false
    harness.controller.handle(.began)
    #expect(harness.scheduled.isEmpty)

    harness.enabled = true
    harness.rows = []
    harness.controller.handle(.began)
    harness.fireTimer()
    #expect(harness.presented.isEmpty)
}

@Test @MainActor
func chordWhilePresentedDismisses() {
    let harness = CheatSheetHarness()
    harness.controller.handle(.began)
    harness.fireTimer()
    #expect(harness.controller.isPresented)

    harness.controller.handle(.chordConsumed)
    #expect(harness.dismissals == 1)
    #expect(!harness.controller.isPresented)
}

@Test @MainActor
func timerFireRechecksEnabledStateAfterMidHoldDisable() {
    let harness = CheatSheetHarness()
    harness.controller.handle(.began)
    // Hyper (or the sheet) disabled mid-hold: the tap clears its state
    // without emitting `ended`, so the armed timer must not present.
    harness.enabled = false
    harness.fireTimer()
    #expect(harness.presented.isEmpty)
}

@Test @MainActor
func resetDismissesPresentedSheetAndCancelsTimer() {
    let harness = CheatSheetHarness()
    harness.controller.handle(.began)
    harness.fireTimer()
    #expect(harness.controller.isPresented)

    harness.controller.reset()
    #expect(harness.dismissals == 1)
    #expect(!harness.controller.isPresented)
}
