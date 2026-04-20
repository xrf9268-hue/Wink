import Foundation

@MainActor
protocol AppSwitching {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool
}
