struct ShortcutCaptureStatus: Equatable, Sendable {
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let eventTapActive: Bool

    var permissionsGranted: Bool {
        accessibilityGranted && inputMonitoringGranted
    }

    var ready: Bool {
        permissionsGranted && eventTapActive
    }
}
