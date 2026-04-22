import Foundation

@MainActor
protocol AppSwitching {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool

    func setFrontmostTargetBehavior(_ behavior: FrontmostTargetBehavior)
}

extension AppSwitching {
    func setFrontmostTargetBehavior(_ behavior: FrontmostTargetBehavior) {}
}
