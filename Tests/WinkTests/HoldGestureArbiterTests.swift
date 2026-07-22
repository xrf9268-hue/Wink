import AppKit
import Carbon.HIToolbox
import Testing
@testable import Wink

@Suite("Hold gesture arbiter")
@MainActor
struct HoldGestureArbiterTests {
    // @unchecked Sendable so the @Sendable physical-state seam can capture
    // it; every access in these tests happens on the main actor.
    private final class Harness: @unchecked Sendable {
        var taps: [(KeyPress, TimeInterval)] = []
        var holds: [KeyPress] = []
        var pendingDeadlines: [@MainActor () -> Void] = []
        var physicallyHeld = true
        var clock: CFAbsoluteTime = 1000

        @MainActor
        func makeArbiter(threshold: TimeInterval = 0.3) -> HoldGestureArbiter {
            HoldGestureArbiter(
                configuration: HoldGestureArbiter.Configuration(holdThreshold: threshold),
                physicalState: ChordPhysicalStateClient { [weak self] _ in
                    // Test-only: the harness outlives the arbiter in every test.
                    MainActor.assumeIsolated { self?.physicallyHeld ?? false }
                },
                now: { [weak self] in
                    MainActor.assumeIsolated { self?.clock ?? 0 }
                },
                scheduleDeadline: { [weak self] _, work in
                    MainActor.assumeIsolated { self?.pendingDeadlines.append(work) }
                },
                onTap: { [weak self] keyPress, duration in
                    self?.taps.append((keyPress, duration))
                },
                onHold: { [weak self] keyPress in
                    self?.holds.append(keyPress)
                }
            )
        }

        @MainActor
        func fireDeadlines() {
            let deadlines = pendingDeadlines
            pendingDeadlines = []
            deadlines.forEach { $0() }
        }
    }

    private let chord = KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command])

    @Test
    func upBeforeDeadlineIsATapWithMeasuredDuration() {
        let harness = Harness()
        let arbiter = harness.makeArbiter()

        arbiter.handle(chord, .down)
        harness.clock += 0.12
        arbiter.handle(chord, .up)

        #expect(harness.taps.count == 1)
        #expect(harness.taps.first?.0 == chord)
        #expect(harness.taps.first.map { abs($0.1 - 0.12) < 0.001 } == true)
        #expect(harness.holds.isEmpty)

        // The now-stale deadline must not double-dispatch.
        harness.fireDeadlines()
        #expect(harness.taps.count == 1)
        #expect(harness.holds.isEmpty)
    }

    @Test
    func deadlineWithKeyStillDownIsAHoldAndLateUpIsCleanup() {
        let harness = Harness()
        let arbiter = harness.makeArbiter()

        arbiter.handle(chord, .down)
        harness.fireDeadlines()

        #expect(harness.holds == [chord])
        #expect(harness.taps.isEmpty)

        arbiter.handle(chord, .up)
        #expect(harness.taps.isEmpty, "the up after a dispatched hold is cleanup, not a tap")
    }

    @Test
    func deadlineWithKeyReleasedResolvesLostUpAsTap() {
        let harness = Harness()
        harness.physicallyHeld = false
        let arbiter = harness.makeArbiter()

        arbiter.handle(chord, .down)
        harness.clock += 0.3
        harness.fireDeadlines()

        #expect(harness.taps.count == 1, "a lost keyUp must degrade to a tap, never a hold under absent fingers")
        #expect(harness.holds.isEmpty)
    }

    @Test
    func resetDropsInFlightGesturesWithoutDispatching() {
        let harness = Harness()
        let arbiter = harness.makeArbiter()

        arbiter.handle(chord, .down)
        arbiter.reset()
        harness.fireDeadlines()
        arbiter.handle(chord, .up)

        #expect(harness.taps.isEmpty)
        #expect(harness.holds.isEmpty)
    }

    @Test
    func duplicateDownDoesNotRestartTheClock() {
        let harness = Harness()
        let arbiter = harness.makeArbiter()

        arbiter.handle(chord, .down)
        arbiter.handle(chord, .down)

        #expect(harness.pendingDeadlines.count == 1, "an unfiltered autorepeat down must not schedule a second deadline")
    }

    @Test
    func interleavedChordsResolveIndependently() {
        let harness = Harness()
        let arbiter = harness.makeArbiter()
        let other = KeyPress(keyCode: CGKeyCode(kVK_ANSI_B), modifiers: [.command])

        arbiter.handle(chord, .down)
        arbiter.handle(other, .down)
        arbiter.handle(other, .up)
        harness.fireDeadlines()

        #expect(harness.taps.map(\.0) == [other])
        #expect(harness.holds == [chord])
    }
}

@Suite("Phased chord autorepeat swallow")
struct PhasedAutorepeatSwallowTests {
    @Test
    func autorepeatDownOfPhasedChordIsSwallowedWithoutDelivery() {
        let keyPress = KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command])
        let box = EventTapBox()
        box.registeredShortcuts = [keyPress]
        box.phasedChords = [keyPress]
        nonisolated(unsafe) var deliveries = 0
        box.setPhasedKeyObserver { _, _ in deliveries += 1 }
        nonisolated(unsafe) var legacyDeliveries = 0
        box.onKeyPress = { _ in legacyDeliveries += 1 }

        let event = makeAutorepeatKeyDown(keyPress)
        let result = handleEventTapEvent(type: .keyDown, event: event, box: box)

        #expect(result == nil, "a held hold-gesture chord must not autorepeat into the frontmost app")
        #expect(deliveries == 0)
        #expect(legacyDeliveries == 0)
    }

    @Test
    func autorepeatDownOfNonPhasedChordKeepsPassingThrough() {
        let keyPress = KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command])
        let box = EventTapBox()
        box.registeredShortcuts = [keyPress]

        let event = makeAutorepeatKeyDown(keyPress)
        let result = handleEventTapEvent(type: .keyDown, event: event, box: box)

        #expect(result != nil, "pre-existing autorepeat pass-through contract must hold for non-phased chords")
    }

    private func makeAutorepeatKeyDown(_ keyPress: KeyPress) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyPress.keyCode,
            keyDown: true
        )!
        event.flags = CGEventFlags(rawValue: UInt64(keyPress.modifiers.rawValue))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        return event
    }
}
