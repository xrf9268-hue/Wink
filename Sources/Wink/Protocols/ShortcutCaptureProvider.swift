import AppKit

struct ShortcutCaptureRegistrationFailure: Equatable, Sendable {
    let keyPress: KeyPress
    let status: Int32
}

enum ShortcutCaptureHandlerState: Equatable, Sendable {
    case notInstalled
    case installed
    case installationFailed(status: Int32)

    var isInstalled: Bool {
        self == .installed
    }

    var failureStatus: Int32? {
        guard case .installationFailed(let status) = self else { return nil }
        return status
    }

    var diagnosticName: String {
        switch self {
        case .notInstalled:
            "not_installed"
        case .installed:
            "installed"
        case .installationFailed:
            "installation_failed"
        }
    }
}

struct ShortcutCaptureRegistrationState: Equatable, Sendable {
    let desiredShortcutCount: Int
    let registeredShortcutCount: Int
    let handlerState: ShortcutCaptureHandlerState
    let failures: [ShortcutCaptureRegistrationFailure]

    init(
        desiredShortcutCount: Int,
        registeredShortcutCount: Int,
        handlerState: ShortcutCaptureHandlerState = .installed,
        failures: [ShortcutCaptureRegistrationFailure]
    ) {
        self.desiredShortcutCount = desiredShortcutCount
        self.registeredShortcutCount = registeredShortcutCount
        self.handlerState = handlerState
        self.failures = failures
    }

    var allDesiredShortcutsRegistered: Bool {
        desiredShortcutCount > 0 && registeredShortcutCount == desiredShortcutCount
    }

    var isReady: Bool {
        handlerState.isInstalled && allDesiredShortcutsRegistered
    }
}

@MainActor
protocol ShortcutCaptureProvider {
    var isRunning: Bool { get }
    var inputMonitoringRequired: Bool { get }
    var registrationState: ShortcutCaptureRegistrationState { get }
    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void)
    func stop()
    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>)
}

extension ShortcutCaptureProvider {
    var inputMonitoringRequired: Bool { false }
}

@MainActor
protocol HyperShortcutCaptureProvider: ShortcutCaptureProvider {
    func setHyperKeyEnabled(_ enabled: Bool)
    func setHyperHoldObserver(_ observer: (@Sendable (HyperHoldEvent) -> Void)?)
}

extension HyperShortcutCaptureProvider {
    // Sync no-op default; only the live event-tap provider surfaces
    // Hyper hold phases.
    func setHyperHoldObserver(_ observer: (@Sendable (HyperHoldEvent) -> Void)?) {}
}
