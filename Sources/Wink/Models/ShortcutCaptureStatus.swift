struct ShortcutCaptureStatus: Equatable, Sendable {
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let inputMonitoringRequired: Bool
    let carbonHotKeysRegistered: Bool
    let eventTapActive: Bool
    let standardShortcutsReady: Bool
    let hyperShortcutsReady: Bool
    let standardShortcutCount: Int
    let registeredStandardShortcutCount: Int
    let standardRegistrationFailures: [ShortcutCaptureRegistrationFailure]

    init(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        inputMonitoringRequired: Bool = false,
        carbonHotKeysRegistered: Bool,
        eventTapActive: Bool,
        standardShortcutsReady: Bool,
        hyperShortcutsReady: Bool,
        standardShortcutCount: Int = 0,
        registeredStandardShortcutCount: Int = 0,
        standardRegistrationFailures: [ShortcutCaptureRegistrationFailure] = []
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringGranted = inputMonitoringGranted
        self.inputMonitoringRequired = inputMonitoringRequired
        self.carbonHotKeysRegistered = carbonHotKeysRegistered
        self.eventTapActive = eventTapActive
        self.standardShortcutsReady = standardShortcutsReady
        self.hyperShortcutsReady = hyperShortcutsReady
        self.standardShortcutCount = standardShortcutCount
        self.registeredStandardShortcutCount = registeredStandardShortcutCount
        self.standardRegistrationFailures = standardRegistrationFailures
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
                guard standardRegistrationWarning == nil else {
                    return nil
                }
                return "Input Monitoring is only required for Hyper shortcuts."
            }
            return nil
        }
        guard inputMonitoringGranted || hyperShortcutsReady else {
            return "Hyper shortcuts need Input Monitoring."
        }
        return nil
    }

    var bannerDetail: String {
        if let warning = permissionWarning {
            return warning
        }

        if let warning = standardRegistrationWarning {
            return warning
        }

        if !inputMonitoringRequired {
            return "Standard shortcuts are active."
        }

        if !hyperShortcutsReady {
            return "Hyper shortcuts need Input Monitoring."
        }

        return "Standard and Hyper shortcuts are active."
    }

    var systemSettingsGuidance: String? {
        guard permissionWarning == nil, standardRegistrationWarning == nil else {
            return nil
        }

        guard inputMonitoringRequired, inputMonitoringGranted, hyperShortcutsReady else {
            return nil
        }

        return "System Settings > Input Monitoring can lag behind live access. If Hyper shortcuts work here, Wink already has the permission it needs."
    }

    var standardRegistrationWarning: String? {
        let failedCount = max(0, standardShortcutCount - registeredStandardShortcutCount)
        guard failedCount > 0 else {
            return nil
        }

        if failedCount == standardShortcutCount {
            return "Standard shortcuts failed to register. Check logs for the blocked key combinations."
        }

        if failedCount == 1 {
            return "1 standard shortcut binding failed to register. Check logs for the blocked key combination."
        }

        return "\(failedCount) standard shortcut bindings failed to register. Check logs for the blocked key combinations."
    }
}
