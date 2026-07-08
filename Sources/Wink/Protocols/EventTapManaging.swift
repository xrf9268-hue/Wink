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
}
