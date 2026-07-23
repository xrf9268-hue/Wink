import AppKit

enum ShortcutCaptureRoute: Equatable, Sendable {
    case standard
    case hyper

    static func route(for shortcut: AppShortcut, hyperKeyEnabled: Bool) -> Self {
        hyperKeyEnabled && shortcut.isHyper ? .hyper : .standard
    }
}

struct ShortcutCaptureSnapshot: Equatable, Sendable {
    let carbonHotKeysRegistered: Bool
    let eventTapActive: Bool
    let standardInputMonitoringRequired: Bool
    let shortcutsPaused: Bool
    let standardShortcutCount: Int
    let registeredStandardShortcutCount: Int
    let standardHandlerState: ShortcutCaptureHandlerState
    let standardRegistrationFailures: [ShortcutCaptureRegistrationFailure]
    let hyperShortcutCount: Int
}

@MainActor
final class ShortcutCaptureCoordinator {
    private let keyMatcher = KeyMatcher()
    private let standardProvider: any ShortcutCaptureProvider
    private let hyperProvider: any HyperShortcutCaptureProvider

    private var shortcuts: [AppShortcut] = []
    private var standardShortcuts: Set<KeyPress> = []
    private var hyperShortcuts: Set<KeyPress> = []
    /// Per-route subsets of chords with a hold action; always subsets of the
    /// corresponding registered sets above.
    private var standardPhasedChords: Set<KeyPress> = []
    private var hyperPhasedChords: Set<KeyPress> = []
    private var hyperKeyEnabled = false
    private var inputMonitoringGranted = false
    private var capturePaused = false
    private var onKeyPress: (@MainActor @Sendable (KeyPress) -> Void)?
    private var phasedKeyObserver: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?
    private var standardProviderStarted = false

    convenience init() {
        self.init(
            standardProvider: CarbonHotKeyProvider(),
            hyperProvider: EventTapCaptureProvider()
        )
    }

    convenience init(standardProvider: any ShortcutCaptureProvider) {
        self.init(
            standardProvider: standardProvider,
            hyperProvider: EventTapCaptureProvider()
        )
    }

    init(
        standardProvider: any ShortcutCaptureProvider,
        hyperProvider: any HyperShortcutCaptureProvider
    ) {
        self.standardProvider = standardProvider
        self.hyperProvider = hyperProvider
    }

    func start(
        inputMonitoringGranted: Bool,
        retryStandardProvider: Bool = true,
        onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void
    ) {
        self.inputMonitoringGranted = inputMonitoringGranted
        self.onKeyPress = onKeyPress
        syncProviders(retryStandardProvider: retryStandardProvider)
    }

    func stop() {
        standardProvider.stop()
        hyperProvider.stop()
        standardProviderStarted = false
        onKeyPress = nil
    }

    @discardableResult
    func updateShortcuts(_ shortcuts: [AppShortcut]) -> Bool {
        let previousStandardShortcuts = standardShortcuts
        let previousHyperShortcuts = hyperShortcuts
        let previousStandardPhased = standardPhasedChords
        let previousHyperPhased = hyperPhasedChords
        self.shortcuts = shortcuts
        rebuildRoutes()
        let standardShortcutsChanged = standardShortcuts != previousStandardShortcuts
        let hyperShortcutsChanged = hyperShortcuts != previousHyperShortcuts
        // Toggling a hold action on an existing shortcut leaves the chord
        // sets identical — the phased comparison must gate propagation on
        // its own or the change never reaches the providers.
        let phasedChanged = standardPhasedChords != previousStandardPhased
            || hyperPhasedChords != previousHyperPhased
        guard standardShortcutsChanged || hyperShortcutsChanged || phasedChanged else {
            return false
        }
        syncProviders(
            standardShortcutsChanged: standardShortcutsChanged,
            hyperShortcutsChanged: hyperShortcutsChanged,
            phasedChordsChanged: phasedChanged
        )
        return standardShortcutsChanged
    }

