import AppKit
import Carbon.HIToolbox
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "AppSwitcher")

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
                logger.info("TOGGLE[\(shortcut.appName)]: NOT RUNNING → launching")
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: NOT RUNNING → launching, saved previous=\(frontmostTracker.lastNonTargetBundleIdentifier ?? "nil")")
                let bundleId = shortcut.bundleIdentifier
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { @Sendable app, error in
                    if let error {
                        logger.error("Failed to launch \(bundleId): \(error.localizedDescription)")
                        DiagnosticLog.log("Failed to launch \(bundleId): \(error.localizedDescription)")
                    }
                }
                return true
            }
            logger.error("TOGGLE[\(shortcut.appName)]: NOT RUNNING, no URL found — cannot launch")
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: NOT RUNNING, no URL found — cannot launch")
            return false
        }

        if runningApp.isActive {
            // App is frontmost — hide it and restore the previous app
            let previousApp = frontmostTracker.lastNonTargetBundleIdentifier
            let restored = frontmostTracker.restorePreviousAppIfPossible()
            let hidden = runningApp.hide()
            logger.info("TOGGLE[\(shortcut.appName)]: IS ACTIVE → restored=\(restored), hidden=\(hidden)")
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: IS ACTIVE → restored=\(restored) (prev=\(previousApp ?? "nil")), hidden=\(hidden)")
            return restored || hidden
        }

        // App is running but not frontmost — bring it forward.
        frontmostTracker.noteCurrentFrontmostApp(excluding: shortcut.bundleIdentifier)
        logger.info("TOGGLE[\(shortcut.appName)]: RUNNING NOT FRONT → activating, isHidden=\(runningApp.isHidden)")
        DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: RUNNING NOT FRONT → activating, saved previous=\(frontmostTracker.lastNonTargetBundleIdentifier ?? "nil"), isHidden=\(runningApp.isHidden)")
        if runningApp.isHidden {
            runningApp.unhide()
        }
        unminimizeWindows(of: runningApp)
        let activated = activateViaWindowServer(runningApp)
        // If app has no visible windows, open a new one via Accessibility API (⌘N)
        if activated && !hasVisibleWindows(of: runningApp) {
            logger.info("TOGGLE[\(shortcut.appName)]: no visible windows, sending ⌘N")
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: no visible windows, sending ⌘N")
            openNewWindow(of: runningApp)
        }
        return activated
    }

    /// Unminimize all minimized windows of the given app via Accessibility API.
    private func unminimizeWindows(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            logger.error("unminimize: AXWindows failed for pid \(pid), result=\(result.rawValue)")
            DiagnosticLog.log("unminimize: AXWindows failed for pid \(pid), result=\(result.rawValue)")
            return
        }
        #if DEBUG
        logger.debug("unminimize: found \(windows.count) windows for pid \(pid)")
        #endif
        for (i, window) in windows.enumerated() {
            var minimizedRef: CFTypeRef?
            let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
            if minResult == .success, let isMinimized = minimizedRef as? Bool, isMinimized {
                let setResult = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                #if DEBUG
                logger.debug("unminimize: window[\(i)] was minimized, unminimize result=\(setResult.rawValue)")
                #endif
            }
        }
    }

    /// Activate app using SkyLight private API for reliable foreground activation.
    /// NSRunningApplication.activate() is unreliable from LSUIElement apps on macOS 14+.
    private func activateViaWindowServer(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        var psn = ProcessSerialNumber()
        let status = GetProcessForPID(pid, &psn)
        guard status == noErr else {
            logger.error("GetProcessForPID failed for pid \(pid): \(status)")
            DiagnosticLog.log("GetProcessForPID failed for pid \(pid): \(status)")
            return app.activate(options: .activateIgnoringOtherApps)
        }
        let result = _SLPSSetFrontProcessWithOptions(&psn, 0, SLPSMode.userGenerated.rawValue)
        if result != .success {
            logger.error("_SLPSSetFrontProcessWithOptions failed: \(result.rawValue), falling back")
            DiagnosticLog.log("SkyLight activation failed: \(result.rawValue), falling back to NSRunningApplication.activate")
            return app.activate(options: .activateIgnoringOtherApps)
        }
        return true
    }

    /// Check if app has any visible (non-minimized) windows.
    private func hasVisibleWindows(of app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else { return false }
        for window in windows {
            var minimizedRef: CFTypeRef?
            let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
            if minResult != .success || !(minimizedRef as? Bool ?? false) {
                return true // not minimized = visible
            }
        }
        return false
    }

    /// Open a new window by pressing ⌘N via CGEvent.
    private func openNewWindow(of app: NSRunningApplication) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_N), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_N), keyDown: false) else { return }
        keyDown.flags = CGEventFlags.maskCommand
        keyUp.flags = CGEventFlags.maskCommand
        let pid = app.processIdentifier
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }
}
