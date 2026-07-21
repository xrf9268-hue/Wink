import AppKit

@MainActor
final class EventTapCaptureProvider: HyperShortcutCaptureProvider {
    private let manager: any EventTapManaging
    private var pendingHyperKeyEnabled = false
    private var registeredShortcuts: Set<KeyPress> = []

    init(manager: any EventTapManaging = EventTapManager()) {
        self.manager = manager
    }

    var isRunning: Bool {
        manager.isRunning
    }

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: registeredShortcuts.count,
            registeredShortcutCount: manager.isRunning ? registeredShortcuts.count : 0,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        // The manager delivers on the main actor already; invoke the handler
        // directly rather than enqueueing a second main-actor Task per press.
        let result = manager.start { keyPress in
            onKeyPress(keyPress)
            return true
        }
        if result == .started {
            manager.setHyperKeyEnabled(pendingHyperKeyEnabled)
        }
    }

    func stop() {
        manager.stop()
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {
        registeredShortcuts = keyPresses
        manager.updateRegisteredShortcuts(keyPresses)
    }

    func setHyperKeyEnabled(_ enabled: Bool) {
        pendingHyperKeyEnabled = enabled
        manager.setHyperKeyEnabled(enabled)
    }

    func setHyperHoldObserver(_ observer: (@Sendable (HyperHoldEvent) -> Void)?) {
        manager.setHyperHoldObserver(observer)
    }
}
