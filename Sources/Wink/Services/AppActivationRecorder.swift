import AppKit

/// Counts foreground app activations (local-only) to power the Insights
/// "Suggested shortcuts" card. Purely observational: one workspace
/// notification, no TCC, no polling. Wink itself is never recorded, and
/// `AppSuggestionEligibility` drops non-.regular processes that aren't
/// installed apps; bound-vs-unbound filtering happens at query time because
/// binding state changes over time.
@MainActor
final class AppActivationRecorder {
    private let onActivation: @MainActor (String) -> Void
    private var isEnabled = false

    init(onActivation: @escaping @MainActor (String) -> Void) {
        self.onActivation = onActivation
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func handleActivation(
        bundleIdentifier: String?,
        activationPolicy: NSApplication.ActivationPolicy,
        bundleURL: URL?
    ) {
        guard isEnabled,
              let bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier,
              // System dialogs and background agents (universalAccessAuthWarn,
              // loginwindow-class helpers) fire didActivate too; recording
              // them turns the Suggested-shortcuts card into a process list.
              AppSuggestionEligibility.shouldRecordActivation(
                  activationPolicy: activationPolicy,
                  bundleURL: bundleURL
              ) else { return }
        onActivation(bundleIdentifier)
    }

    // nonisolated(unsafe): written from MainActor start and from the
    // nonisolated stop (called from deinit, where exclusivity comes from
    // unique ownership); NotificationCenter.removeObserver is thread-safe.
    private nonisolated(unsafe) var activationObserver: Any?

    deinit {
        stopObservingWorkspaceNotifications()
    }

    func startObservingWorkspaceNotifications() {
        stopObservingWorkspaceNotifications()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = app?.bundleIdentifier
            // Snapshot policy and URL on the main queue alongside the id —
            // NSRunningApplication's time-varying properties are only
            // consistent within the current main run loop turn.
            let policy = app?.activationPolicy ?? .regular
            let bundleURL = app?.bundleURL
            MainActor.assumeIsolated { [weak self] in
                self?.handleActivation(
                    bundleIdentifier: bundle,
                    activationPolicy: policy,
                    bundleURL: bundleURL
                )
            }
        }
    }

    nonisolated func stopObservingWorkspaceNotifications() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }
}