    func setHyperKeyEnabled(_ enabled: Bool) {
        guard hyperKeyEnabled != enabled else { return }
        let previousStandardShortcuts = standardShortcuts
        let previousHyperShortcuts = hyperShortcuts
        hyperKeyEnabled = enabled
        rebuildRoutes()
        syncProviders(
            standardShortcutsChanged: standardShortcuts != previousStandardShortcuts,
            hyperShortcutsChanged: hyperShortcuts != previousHyperShortcuts,
            hyperConfigurationChanged: true
        )
    }

    func refreshInputMonitoring(granted: Bool) {
        guard inputMonitoringGranted != granted else { return }
        inputMonitoringGranted = granted
        syncProviders(retryStandardProvider: standardProvider.inputMonitoringRequired)
    }

    func setHyperHoldObserver(_ observer: (@Sendable (HyperHoldEvent) -> Void)?) {
        hyperProvider.setHyperHoldObserver(observer)
    }

    /// See `HyperShortcutCaptureProvider.setHyperReleaseDeferralSuppressed(_:)` (#385).
    func setHyperReleaseDeferralSuppressed(_ suppressed: Bool) {
        hyperProvider.setHyperReleaseDeferralSuppressed(suppressed)
    }

    /// Single consumer for both routes' phased (down/up) deliveries.
    /// Providers store the observer independently of their running state, so
    /// setting it once at wiring time survives provider stop/start cycles.
    func setPhasedKeyObserver(_ observer: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?) {
        phasedKeyObserver = observer
        standardProvider.setPhasedKeyObserver(observer)
        hyperProvider.setPhasedKeyObserver(observer)
    }

    func setCapturePaused(_ paused: Bool) {
        guard capturePaused != paused else { return }
        capturePaused = paused
        syncProviders()
    }

    var inputMonitoringRequired: Bool {
        standardProvider.inputMonitoringRequired || !hyperShortcuts.isEmpty
    }

    func status(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        secureInputActive: Bool = false
    ) -> ShortcutCaptureStatus {
        let standardRegistrationState = standardProvider.registrationState
        let standardShortcutCount = standardRegistrationState.desiredShortcutCount
        let standardCaptureReady = standardShortcutCount == 0
            || standardRegistrationState.isReady
        let standardInputMonitoringReady = !standardProvider.inputMonitoringRequired
            || inputMonitoringGranted
        let carbonHotKeysRegistered = !capturePaused
            && standardShortcutCount > 0
            && standardInputMonitoringReady
            && standardRegistrationState.isReady
        let standardReady = !capturePaused
            && accessibilityGranted
            && standardInputMonitoringReady
            && standardCaptureReady
        let hyperReady = !capturePaused
            && accessibilityGranted
            && (hyperShortcuts.isEmpty || (inputMonitoringGranted && hyperProvider.isRunning))

        return ShortcutCaptureStatus(
            accessibilityGranted: accessibilityGranted,
            inputMonitoringGranted: inputMonitoringGranted,
            inputMonitoringRequired: inputMonitoringRequired,
            carbonHotKeysRegistered: carbonHotKeysRegistered,
            eventTapActive: !capturePaused && hyperProvider.isRunning,
            standardShortcutsReady: standardReady,
            hyperShortcutsReady: hyperReady,
            shortcutsPaused: capturePaused,
            standardShortcutCount: standardShortcutCount,
            registeredStandardShortcutCount: standardRegistrationState.registeredShortcutCount,
            standardHandlerState: standardRegistrationState.handlerState,
            standardRegistrationFailures: standardRegistrationState.failures,
            secureInputActive: secureInputActive
        )
    }

