import AppKit

/// Auto-pauses shortcut capture while an exception app (VM, remote
/// desktop, …) is frontmost, so bound chords reach the guest system
/// instead of Wink. Purely observational: NSWorkspace activation
/// notifications plus a call-time snapshot, no TCC, no event taps.
@MainActor
final class FrontmostExceptionMonitor {
    /// Factory defaults, mirroring the app classes where a global keyboard
    /// interceptor is most likely to fight the app under the user's hands.
    static let defaultRuleBundleIdentifiers: [String] = [
        "com.parallels.desktop.console",
        "com.vmware.fusion",
        "org.virtualbox.app.VirtualBoxVM",
        "com.utmapp.UTM",
        "com.teamviewer.TeamViewer",
        "com.citrix.receiver.icaviewer.mac",
        "com.microsoft.rdc.macos",
        "com.realvnc.vncviewer",
        "com.apple.ScreenSharing",
    ]

    struct Client: Sendable {
        let frontmostApplication: @MainActor () -> (bundleIdentifier: String, localizedName: String?)?

        init(
            frontmostApplication: @escaping @MainActor () -> (bundleIdentifier: String, localizedName: String?)? = {
                guard let app = NSWorkspace.shared.frontmostApplication,
                      let bundle = app.bundleIdentifier else { return nil }
                return (bundle, app.localizedName)
            }
        ) {
            self.frontmostApplication = frontmostApplication
        }
    }

    private let client: Client
    /// (isAutoPaused, triggering app display name)
    private let onAutoPauseChange: @MainActor (Bool, String?) -> Void

    private var isEnabled = false
    private var ruleBundleIdentifiers: Set<String> = []
    private(set) var isAutoPaused = false
    private(set) var triggeringAppName: String?

    init(
        client: Client = Client(),
        onAutoPauseChange: @escaping @MainActor (Bool, String?) -> Void
    ) {
        self.client = client
        self.onAutoPauseChange = onAutoPauseChange
    }

    func configure(enabled: Bool, ruleBundleIdentifiers: [String]) {
        self.isEnabled = enabled
        self.ruleBundleIdentifiers = Set(ruleBundleIdentifiers)
        reevaluate()
    }

    func handleFrontmostChange(bundleIdentifier: String?, appName: String?) {
        apply(
            matched: isEnabled
                && bundleIdentifier.map { ruleBundleIdentifiers.contains($0) } == true,
            appName: appName
        )
    }

    /// Re-checks the live frontmost snapshot — used after configuration
    /// changes so enabling a rule for the app you are already in takes
    /// effect without an app switch.
    func reevaluate() {
        let frontmost = client.frontmostApplication()
        apply(
            matched: isEnabled
                && frontmost.map { ruleBundleIdentifiers.contains($0.bundleIdentifier) } == true,
            appName: frontmost?.localizedName ?? frontmost?.bundleIdentifier
        )
    }

    private func apply(matched: Bool, appName: String?) {
        let name = matched ? appName : nil
        guard matched != isAutoPaused || name != triggeringAppName else { return }
        isAutoPaused = matched
        triggeringAppName = name
        DiagnosticLog.log("EXCEPTION: autoPaused=\(matched) app=\(name ?? "-")")
        onAutoPauseChange(matched, name)
    }

    // MARK: - Live notification wiring

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
            let name = app?.localizedName
            MainActor.assumeIsolated { [weak self] in
                self?.handleFrontmostChange(bundleIdentifier: bundle, appName: name ?? bundle)
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
