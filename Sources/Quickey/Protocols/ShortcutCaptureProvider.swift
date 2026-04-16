import AppKit

struct ShortcutCaptureRegistrationFailure: Equatable, Sendable {
    let keyPress: KeyPress
    let status: Int32
}

struct ShortcutCaptureRegistrationState: Equatable, Sendable {
    let desiredShortcutCount: Int
    let registeredShortcutCount: Int
    let failures: [ShortcutCaptureRegistrationFailure]

    var allDesiredShortcutsRegistered: Bool {
        desiredShortcutCount > 0 && registeredShortcutCount == desiredShortcutCount
    }
}

@MainActor
protocol ShortcutCaptureProvider {
    var isRunning: Bool { get }
    var registrationState: ShortcutCaptureRegistrationState { get }
    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void)
    func stop()
    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>)
}

@MainActor
protocol HyperShortcutCaptureProvider: ShortcutCaptureProvider {
    func setHyperKeyEnabled(_ enabled: Bool)
}
