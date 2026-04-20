import ApplicationServices
import Foundation

struct AccessibilityPermissionService: PermissionServicing {
    struct Client: Sendable {
        let isAccessibilityTrusted: @Sendable () -> Bool
        let isInputMonitoringTrusted: @Sendable () -> Bool
        let requestAccessibilityPermission: @Sendable (Bool) -> Bool
        let requestInputMonitoringAccess: @Sendable () -> Bool
    }

    private let client: Client

    init(client: Client = .live) {
        self.client = client
    }

    /// Checks if both Accessibility and Input Monitoring permissions are granted.
    /// - Accessibility: needed for AX API (app activation via SkyLight)
    /// - Input Monitoring: needed for CGEvent tap (global hotkey capture)
    func isTrusted() -> Bool {
        client.isAccessibilityTrusted() && client.isInputMonitoringTrusted()
    }

    /// Returns true only if Accessibility permission is granted.
    func isAccessibilityTrusted() -> Bool {
        client.isAccessibilityTrusted()
    }

    /// Returns true only if Input Monitoring permission is granted.
    func isInputMonitoringTrusted() -> Bool {
        client.isInputMonitoringTrusted()
    }

    @discardableResult
    func requestIfNeeded(
        prompt: Bool = true,
        inputMonitoringRequired: Bool = true
    ) -> Bool {
        let axGranted = client.requestAccessibilityPermission(prompt)

        let imGranted: Bool
        if !inputMonitoringRequired {
            imGranted = client.isInputMonitoringTrusted()
        } else if client.isInputMonitoringTrusted() {
            imGranted = true
        } else if prompt {
            imGranted = client.requestInputMonitoringAccess()
        } else {
            imGranted = false
        }

        return axGranted && (!inputMonitoringRequired || imGranted)
    }
}

extension AccessibilityPermissionService.Client {
    static let live = AccessibilityPermissionService.Client(
        isAccessibilityTrusted: {
            AXIsProcessTrusted()
        },
        isInputMonitoringTrusted: {
            CGPreflightListenEventAccess()
        },
        requestAccessibilityPermission: { prompt in
            let key = "AXTrustedCheckOptionPrompt" as CFString
            return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
        },
        requestInputMonitoringAccess: {
            CGRequestListenEventAccess()
        }
    )
}
