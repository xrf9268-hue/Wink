import CoreGraphics
import Foundation

@MainActor
protocol AppSwitching {
    /// - Parameter bypassCooldown: see `AppSwitcher.toggleApplication` — the
    ///   re-entry guard and confirmation/recovery pipeline stay fully
    ///   active either way; only the early per-bundle cooldown check is
    ///   skipped, and the cooldown is still stamped afterward.
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut, bypassCooldown: Bool) -> Bool

    func setFrontmostTargetBehavior(_ behavior: FrontmostTargetBehavior)

    /// Drop any in-flight window-cycle cursor. Called when shortcut
    /// configuration changes so a stale session (e.g. an override flipped
    /// away from Cycle and back) cannot steer the next gesture or qualify
    /// for the relaxed cycle cooldown.
    func invalidateWindowCycleSession(reason: String)

    /// Resolve a hold gesture into a picker session: the shortcut's target
    /// (frontmost pseudo-targets resolve to the concrete frontmost app),
    /// its running process, and its eligible current-Space windows.
    /// `nil` = nothing to pick (target not running, no eligible windows, or
    /// a transient AX failure) — the hold degrades to a silent no-op.
    func windowPickerSession(for shortcut: AppShortcut) -> WindowPickerSession?

    /// Focus one window from a picker session via the per-window activation
    /// trio, promoting any pending activation session so the confirmation
    /// ladder cannot re-raise a different window over the user's choice.
    @discardableResult
    func focusPickedWindow(windowID: CGWindowID, session: WindowPickerSession) -> Bool
}

extension AppSwitching {
    /// Convenience for the overwhelmingly common case — a real shortcut
    /// press always keeps the cooldown active.
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        toggleApplication(for: shortcut, bypassCooldown: false)
    }

    func setFrontmostTargetBehavior(_ behavior: FrontmostTargetBehavior) {}

    func invalidateWindowCycleSession(reason: String) {}

    // Declared requirements + defaults (witness-table dispatch): doubles
    // that predate the picker keep compiling as "no windows to pick".
    func windowPickerSession(for shortcut: AppShortcut) -> WindowPickerSession? { nil }

    @discardableResult
    func focusPickedWindow(windowID: CGWindowID, session: WindowPickerSession) -> Bool { false }
}
