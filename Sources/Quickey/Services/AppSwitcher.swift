import AppKit
import os.log

private let logger = Logger(subsystem: "com.quickey.app", category: "AppSwitcher")

@MainActor
final class AppSwitcher {
    private let frontmostTracker: FrontmostApplicationTracker

    init(frontmostTracker: FrontmostApplicationTracker = FrontmostApplicationTracker()) {
        self.frontmostTracker = frontmostTracker
    }

    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: shortcut.bundleIdentifier).first else {
            // App not running — launch it
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: shortcut.bundleIdentifier) {
                frontmostTracker.noteCurrentFrontmostApp(excluding: shortcut.bundleIdentifier)
                let bundleId = shortcut.bundleIdentifier
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { @Sendable app, error in
                    if let error {
                        logger.error("Failed to launch \(bundleId): \(error.localizedDescription)")
                    }
                }
                return true
            }
            return false
        }

        if runningApp.isActive {
            // App is frontmost — hide it and restore the previous app
            let restored = frontmostTracker.restorePreviousAppIfPossible()
            let hidden = runningApp.hide()
            return restored || hidden
        }

        // App is running but not frontmost — bring it forward.
        frontmostTracker.noteCurrentFrontmostApp(excluding: shortcut.bundleIdentifier)
        if runningApp.isHidden {
            runningApp.unhide()
        }
        return activateViaWindowServer(runningApp)
    }

    /// Activate app using SkyLight private API for reliable foreground activation.
    /// NSRunningApplication.activate() is unreliable from LSUIElement apps on macOS 14+.
    private func activateViaWindowServer(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        var psn = ProcessSerialNumber()
        let status = GetProcessForPID(pid, &psn)
        guard status == noErr else {
            logger.warning("GetProcessForPID failed for pid \(pid): \(status)")
            return app.activate(options: .activateIgnoringOtherApps)
        }
        let result = _SLPSSetFrontProcessWithOptions(&psn, 0, SLPSMode.userGenerated.rawValue)
        if result != .success {
            logger.warning("_SLPSSetFrontProcessWithOptions failed: \(result.rawValue), falling back")
            return app.activate(options: .activateIgnoringOtherApps)
        }
        return true
    }
}
