import AppKit

struct AppSwitcher {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: shortcut.bundleIdentifier).first else {
            return false
        }

        if runningApp.isActive {
            return runningApp.hide()
        }

        return runningApp.activate(options: [.activateIgnoringOtherApps])
    }
}
