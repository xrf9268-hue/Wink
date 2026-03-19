import AppKit

@MainActor
final class AppSwitcher {
    private let frontmostTracker: FrontmostApplicationTracker

    init(frontmostTracker: FrontmostApplicationTracker = FrontmostApplicationTracker()) {
        self.frontmostTracker = frontmostTracker
    }

    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: shortcut.bundleIdentifier).first else {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: shortcut.bundleIdentifier) {
                frontmostTracker.noteCurrentFrontmostApp(excluding: shortcut.bundleIdentifier)
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
                return true
            }
            return false
        }

        if runningApp.isActive {
            let restored = frontmostTracker.restorePreviousAppIfPossible()
            let hidden = runningApp.hide()
            return restored || hidden
        }

        frontmostTracker.noteCurrentFrontmostApp(excluding: shortcut.bundleIdentifier)
        return runningApp.activate(options: [.activateIgnoringOtherApps])
    }
}
