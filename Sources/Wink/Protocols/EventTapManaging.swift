import AppKit

enum EventTapStartResult: Equatable, Sendable {
    case started
    case failedToCreateTap
}

@MainActor
protocol EventTapManaging {
    var isRunning: Bool { get }
    /// The handler is invoked on the main actor (the tap's background thread
    /// hops exactly once, in `MatchedShortcutDelivery`); marking it
    /// `@MainActor` lets callers run their toggle logic directly instead of
    /// paying a second executor enqueue per keypress.
    func start(onKeyPress: @escaping @MainActor (KeyPress) -> Bool) -> EventTapStartResult
    func stop()
    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>)
    func setHyperKeyEnabled(_ enabled: Bool)
    func setHyperHoldObserver(_ observer: (@Sendable (HyperHoldEvent) -> Void)?)
    func updatePhasedChords(_ keyPresses: Set<KeyPress>)
    func setPhasedKeyObserver(_ observer: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?)
}

extension EventTapManaging {
    // Sync no-op default (sync requirement + sync default: no async
    // overload-shadowing hazard); display-only consumers are optional.
    func setHyperHoldObserver(_ observer: (@Sendable (HyperHoldEvent) -> Void)?) {}
    // Same shape for phased delivery: declared requirements + sync no-op
    // defaults keep pre-phase fakes compiling with dynamic dispatch intact.
    func updatePhasedChords(_ keyPresses: Set<KeyPress>) {}
    func setPhasedKeyObserver(_ observer: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?) {}
}