    func snapshot() -> ShortcutCaptureSnapshot {
        let standardRegistrationState = standardProvider.registrationState
        let standardShortcutCount = standardRegistrationState.desiredShortcutCount
        let standardInputMonitoringReady = !standardProvider.inputMonitoringRequired
            || inputMonitoringGranted
        let carbonHotKeysRegistered = !capturePaused
            && standardShortcutCount > 0
            && standardInputMonitoringReady
            && standardRegistrationState.isReady
        return ShortcutCaptureSnapshot(
            carbonHotKeysRegistered: carbonHotKeysRegistered,
            eventTapActive: !capturePaused && hyperProvider.isRunning,
            standardInputMonitoringRequired: standardProvider.inputMonitoringRequired,
            shortcutsPaused: capturePaused,
            standardShortcutCount: standardShortcutCount,
            registeredStandardShortcutCount: standardRegistrationState.registeredShortcutCount,
            standardHandlerState: standardRegistrationState.handlerState,
            standardRegistrationFailures: standardRegistrationState.failures,
            hyperShortcutCount: hyperShortcuts.count
        )
    }

    private func rebuildRoutes() {
        var standard = Set<KeyPress>()
        var hyper = Set<KeyPress>()
        var standardPhased = Set<KeyPress>()
        var hyperPhased = Set<KeyPress>()

        for shortcut in shortcuts where shortcut.isEnabled {
            let keyPress = KeyPress(
                keyCode: keyMatcher.trigger(for: shortcut).keyCode,
                modifiers: NSEvent.ModifierFlags(rawValue: keyMatcher.trigger(for: shortcut).modifierMask)
            )
            switch ShortcutCaptureRoute.route(for: shortcut, hyperKeyEnabled: hyperKeyEnabled) {
            case .standard:
                standard.insert(keyPress)
                if shortcut.holdAction != nil {
                    standardPhased.insert(keyPress)
                }
            case .hyper:
                hyper.insert(keyPress)
                if shortcut.holdAction != nil {
                    hyperPhased.insert(keyPress)
                }
            }
        }

        standardShortcuts = standard
        hyperShortcuts = hyper
        standardPhasedChords = standardPhased
        hyperPhasedChords = hyperPhased
    }

    private func syncProviders(
        standardShortcutsChanged: Bool = false,
        hyperShortcutsChanged: Bool = false,
        phasedChordsChanged: Bool = false,
        hyperConfigurationChanged: Bool = false,
        retryStandardProvider: Bool = false
    ) {
        // Phased sets are pushed BEFORE registered sets: the two writes are
        // not atomic across the tap thread, and the harmful interleaving is
        // a chord that is already registered but not yet phased (one event
        // takes the legacy key-down dispatch instead of hold arbitration).
        // Phased-but-not-yet-registered is inert — the chord doesn't match
        // at all until the registered write lands.
        if standardShortcutsChanged || phasedChordsChanged {
            standardProvider.updatePhasedChords(standardPhasedChords)
        }
        if hyperShortcutsChanged || phasedChordsChanged {
            hyperProvider.updatePhasedChords(hyperPhasedChords)
        }
        if standardShortcutsChanged {
            standardProvider.updateRegisteredShortcuts(standardShortcuts)
        }
        if hyperShortcutsChanged {
            hyperProvider.updateRegisteredShortcuts(hyperShortcuts)
        }
        if hyperConfigurationChanged || hyperShortcutsChanged {
            hyperProvider.setHyperKeyEnabled(hyperKeyEnabled && !hyperShortcuts.isEmpty)
        }

        guard let onKeyPress, !capturePaused else {
            standardProvider.stop()
            hyperProvider.stop()
            standardProviderStarted = false
            return
        }

        if standardShortcuts.isEmpty {
            standardProvider.stop()
            standardProviderStarted = false
        } else if standardShortcutsChanged && standardProviderStarted {
            // An already-started provider reconciles a changed desired set in
            // updateRegisteredShortcuts. Calling start immediately afterwards
            // would retry the same partial failure twice in one logical sync.
        } else if !standardProviderStarted || retryStandardProvider {
            standardProvider.start(onKeyPress: onKeyPress)
            standardProviderStarted = true
        }

        if inputMonitoringGranted && !hyperShortcuts.isEmpty {
            hyperProvider.start(onKeyPress: onKeyPress)
        } else {
            hyperProvider.stop()
        }
    }
}
