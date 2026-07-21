import Foundation

@MainActor
protocol AppSwitching {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool

    func setFrontmostTargetBehavior(_ behavior: FrontmostTargetBehavior)

    /// Drop any in-flight window-cycle cursor. Called when shortcut
    /// configuration changes so a stale session (e.g. an override flipped
    /// away from Cycle and back) cannot steer the next gesture or qualify
    /// for the relaxed cycle cooldown.
    func invalidateWindowCycleSession(reason: String)
}

extension AppSwitching {
    func setFrontmostTargetBehavior(_ behavior: FrontmostTargetBehavior) {}

    func invalidateWindowCycleSession(reason: String) {}
}
