struct ShortcutCaptureStatus: Equatable, Sendable {
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let carbonHotKeysRegistered: Bool
    let eventTapActive: Bool
    let standardShortcutsReady: Bool
    let hyperShortcutsReady: Bool

    var anyShortcutsReady: Bool {
        standardShortcutsReady || hyperShortcutsReady
    }

    var permissionWarning: String? {
        guard accessibilityGranted else {
            return "Accessibility permission is required for app switching."
        }
        guard inputMonitoringGranted || hyperShortcutsReady else {
            return "Input Monitoring is only required for Hyper shortcuts."
        }
        return nil
    }
}
