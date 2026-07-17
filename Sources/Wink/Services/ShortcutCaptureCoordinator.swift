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
    private var hyperKeyEnabled = false
    private var inputMonitoringGranted = false
    private var capturePaused = false
    private var onKeyPress: (@MainActor @Sendable (KeyPress) -> Void)?

    init(
        standardProvider: any ShortcutCaptureProvider = CarbonHotKeyProvider(),
        hyperProvider: any HyperShortcutCaptureProvider = EventTapCaptureProvider()
    ) {
        self.standardProvider = standardProvider
        self.hyperProvider = hyperProvider
    }

    func start(
        inputMonitoringGranted: Bool,
        onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void
    ) {
        self.inputMonitoringGranted = inputMonitoringGranted
        self.onKeyPress = onKeyPress
        syncProviders()
    }

    func stop() {
        standardProvider.stop()
        hyperProvider.stop()
        onKeyPress = nil
    }

    func updateShortcuts(_ shortcuts: [AppShortcut]) {
        self.shortcuts = shortcuts
        rebuildRoutes()
        syncProviders()
    }

    func setHyperKeyEnabled(_ enabled: Bool) {
        hyperKeyEnabled = enabled
        rebuildRoutes()
        syncProviders()
    }

    func refreshInputMonitoring(granted: Bool) {
        inputMonitoringGranted = granted
        syncProviders()
    }

    func setCapturePaused(_ paused: Bool) {
        capturePaused = paused
        syncProviders()
    }

    var inputMonitoringRequired: Bool {
        standardProvider.inputMonitoringRequired || !hyperShortcuts.isEmpty
    }

    func status(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool
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
            standardRegistrationFailures: standardRegistrationState.failures
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

        for shortcut in shortcuts where shortcut.isEnabled {
            let keyPress = KeyPress(
                keyCode: keyMatcher.trigger(for: shortcut).keyCode,
                modifiers: NSEvent.ModifierFlags(rawValue: keyMatcher.trigger(for: shortcut).modifierMask)
            )
            switch ShortcutCaptureRoute.route(for: shortcut, hyperKeyEnabled: hyperKeyEnabled) {
            case .standard:
                standard.insert(keyPress)
            case .hyper:
                hyper.insert(keyPress)
            }
        }

        standardShortcuts = standard
        hyperShortcuts = hyper
    }

    private func syncProviders() {
        standardProvider.updateRegisteredShortcuts(standardShortcuts)
        hyperProvider.updateRegisteredShortcuts(hyperShortcuts)
        hyperProvider.setHyperKeyEnabled(hyperKeyEnabled && !hyperShortcuts.isEmpty)

        guard let onKeyPress, !capturePaused else {
            standardProvider.stop()
            hyperProvider.stop()
            return
        }

        if standardShortcuts.isEmpty {
            standardProvider.stop()
        } else {
            standardProvider.start(onKeyPress: onKeyPress)
        }

        if inputMonitoringGranted && !hyperShortcuts.isEmpty {
            hyperProvider.start(onKeyPress: onKeyPress)
        } else {
            hyperProvider.stop()
        }
    }
}
