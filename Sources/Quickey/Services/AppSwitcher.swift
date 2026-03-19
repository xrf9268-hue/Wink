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
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
                    if let error {
                        logger.error("Failed to launch \(shortcut.bundleIdentifier): \(error.localizedDescription)")
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
        // Unhide first so minimized/hidden windows reappear before activation.
        frontmostTracker.noteCurrentFrontmostApp(excluding: shortcut.bundleIdentifier)
        if runningApp.isHidden {
            runningApp.unhide()
        }
        return runningApp.activate()
    }
}
