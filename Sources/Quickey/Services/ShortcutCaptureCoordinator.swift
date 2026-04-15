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
    let standardShortcutCount: Int
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

    var inputMonitoringRequired: Bool {
        !hyperShortcuts.isEmpty
    }

    func status(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool
    ) -> ShortcutCaptureStatus {
        let standardReady = accessibilityGranted
            && (standardShortcuts.isEmpty || standardProvider.isRunning)
        let hyperReady = accessibilityGranted
            && (hyperShortcuts.isEmpty || (inputMonitoringGranted && hyperProvider.isRunning))

        return ShortcutCaptureStatus(
            accessibilityGranted: accessibilityGranted,
            inputMonitoringGranted: inputMonitoringGranted,
            inputMonitoringRequired: inputMonitoringRequired,
            carbonHotKeysRegistered: standardProvider.isRunning,
            eventTapActive: hyperProvider.isRunning,
            standardShortcutsReady: standardReady,
            hyperShortcutsReady: hyperReady
        )
    }

    func snapshot() -> ShortcutCaptureSnapshot {
        ShortcutCaptureSnapshot(
            carbonHotKeysRegistered: standardProvider.isRunning,
            eventTapActive: hyperProvider.isRunning,
            standardShortcutCount: standardShortcuts.count,
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

        guard let onKeyPress else {
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
