import CoreGraphics
import Foundation

struct AppActivationAttemptIdentity: Equatable, Hashable, Sendable {
    let bundleIdentifier: String
    let attemptID: UUID
    let generation: Int
}

enum AppSwitchInvocationOperation: Equatable, Hashable, Sendable {
    case activation
    case deactivation
}

enum AppSwitchInvocationStatus: Equatable, Sendable {
    case pending
    case confirmed
    case failed
}

/// Exact ownership for one accepted direct invocation. The token binds an
/// asynchronous result to the concrete bundle AppSwitcher resolved at the
/// start of that invocation, including frontmost-app pseudo-targets.
struct AppSwitchInvocationToken: Equatable, Hashable, Sendable {
    /// Distinguishes repeated menu actions that intentionally reuse the same
    /// toggle session (for example, a degraded activation reconfirmation or a
    /// hide retry). Session identity alone is not invocation identity.
    let invocationID: UUID
    let attempt: AppActivationAttemptIdentity
    let operation: AppSwitchInvocationOperation
}

struct AppSwitchInvocationReceipt: Equatable, Sendable {
    let token: AppSwitchInvocationToken?
    let status: AppSwitchInvocationStatus

    static let confirmed = AppSwitchInvocationReceipt(
        token: nil,
        status: .confirmed
    )
}

struct AppActivationAttemptSnapshot: Equatable, Sendable {
    let identity: AppActivationAttemptIdentity
    let isConfirmed: Bool
    let isFailed: Bool

    init(
        identity: AppActivationAttemptIdentity,
        isConfirmed: Bool,
        isFailed: Bool = false
    ) {
        self.identity = identity
        self.isConfirmed = isConfirmed
        self.isFailed = isFailed
    }
}

@MainActor
protocol AppSwitching {
    /// - Parameter bypassCooldown: see `AppSwitcher.toggleApplication` — the
    ///   re-entry guard and confirmation/recovery pipeline stay fully
    ///   active either way; only the early per-bundle cooldown check is
    ///   skipped, and the cooldown is still stamped afterward.
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut, bypassCooldown: Bool) -> Bool

    /// Runs the same toggle pipeline while returning exact ownership for any
    /// asynchronous activation or deactivation it accepted. Callers that need
    /// final UI feedback must use this instead of inferring success from the
    /// absence of an activation session.
    func performApplicationInvocation(
        for shortcut: AppShortcut,
        bypassCooldown: Bool
    ) -> AppSwitchInvocationReceipt?

    /// Returns the terminal state of the exact receipt token. A missing or
    /// superseded owned session fails closed.
    func applicationInvocationStatus(
        for token: AppSwitchInvocationToken
    ) -> AppSwitchInvocationStatus

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

    /// Exact activation-session ownership for callers that must distinguish a
    /// Wink-triggered activation from an unrelated Dock/Cmd-Tab switch to the
    /// same bundle. `isConfirmed` closes the race where confirmation completes
    /// before the caller can install its own wait state.
    func currentActivationAttempt(
        for bundleIdentifier: String
    ) -> AppActivationAttemptSnapshot?

    /// Receives successful AppSwitcher confirmation transitions with their
    /// exact attempt identity. Raw workspace activation notifications are not
    /// an equivalent signal because they have no Wink-attempt ownership.
    func setActivationConfirmationObserver(
        _ observer: (@MainActor @Sendable (AppActivationAttemptIdentity) -> Void)?
    )
}

extension AppSwitching {
    /// Convenience for the overwhelmingly common case — a real shortcut
    /// press always keeps the cooldown active.
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        toggleApplication(for: shortcut, bypassCooldown: false)
    }

    func performApplicationInvocation(
        for shortcut: AppShortcut,
        bypassCooldown: Bool
    ) -> AppSwitchInvocationReceipt? {
        toggleApplication(for: shortcut, bypassCooldown: bypassCooldown)
            ? .confirmed
            : nil
    }

    func applicationInvocationStatus(
        for token: AppSwitchInvocationToken
    ) -> AppSwitchInvocationStatus {
        .failed
    }

    func setFrontmostTargetBehavior(_ behavior: FrontmostTargetBehavior) {}

    func invalidateWindowCycleSession(reason: String) {}

    // Declared requirements + defaults (witness-table dispatch): doubles
    // that predate the picker keep compiling as "no windows to pick".
    func windowPickerSession(for shortcut: AppShortcut) -> WindowPickerSession? { nil }

    @discardableResult
    func focusPickedWindow(windowID: CGWindowID, session: WindowPickerSession) -> Bool { false }

    func currentActivationAttempt(
        for bundleIdentifier: String
    ) -> AppActivationAttemptSnapshot? { nil }

    func setActivationConfirmationObserver(
        _ observer: (@MainActor @Sendable (AppActivationAttemptIdentity) -> Void)?
    ) {}
}
