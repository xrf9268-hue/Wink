import ApplicationServices
import Foundation

struct AccessibilityPermissionService: Sendable {
    /// Checks if both Accessibility and Input Monitoring permissions are granted.
    /// - Accessibility: needed for AX API (app activation via SkyLight)
    /// - Input Monitoring: needed for CGEvent tap (global hotkey capture)
    func isTrusted() -> Bool {
        AXIsProcessTrusted() && CGPreflightListenEventAccess()
    }

    /// Returns true only if Accessibility permission is granted.
    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Returns true only if Input Monitoring permission is granted.
    func isInputMonitoringTrusted() -> Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    func requestIfNeeded(prompt: Bool = true) -> Bool {
        // Request Accessibility permission (shows dialog reliably)
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let axGranted = AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)

        // Request Input Monitoring permission
        let imGranted: Bool
        if CGPreflightListenEventAccess() {
            imGranted = true
        } else if prompt {
            imGranted = CGRequestListenEventAccess()
        } else {
            imGranted = false
        }

        return axGranted && imGranted
    }
}
