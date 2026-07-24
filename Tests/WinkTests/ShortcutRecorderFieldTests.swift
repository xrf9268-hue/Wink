import AppKit
import Testing
@testable import Wink

/// #417: `RecorderField` capture must not depend on first-responder status.
/// These tests drive `handleMonitoredEvent(_:)` — the session monitor's
/// routing seam — with synthesized `NSEvent`s on a field that has no window
/// and was never made first responder, exactly the state the live bug left
/// it in (SwiftUI kept `AXFocusedUIElement` on the settings sidebar).
@Suite("Shortcut recorder field")
struct ShortcutRecorderFieldTests {
    @MainActor
    private final class Harness {
        let field = RecorderField()
        var captured: [RecordedShortcut] = []
        var cancelCount = 0
        var liveModifiers: [[String]] = []
        var errorMessages: [String?] = []

        init(recording: Bool = true) {
            field.onCapture = { [unowned self] in captured.append($0) }
            field.onCancel = { [unowned self] in cancelCount += 1 }
            field.onLiveModifiersChange = { [unowned self] in liveModifiers.append($0) }
            field.onErrorChange = { [unowned self] in errorMessages.append($0) }
            field.updateRecordingState(isRecording: recording)
        }
    }

    @MainActor
    private static func keyEvent(
        type: NSEvent.EventType = .keyDown,
        keyCode: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @MainActor
    private static func mouseEvent(type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    @Test @MainActor
    func capturesChordWithoutFirstResponderAndSwallowsKeyDown() {
        let harness = Harness()
        // kVK_ANSI_A with a full non-Hyper modifier set
        let event = Self.keyEvent(keyCode: 0, characters: "a", modifiers: [.command, .option])

        let passthrough = harness.field.handleMonitoredEvent(event)

        #expect(passthrough == nil)
        #expect(harness.captured == [RecordedShortcut(keyEquivalent: "a", modifierFlags: ["option", "command"])])
        // The capture path clears any prior error explicitly: one nil entry.
        #expect(harness.errorMessages == [nil])
    }

    @Test @MainActor
    func modifierlessKeySurfacesErrorAndIsStillSwallowed() {
        let harness = Harness()

        let passthrough = harness.field.handleMonitoredEvent(Self.keyEvent(keyCode: 0, characters: "a"))

        #expect(passthrough == nil)
        #expect(harness.captured.isEmpty)
        #expect(harness.errorMessages.last != nil)
    }

    @Test @MainActor
    func escapeCancelsTheSession() {
        let harness = Harness()

        let passthrough = harness.field.handleMonitoredEvent(Self.keyEvent(keyCode: 53))

        #expect(passthrough == nil)
        #expect(harness.cancelCount == 1)
        #expect(harness.captured.isEmpty)
    }

    @Test @MainActor
    func flagsChangedUpdatesLiveModifiersAndPassesThrough() {
        let harness = Harness()
        let event = Self.keyEvent(type: .flagsChanged, keyCode: 55, modifiers: [.control, .shift])

        let passthrough = harness.field.handleMonitoredEvent(event)

        #expect(passthrough === event)
        #expect(harness.liveModifiers.last == ["control", "shift"])
    }

    @Test @MainActor
    func mouseDownOutsideTheFieldCancelsButPassesThrough() {
        // A windowless field can never contain the click — the "outside" case.
        let harness = Harness()
        let event = Self.mouseEvent()

        let passthrough = harness.field.handleMonitoredEvent(event)

        #expect(passthrough === event)
        #expect(harness.cancelCount == 1)
    }

    @Test @MainActor
    func eventsPassThroughUntouchedWhenNotRecording() {
        let harness = Harness(recording: false)
        let event = Self.keyEvent(keyCode: 0, characters: "a", modifiers: [.command])

        let passthrough = harness.field.handleMonitoredEvent(event)

        #expect(passthrough === event)
        #expect(harness.captured.isEmpty)
        #expect(harness.cancelCount == 0)
    }

    @Test @MainActor
    func sessionMonitorFollowsRecordingStateAndWindowDetach() {
        let harness = Harness(recording: false)
        #expect(!harness.field.isMonitoringForTesting)

        harness.field.updateRecordingState(isRecording: true)
        #expect(harness.field.isMonitoringForTesting)

        // Re-entrant updates (SwiftUI calls updateNSView repeatedly) must
        // not stack a second monitor; state stays installed.
        harness.field.updateRecordingState(isRecording: true)
        #expect(harness.field.isMonitoringForTesting)

        // Dismantling mid-recording (window detach) tears the monitor down
        // even though isRecording never flipped false.
        harness.field.viewWillMove(toWindow: nil)
        #expect(!harness.field.isMonitoringForTesting)

        harness.field.updateRecordingState(isRecording: true)
        harness.field.updateRecordingState(isRecording: false)
        #expect(!harness.field.isMonitoringForTesting)
    }
}
