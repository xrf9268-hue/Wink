import AppKit

enum EventTapStartResult: Equatable, Sendable {
    case started
    case failedToCreateTap
}

@MainActor
protocol EventTapManaging {
    var isRunning: Bool { get }
    func start(onKeyPress: @escaping (KeyPress) -> Bool) -> EventTapStartResult
    func stop()
    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>)
    func setHyperKeyEnabled(_ enabled: Bool)
}
