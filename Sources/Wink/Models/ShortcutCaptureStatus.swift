import Foundation

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
    /// macOS Secure Event Input is engaged (password field, secure prompt):
    /// the Hyper/event-tap route stops receiving key events until it ends.
    /// Surfaced so degradation is visible instead of silent.
    let secureInputActive: Bool

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
        standardRegistrationFailures: [ShortcutCaptureRegistrationFailure] = [],
        secureInputActive: Bool = false
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringGranted = inputMonitoringGranted
        self.secureInputActive = secureInputActive
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
            return String(localized: "Accessibility permission is required for app switching.", bundle: WinkResourceBundle.bundle)
        }
        guard inputMonitoringRequired else {
            guard inputMonitoringGranted else {
                guard standardRegistrationWarning == nil else {
                    return nil
                }
                return String(localized: "Input Monitoring is not required for the current shortcuts.", bundle: WinkResourceBundle.bundle)
            }
            return nil
        }
        guard inputMonitoringGranted else {
            return String(localized: "Some shortcuts need Input Monitoring.", bundle: WinkResourceBundle.bundle)
        }
        guard hyperShortcutsReady else {
            return String(localized: "Hyper shortcuts are configured, but shortcut capture is not active.", bundle: WinkResourceBundle.bundle)
        }
        return nil
    }

    var bannerDetail: String {
        if shortcutsPaused {
            return String(localized: "All shortcuts are paused.", bundle: WinkResourceBundle.bundle)
        }

        if let warning = permissionWarning {
            return warning
        }

        if let warning = standardRegistrationWarning {
            return warning
        }

        if !inputMonitoringRequired {
            return String(localized: "Standard shortcuts are active.", bundle: WinkResourceBundle.bundle)
        }

        if !inputMonitoringGranted {
            return String(localized: "Some shortcuts need Input Monitoring.", bundle: WinkResourceBundle.bundle)
        }

        return eventTapActive
            ? String(localized: "Standard and Hyper shortcuts are active.", bundle: WinkResourceBundle.bundle)
            : String(localized: "Standard shortcuts are active.", bundle: WinkResourceBundle.bundle)
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

        return String(
            localized: "System Settings > Input Monitoring can lag behind live access. If the affected shortcuts work here, Wink already has the permission it needs.",
            bundle: WinkResourceBundle.bundle
        )
    }

    var standardRegistrationWarning: String? {
        guard !shortcutsPaused else {
            return nil
        }
        if standardShortcutCount > 0,
           case .installationFailed = standardHandlerState {
            return String(localized: "Standard shortcut capture failed to start. Check logs for the Carbon handler status.", bundle: WinkResourceBundle.bundle)
        }
        let failedCount = max(0, standardShortcutCount - registeredStandardShortcutCount)
        guard failedCount > 0 else {
            return nil
        }

        if failedCount == standardShortcutCount {
            return String(localized: "Standard shortcuts failed to register. Check logs for the blocked key combinations.", bundle: WinkResourceBundle.bundle)
        }

        // Interpolating `failedCount` (not a literal "1 …") lets the catalog's
        // plural `variations` block pick "one" vs "other" — do not special-case
        // failedCount == 1 with a separate hard-coded string.
        return String(
            localized: "\(failedCount) standard shortcut bindings failed to register. Check logs for the blocked key combinations.",
            bundle: WinkResourceBundle.bundle
        )
    }
}
