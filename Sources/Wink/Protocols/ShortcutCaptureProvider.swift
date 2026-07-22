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
    /// Chords whose down AND up edges must be swallowed and delivered through
    /// the phased observer instead of `onKeyPress`. Always a subset of the
    /// registered set. Phased delivery is best-effort on the up edge (a chord
    /// released modifiers-first changes identity and the up passes through) —
    /// consumers must pair it with a deadline fallback, never block on it.
    func updatePhasedChords(_ keyPresses: Set<KeyPress>)
    /// Observer for phased-chord events. Invoked on the main actor in
    /// delivery order (down before its up) — providers must hop through a
    /// FIFO channel (the main dispatch queue), not per-event `Task`s, which
    /// do not preserve ordering.
    func setPhasedKeyObserver(_ observer: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?)
}

extension ShortcutCaptureProvider {
    var inputMonitoringRequired: Bool { false }

    // Declared in the protocol body above so these dispatch dynamically
    // (witness table), then defaulted here: providers and test doubles that
    // predate phased delivery keep compiling and behave as "no phased
    // chords". (Extension-only members would statically shadow overrides —
    // see the project memory on Swift 6 protocol-extension shadowing.)
    func updatePhasedChords(_ keyPresses: Set<KeyPress>) {}
    func setPhasedKeyObserver(_ observer: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?) {}
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
