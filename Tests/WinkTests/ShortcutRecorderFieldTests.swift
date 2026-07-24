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
            // weak, not unowned: the window-detach cancel retains the
            // callback beyond the field's lifetime and may run it after a
            // test's harness has been released.
            field.onCapture = { [weak self] in self?.captured.append($0) }
            field.onCancel = { [weak self] in self?.cancelCount += 1 }
            field.onLiveModifiersChange = { [weak self] in self?.liveModifiers.append($0) }
            field.onErrorChange = { [weak self] in self?.errorMessages.append($0) }
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

    /// A real window for resign-key notification posts: broadcasting the
    /// notification with `object: nil` trips an `NSRemoteView` assertion
    /// (`[window isKindOfClass:NSWindow.class]`) in CI test processes that
    /// host ViewBridge listeners — the production observer is unscoped, so
    /// any window object reaches it just the same.
    @MainActor
    private static func makeResigningWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
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
    func keyWindowResignationCancelsTheSession() {
        // #418 P2: the local monitor never sees events delivered to other
        // apps, so Cmd-Tab (or a click into another app) must end the
        // session through the resign-key observer — otherwise the dispatch
        // gate stays latched and swallows every matched chord globally.
        let harness = Harness()

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: Self.makeResigningWindow())

        #expect(harness.cancelCount == 1)
    }

    @Test @MainActor
    func keyWindowResignationIsIgnoredWhenNotRecording() {
        let harness = Harness(recording: false)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: Self.makeResigningWindow())

        #expect(harness.cancelCount == 0)
    }

    @Test @MainActor
    func keyWindowResignationIsIgnoredAfterRecordingEnds() {
        let harness = Harness()
        harness.field.updateRecordingState(isRecording: false)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: Self.makeResigningWindow())

        #expect(harness.cancelCount == 0)
    }

    @Test @MainActor
    func windowDetachCancelSurvivesFieldRelease() async {
        // #418 round-4 P1: SwiftUI can release the detached field before the
        // deferred cancel runs. The callback must be retained independently
        // of self — a weak-self guard would silently drop the cancel and
        // leave the dispatch gate latched with no live recorder.
        var cancelCount = 0
        var field: RecorderField? = RecorderField()
        field?.onCancel = { cancelCount += 1 }
        field?.updateRecordingState(isRecording: true)

        field?.viewWillMove(toWindow: nil)
        field = nil

        // Queue behind the deferred cancel so it has run when we assert.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(cancelCount == 1)
    }

    @Test @MainActor
    func failedMonitorRegistrationEndsTheSessionInsteadOfLatchingTheGate() async {
        // Codex pre-push review (medium): NSEvent.addLocalMonitorForEvents
        // is nullable. A nil token with isRecording left true would keep
        // the dispatch gate latched with no way to capture or cancel from
        // inside the app.
        var cancelCount = 0
        let field = RecorderField()
        field.installMonitorImpl = { _, _ in nil }
        field.onCancel = { cancelCount += 1 }

        field.updateRecordingState(isRecording: true)

        #expect(!field.isMonitoringForTesting)
        // The resign observer must not install on the failure path either —
        // an unguarded retry used to stack a second unscoped observer and
        // orphan the first for the process lifetime.
        #expect(!field.isObservingResignKeyForTesting)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(cancelCount == 1)
    }

    @Test @MainActor
    func dismantleTeardownEndsTheSessionWithoutAnyWindowCallback() async {
        // A field discarded before it was ever attached to a window gets no
        // viewWillMove(toWindow:) at all — dismantleNSView must end the
        // session on its own or the monitor leaks and the gate stays latched.
        var cancelCount = 0
        let field = RecorderField()
        field.onCancel = { cancelCount += 1 }
        field.updateRecordingState(isRecording: true)
        #expect(field.isMonitoringForTesting)

        field.endSessionForTeardown()

        #expect(!field.isMonitoringForTesting)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(cancelCount == 1)

        // Idempotent: the window-detach path may fire after dismantle.
        field.endSessionForTeardown()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(cancelCount == 1)
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

    @Test @MainActor
    func staleTeardownCancelIsSuppressedWhenASuccessorSessionStarts() async {
        // #420: the teardown cancel is queued a tick out and writes the
        // shared lane flag unconditionally. If a successor session starts
        // in the same lane before the block drains (generation bump), the
        // stale cancel must not end it on arrival.
        var cancelCount = 0
        var generation: UInt64 = 1
        let field = RecorderField()
        field.onCancel = { cancelCount += 1 }
        field.sessionGenerationProvider = { generation }
        field.updateRecordingState(isRecording: true)

        field.endSessionForTeardown()
        // Successor session starts before the deferred cancel drains.
        generation = 2

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(cancelCount == 0)
    }

    @Test @MainActor
    func teardownCancelStillFiresWhenNoSuccessorStarts() async {
        // The #418 contract stands: with no successor session, the deferred
        // cancel must land — a skipped cancel here leaves the #417 dispatch
        // gate latched with no live recorder.
        var cancelCount = 0
        let generation: UInt64 = 7
        let field = RecorderField()
        field.onCancel = { cancelCount += 1 }
        field.sessionGenerationProvider = { generation }
        field.updateRecordingState(isRecording: true)

        field.endSessionForTeardown()

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(cancelCount == 1)
    }

    @Test @MainActor
    func liveCancelIgnoresGenerationMismatch() {
        // Only the deferred teardown path is generation-guarded. A live
        // cancel (escape here; outside click and key-window resignation
        // share the same direct onCancel call) reflects a real user action
        // against the CURRENT session and must never be suppressed.
        var cancelCount = 0
        var generation: UInt64 = 1
        let field = RecorderField()
        field.onCancel = { cancelCount += 1 }
        field.sessionGenerationProvider = { generation }
        field.updateRecordingState(isRecording: true)
        generation = 99

        _ = field.handleMonitoredEvent(Self.keyEvent(keyCode: 53))

        #expect(cancelCount == 1)
    }
}
