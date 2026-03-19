import AppKit

@MainActor
final class FrontmostApplicationTracker {
    private(set) var lastNonTargetBundleIdentifier: String?

    func currentFrontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func noteCurrentFrontmostApp(excluding targetBundleIdentifier: String) {
        guard let current = currentFrontmostBundleIdentifier(), current != targetBundleIdentifier else {
            return
        }
        lastNonTargetBundleIdentifier = current
    }

    @discardableResult
    func restorePreviousAppIfPossible() -> Bool {
        guard let bundleIdentifier = lastNonTargetBundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return false
        }
        return app.activate()
    }
}
