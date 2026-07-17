struct ShortcutCaptureStatus: Equatable, Sendable {
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let inputMonitoringRequired: Bool
    let carbonHotKeysRegistered: Bool
    let eventTapActive: Bool
    let standardShortcutsReady: Bool
    let hyperShortcutsReady: Bool
    let shortcutsPaused: Bool
    let standardShortcutCount: Int
    let registeredStandardShortcutCount: Int
    let standardHandlerState: ShortcutCaptureHandlerState
    let standardRegistrationFailures: [ShortcutCaptureRegistrationFailure]

    init(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        inputMonitoringRequired: Bool = false,
        carbonHotKeysRegistered: Bool,
        eventTapActive: Bool,
        standardShortcutsReady: Bool,
        hyperShortcutsReady: Bool,
        shortcutsPaused: Bool = false,
        standardShortcutCount: Int = 0,
        registeredStandardShortcutCount: Int = 0,
        standardHandlerState: ShortcutCaptureHandlerState = .installed,
        standardRegistrationFailures: [ShortcutCaptureRegistrationFailure] = []
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringGranted = inputMonitoringGranted
        self.inputMonitoringRequired = inputMonitoringRequired
        self.carbonHotKeysRegistered = carbonHotKeysRegistered
        self.eventTapActive = eventTapActive
        self.standardShortcutsReady = standardShortcutsReady
        self.hyperShortcutsReady = hyperShortcutsReady
        self.shortcutsPaused = shortcutsPaused
        self.standardShortcutCount = standardShortcutCount
        self.registeredStandardShortcutCount = registeredStandardShortcutCount
        self.standardHandlerState = standardHandlerState
        self.standardRegistrationFailures = standardRegistrationFailures
    }

    var anyShortcutsReady: Bool {
        !shortcutsPaused && (standardShortcutsReady || hyperShortcutsReady)
    }

    var permissionWarning: String? {
        guard !shortcutsPaused else {
            return nil
        }
        guard accessibilityGranted else {
            return "Accessibility permission is required for app switching."
        }
        guard inputMonitoringRequired else {
            guard inputMonitoringGranted else {
                guard standardRegistrationWarning == nil else {
                    return nil
                }
                return "Input Monitoring is not required for the current shortcuts."
            }
            return nil
        }
        guard inputMonitoringGranted else {
            return "Some shortcuts need Input Monitoring."
        }
        guard hyperShortcutsReady else {
            return "Hyper shortcuts are configured, but shortcut capture is not active."
        }
        return nil
    }

    var bannerDetail: String {
        if shortcutsPaused {
            return "All shortcuts are paused."
        }

        if let warning = permissionWarning {
            return warning
        }

        if let warning = standardRegistrationWarning {
            return warning
        }

        if !inputMonitoringRequired {
            return "Standard shortcuts are active."
        }

        if !inputMonitoringGranted {
            return "Some shortcuts need Input Monitoring."
        }

        return eventTapActive
            ? "Standard and Hyper shortcuts are active."
            : "Standard shortcuts are active."
    }

    var systemSettingsGuidance: String? {
        guard !shortcutsPaused else {
            return nil
        }
        guard permissionWarning == nil, standardRegistrationWarning == nil else {
            return nil
        }

        guard inputMonitoringRequired,
              inputMonitoringGranted,
              standardShortcutsReady,
              hyperShortcutsReady else {
            return nil
        }

        return "System Settings > Input Monitoring can lag behind live access. If the affected shortcuts work here, Wink already has the permission it needs."
    }

    var standardRegistrationWarning: String? {
        guard !shortcutsPaused else {
            return nil
        }
        if standardShortcutCount > 0,
           case .installationFailed = standardHandlerState {
            return "Standard shortcut capture failed to start. Check logs for the Carbon handler status."
        }
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
