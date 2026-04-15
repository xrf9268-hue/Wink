protocol PermissionServicing: Sendable {
    func isTrusted() -> Bool
    func isAccessibilityTrusted() -> Bool
    func isInputMonitoringTrusted() -> Bool
    @discardableResult
    func requestIfNeeded(prompt: Bool, inputMonitoringRequired: Bool) -> Bool
}

extension PermissionServicing {
    @discardableResult
    func requestIfNeeded(prompt: Bool) -> Bool {
        requestIfNeeded(prompt: prompt, inputMonitoringRequired: true)
    }
}
