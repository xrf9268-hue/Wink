import AppKit

/// Physical key-state probe for the missed-keyUp fallback. Same pattern as
/// `FunctionModifierSystemStateClient`: a struct-of-closures seam so tests
/// inject deterministic state while production reads the HID system state.
struct ChordPhysicalStateClient: Sendable {
    var isKeyPressed: @Sendable (CGKeyCode) -> Bool

    static let live = ChordPhysicalStateClient { keyCode in
        CGEventSource.keyState(.hidSystemState, key: keyCode)
    }
}

/// Resolves phased (down/up) chord deliveries into tap-vs-hold gestures for
/// hold-enabled shortcuts.
///
/// - down: starts a deadline; nothing dispatches yet. This is the latency
///   cost hold-enabled shortcuts opt into: a tap dispatches on its up edge,
///   so every tap gains its own press duration (~80–120ms typical).
/// - up before the deadline: the gesture was a tap → `onTap`.
/// - deadline with the key still physically down: a hold → `onHold`.
/// - deadline with the key already up (the up edge was lost — released
///   modifiers-first, device unplugged mid-gesture): resolve as a tap. The
///   phased channel is best-effort on the up edge by contract; this probe is
///   what keeps a lost keyUp from ever opening the hold UI under the user's
///   fingers or leaving a gesture stuck.
@MainActor
final class HoldGestureArbiter {
    struct Configuration {
        /// Hold threshold. Below the typical ~250ms+ autorepeat initial
        /// delay would misread deliberate slow taps as holds; well above it
        /// makes the picker feel unresponsive. 300ms matches the gap between
        /// the 150ms cycle cooldown and the 400ms toggle safety net.
        var holdThreshold: TimeInterval = 0.3

        init(holdThreshold: TimeInterval = 0.3) {
            self.holdThreshold = holdThreshold
        }
    }

    private struct Gesture {
        let generation: UInt64
        let startedAt: CFAbsoluteTime
    }

    private let configuration: Configuration
    private let physicalState: ChordPhysicalStateClient
    private let now: () -> CFAbsoluteTime
    private let scheduleDeadline: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let onTap: @MainActor (KeyPress, _ pressDuration: TimeInterval) -> Void
    private let onHold: @MainActor (KeyPress) -> Void

    /// Keyed by chord so interleaved gestures on different chords cannot
    /// steal each other's deadline. Stale deadlines are discarded by
    /// generation, the same guard the cheat sheet's hold timer uses.
    private var gestures: [KeyPress: Gesture] = [:]
    private var generation: UInt64 = 0

    init(
        configuration: Configuration? = nil,
        physicalState: ChordPhysicalStateClient? = nil,
        now: (() -> CFAbsoluteTime)? = nil,
        scheduleDeadline: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil,
        onTap: @escaping @MainActor (KeyPress, TimeInterval) -> Void,
        onHold: @escaping @MainActor (KeyPress) -> Void
    ) {
        self.configuration = configuration ?? Configuration()
        self.physicalState = physicalState ?? .live
        self.now = now ?? CFAbsoluteTimeGetCurrent
        self.scheduleDeadline = scheduleDeadline ?? { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated(work)
            }
        }
        self.onTap = onTap
        self.onHold = onHold
    }

    func handle(_ keyPress: KeyPress, _ phase: KeyEventPhase) {
        switch phase {
        case .down:
            // A duplicate down for an in-flight chord RESTARTS the gesture.
            // Autorepeat can never reach this channel (the tap swallows
            // phased-chord autorepeats before delivery, and Carbon sends one
            // pressed event per physical press), so a second down can only
            // mean the previous up was lost (modifiers-first release) and
            // the user pressed again — treating it as an autorepeat would
            // let the ORIGINAL deadline read the new press's physical state
            // and turn two taps into a hold.
            generation &+= 1
            let gestureGeneration = generation
            gestures[keyPress] = Gesture(generation: gestureGeneration, startedAt: now())
            scheduleDeadline(configuration.holdThreshold) { [weak self] in
                self?.deadlineFired(keyPress, gestureGeneration)
            }
        case .up:
            guard let gesture = gestures.removeValue(forKey: keyPress) else {
                // Up after the hold already fired (or after a reset): the
                // gesture is settled, the release is just cleanup.
                return
            }
            onTap(keyPress, now() - gesture.startedAt)
        }
    }

    /// Drops all in-flight gestures without dispatching. Called on capture
    /// pause/stop so a gesture straddling the transition cannot fire a hold
    /// action into a paused session.
    func reset() {
        gestures.removeAll()
        generation &+= 1
    }

    /// Slack past the deadline within which a keyState probe still yields a
    /// trustworthy tap-vs-hold answer. Beyond it (a blocked main thread ran
    /// the deadline late), a released key is ambiguous — the user may have
    /// held well past the threshold and released before the late probe.
    private static let deadlineLatenessSlack: TimeInterval = 0.15

    private func deadlineFired(_ keyPress: KeyPress, _ gestureGeneration: UInt64) {
        guard let gesture = gestures[keyPress],
              gesture.generation == gestureGeneration else {
            return
        }
        gestures.removeValue(forKey: keyPress)
        if physicalState.isKeyPressed(keyPress.keyCode) {
            onHold(keyPress)
            return
        }
        let elapsed = now() - gesture.startedAt
        if elapsed > configuration.holdThreshold + Self.deadlineLatenessSlack {
            // The probe ran too late to distinguish "released before the
            // threshold (tap)" from "held past it and released before the
            // late probe (hold)". Dropping is the least-wrong outcome:
            // a misfired toggle acts on the user's windows; a dead press
            // just invites a retry.
            onDroppedAmbiguousGesture?(keyPress, elapsed)
            return
        }
        onTap(keyPress, elapsed)
    }

    /// Diagnostics-only hook for the ambiguous late-deadline drop.
    var onDroppedAmbiguousGesture: (@MainActor (KeyPress, TimeInterval) -> Void)?
}
