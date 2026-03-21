protocol PermissionServicing: Sendable {
    func isTrusted() -> Bool
    func isAccessibilityTrusted() -> Bool
    func isInputMonitoringTrusted() -> Bool
    @discardableResult
    func requestIfNeeded(prompt: Bool) -> Bool
}
