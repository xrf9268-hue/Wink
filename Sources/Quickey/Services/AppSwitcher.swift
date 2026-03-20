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
        let windows = fetchWindows(of: runningApp)
        unminimizeWindows(of: runningApp, windows: windows)
        let activated = activateViaWindowServer(runningApp, windows: windows)

        // If app has no visible windows after activation, try to get one
        if activated && !hasVisibleWindows(of: runningApp, windows: windows) {
            logger.info("TOGGLE[\(shortcut.appName)]: no visible windows after activation")
            DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: no visible windows, attempting recovery")
            recoverWindowlessApp(runningApp, shortcut: shortcut)
        }
        return activated
    }

    // MARK: - Three-layer activation (reference: alt-tab-macos)

    /// Activate app using three-layer approach:
    /// 1. _SLPSSetFrontProcessWithOptions — activate the process (with windowID for Space switching)
    /// 2. SLPSPostEventRecordTo — make the window the key window
    /// 3. AXUIElementPerformAction(kAXRaiseAction) — ensure correct Z-order
    private func activateViaWindowServer(_ app: NSRunningApplication, windows: [AXUIElement]?) -> Bool {
        let pid = app.processIdentifier
        var psn = ProcessSerialNumber()
        let status = GetProcessForPID(pid, &psn)
        guard status == noErr else {
            logger.error("GetProcessForPID failed for pid \(pid): \(status)")
            DiagnosticLog.log("GetProcessForPID failed for pid \(pid): \(status)")
            return app.activate(options: .activateIgnoringOtherApps)
        }

        // Get the first window's CGWindowID for Space-aware activation
        let windowID = firstWindowID(from: windows)

        // Layer 1: Activate the process via SkyLight
        // Passing a real windowID causes macOS to auto-switch to that window's Space
        let result = _SLPSSetFrontProcessWithOptions(&psn, windowID ?? 0, SLPSMode.userGenerated.rawValue)
        if result != .success {
            logger.error("_SLPSSetFrontProcessWithOptions failed: \(result.rawValue), falling back")
            DiagnosticLog.log("SkyLight activation failed: \(result.rawValue), falling back to NSRunningApplication.activate")
            return app.activate(options: .activateIgnoringOtherApps)
        }

        // Layer 2: Make the target window the key window via WindowServer event
        if let wid = windowID {
            makeKeyWindow(psn: &psn, windowID: wid)
        }

        // Layer 3: Raise the first window via Accessibility to ensure correct Z-order
        raiseFirstWindow(from: windows)

        return true
    }

    /// Send a WindowServer event to make a specific window the key window.
    /// Uses the 0xf8 byte pattern from alt-tab-macos.
    private func makeKeyWindow(psn: inout ProcessSerialNumber, windowID: CGWindowID) {
        // 176-byte event record (alt-tab pattern: bytes[0x3a] = 0x10, wid at offset 0x3c)
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xF8  // record length
        bytes[0x08] = 0x01  // event type
        bytes[0x3a] = 0x10  // sub-type: makeKeyWindow

        // Write windowID at offset 0x3c (little-endian UInt32)
        let widBytes = withUnsafeBytes(of: windowID.littleEndian) { Array($0) }
        for (i, b) in widBytes.enumerated() {
            bytes[0x3c + i] = b
        }

        let postResult = SLPSPostEventRecordTo(&psn, &bytes)
        if postResult != .success {
            #if DEBUG
            logger.debug("makeKeyWindow: SLPSPostEventRecordTo failed: \(postResult.rawValue)")
            #endif
        }
    }

    /// Raise the first window via AX kAXRaiseAction using pre-fetched windows.
    private func raiseFirstWindow(from windows: [AXUIElement]?) {
        guard let firstWindow = windows?.first else { return }
        AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
    }

    /// Get the CGWindowID of the first window via _AXUIElementGetWindow private API.
    /// This ID is needed for Space-aware activation and makeKeyWindow.
    private func firstWindowID(from windows: [AXUIElement]?) -> CGWindowID? {
        guard let firstWindow = windows?.first else { return nil }
        var windowID: CGWindowID = 0
        let axResult = _AXUIElementGetWindow(firstWindow, &windowID)
        guard axResult == .success, windowID != 0 else { return nil }
        return windowID
    }

    // MARK: - Windowless app recovery (reference: alt-tab + Hammerspoon)

    /// Try multiple strategies to get a window for a windowless app:
    /// 1. AX kAXRaiseAction on the app element — some apps auto-recover
    /// 2. NSWorkspace.shared.open(url) — like clicking Dock icon
    /// 3. ⌘N fallback — last resort
    private func recoverWindowlessApp(_ app: NSRunningApplication, shortcut: AppShortcut) {
        let pid = app.processIdentifier

        // Strategy 1: Raise the app element itself
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementPerformAction(axApp, kAXRaiseAction as CFString)

        // Check after a short delay if a window appeared
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if self.hasVisibleWindows(of: app, windows: self.fetchWindows(of: app)) {
                logger.info("TOGGLE[\(shortcut.appName)]: window recovered via AX raise")
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: window recovered via AX raise")
                return
            }

            // Strategy 2: Re-open via NSWorkspace (like Dock click)
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: shortcut.bundleIdentifier) {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: appURL, configuration: config) { @Sendable _, error in
                    if let error {
                        logger.error("TOGGLE[\(shortcut.appName)]: NSWorkspace.open failed: \(error.localizedDescription)")
                    }
                }

                // Check after another delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self else { return }
                    if self.hasVisibleWindows(of: app, windows: self.fetchWindows(of: app)) {
                        logger.info("TOGGLE[\(shortcut.appName)]: window recovered via NSWorkspace.open")
                        DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: window recovered via NSWorkspace.open")
                        return
                    }

                    // Strategy 3: Send ⌘N as last resort
                    logger.info("TOGGLE[\(shortcut.appName)]: sending ⌘N as fallback")
                    DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: sending ⌘N as fallback")
                    self.openNewWindow(of: app)
                }
            } else {
                // No app URL — go straight to ⌘N
                logger.info("TOGGLE[\(shortcut.appName)]: sending ⌘N (no app URL)")
                DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: sending ⌘N (no app URL)")
                self.openNewWindow(of: app)
            }
        }
    }

    // MARK: - Window helpers

    /// Fetch all AX windows for the given app (single IPC roundtrip).
    private func fetchWindows(of app: NSRunningApplication) -> [AXUIElement]? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            logger.error("fetchWindows: AXWindows failed for pid \(app.processIdentifier), result=\(result.rawValue)")
            DiagnosticLog.log("fetchWindows: AXWindows failed for pid \(app.processIdentifier), result=\(result.rawValue)")
            return nil
        }
        return windows
    }

    /// Unminimize all minimized windows using pre-fetched window list.
    private func unminimizeWindows(of app: NSRunningApplication, windows: [AXUIElement]?) {
        guard let windows else {
            logger.error("unminimize: no windows for pid \(app.processIdentifier)")
            DiagnosticLog.log("unminimize: no windows for pid \(app.processIdentifier)")
            return
        }
        #if DEBUG
        logger.debug("unminimize: found \(windows.count) windows for pid \(app.processIdentifier)")
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

    /// Check if app has any visible (non-minimized) windows using pre-fetched window list.
    private func hasVisibleWindows(of app: NSRunningApplication, windows: [AXUIElement]?) -> Bool {
        guard let windows else { return false }
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
