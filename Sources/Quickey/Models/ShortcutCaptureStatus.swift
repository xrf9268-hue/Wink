struct ShortcutCaptureStatus: Equatable, Sendable {
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let inputMonitoringRequired: Bool
    let carbonHotKeysRegistered: Bool
    let eventTapActive: Bool
    let standardShortcutsReady: Bool
    let hyperShortcutsReady: Bool

    init(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        inputMonitoringRequired: Bool = false,
        carbonHotKeysRegistered: Bool,
        eventTapActive: Bool,
        standardShortcutsReady: Bool,
        hyperShortcutsReady: Bool
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringGranted = inputMonitoringGranted
        self.inputMonitoringRequired = inputMonitoringRequired
        self.carbonHotKeysRegistered = carbonHotKeysRegistered
        self.eventTapActive = eventTapActive
        self.standardShortcutsReady = standardShortcutsReady
        self.hyperShortcutsReady = hyperShortcutsReady
    }

    var anyShortcutsReady: Bool {
        standardShortcutsReady || hyperShortcutsReady
    }

    var permissionWarning: String? {
        guard accessibilityGranted else {
            return "Accessibility permission is required for app switching."
        }
        guard inputMonitoringRequired else {
            guard inputMonitoringGranted else {
                return "Input Monitoring is only required for Hyper shortcuts."
            }
            return nil
        }
        guard inputMonitoringGranted || hyperShortcutsReady else {
            return "Hyper shortcuts need Input Monitoring."
        }
        return nil
    }
}
