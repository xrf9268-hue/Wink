import AppKit

@MainActor
protocol ShortcutCaptureProvider {
    var isRunning: Bool { get }
    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void)
    func stop()
    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>)
}

@MainActor
protocol HyperShortcutCaptureProvider: ShortcutCaptureProvider {
    func setHyperKeyEnabled(_ enabled: Bool)
}
