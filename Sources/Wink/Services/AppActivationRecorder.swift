import AppKit

/// Counts foreground app activations (local-only) to power the Insights
/// "Suggested shortcuts" card. Purely observational: one workspace
/// notification, no TCC, no polling. Wink itself is never recorded;
/// bound-vs-unbound filtering happens at query time because binding
/// state changes over time.
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

    func handleActivation(bundleIdentifier: String?) {
        guard isEnabled,
              let bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else { return }
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
            let bundle = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { [weak self] in
                self?.handleActivation(bundleIdentifier: bundle)
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
