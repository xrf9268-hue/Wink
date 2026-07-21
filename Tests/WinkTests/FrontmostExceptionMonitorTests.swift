import Foundation
import Testing
@testable import Wink

@MainActor
private final class AutoPauseRecorder {
    var changes: [(paused: Bool, appName: String?)] = []
}

@Test @MainActor
func monitorPausesOnlyWhileEnabledRuleAppIsFrontmost() {
    let recorder = AutoPauseRecorder()
    let monitor = FrontmostExceptionMonitor(
        client: .init(frontmostApplication: { nil }),
        onAutoPauseChange: { paused, name in
            recorder.changes.append((paused, name))
        }
    )
    monitor.configure(enabled: true, ruleBundleIdentifiers: ["com.vmware.fusion"])

    monitor.handleFrontmostChange(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    #expect(monitor.isAutoPaused == false)

    monitor.handleFrontmostChange(bundleIdentifier: "com.vmware.fusion", appName: "VMware Fusion")
    #expect(monitor.isAutoPaused == true)
    #expect(monitor.triggeringAppName == "VMware Fusion")

    monitor.handleFrontmostChange(bundleIdentifier: "com.apple.Safari", appName: "Safari")
    #expect(monitor.isAutoPaused == false)
    #expect(monitor.triggeringAppName == nil)

    #expect(recorder.changes.map(\.paused) == [true, false])
}

@Test @MainActor
func disablingRulesLiftsAnActiveAutoPauseViaReevaluate() {
    let recorder = AutoPauseRecorder()
    let monitor = FrontmostExceptionMonitor(
        client: .init(frontmostApplication: { ("com.vmware.fusion", "VMware Fusion") }),
        onAutoPauseChange: { paused, name in
            recorder.changes.append((paused, name))
        }
    )

    // Enabling while the rule app is already frontmost pauses without an
    // app switch (configure re-evaluates the live snapshot)...
    monitor.configure(enabled: true, ruleBundleIdentifiers: ["com.vmware.fusion"])
    #expect(monitor.isAutoPaused == true)

    // ...and disabling lifts it the same way.
    monitor.configure(enabled: false, ruleBundleIdentifiers: ["com.vmware.fusion"])
    #expect(monitor.isAutoPaused == false)
    #expect(recorder.changes.map(\.paused) == [true, false])
}

@Test @MainActor
func removingTheMatchingRuleLiftsAnActiveAutoPause() {
    let monitor = FrontmostExceptionMonitor(
        client: .init(frontmostApplication: { ("com.teamviewer.TeamViewer", "TeamViewer") }),
        onAutoPauseChange: { _, _ in }
    )
    monitor.configure(enabled: true, ruleBundleIdentifiers: ["com.teamviewer.TeamViewer"])
    #expect(monitor.isAutoPaused == true)

    monitor.configure(enabled: true, ruleBundleIdentifiers: [])
    #expect(monitor.isAutoPaused == false)
}
