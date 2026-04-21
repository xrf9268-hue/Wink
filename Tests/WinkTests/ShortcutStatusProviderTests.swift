import AppKit
import Foundation
import Testing
@testable import Wink

@Suite("Shortcut status provider")
struct ShortcutStatusProviderTests {
    @Test @MainActor
    func trackBuildsRunningAndUnavailableStates() {
        let state = ShortcutStatusProviderState(
            applicationURLs: [
                "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app")
            ],
            runningBundleIdentifiers: ["com.apple.Safari"]
        )
        let provider = makeProvider(state: state)
        let safariShortcut = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
        let ghostShortcut = AppShortcut(
            appName: "Ghostty",
            bundleIdentifier: "com.mitchellh.ghostty",
            keyEquivalent: "g",
            modifierFlags: ["command"]
        )

        provider.track([safariShortcut, ghostShortcut])

        #expect(
            provider.status(for: safariShortcut)
            == ShortcutRuntimeStatus(isRunning: true, isUnavailable: false)
        )
        #expect(
            provider.status(for: ghostShortcut)
            == ShortcutRuntimeStatus(isRunning: false, isUnavailable: true)
        )
    }

    @Test @MainActor
    func runningAppRemainsAvailableWhenLaunchServicesCannotResolveBundleURL() {
        let state = ShortcutStatusProviderState(
            applicationURLs: [:],
            runningBundleIdentifiers: ["com.apple.Safari"]
        )
        let provider = makeProvider(state: state)
        let safariShortcut = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )

        provider.track([safariShortcut])

        #expect(
            provider.status(for: safariShortcut)
            == ShortcutRuntimeStatus(isRunning: true, isUnavailable: false)
        )
    }

    @Test @MainActor
    func workspaceNotificationsRefreshRunningState() {
        let state = ShortcutStatusProviderState(
            applicationURLs: [
                "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app")
            ],
            runningBundleIdentifiers: []
        )
        let workspaceNotificationCenter = NotificationCenter()
        let provider = makeProvider(
            state: state,
            workspaceNotificationCenter: workspaceNotificationCenter
        )
        let safariShortcut = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )

        provider.track([safariShortcut])
        #expect(provider.status(for: safariShortcut).isRunning == false)

        state.runningBundleIdentifiers = ["com.apple.Safari"]
        workspaceNotificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        drainMainRunLoop()

        #expect(provider.status(for: safariShortcut).isRunning == true)

        state.runningBundleIdentifiers = []
        workspaceNotificationCenter.post(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        drainMainRunLoop()

        #expect(provider.status(for: safariShortcut).isRunning == false)
    }

    @Test @MainActor
    func appActivationRefreshesAvailabilityState() {
        let state = ShortcutStatusProviderState(
            applicationURLs: [
                "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app")
            ],
            runningBundleIdentifiers: []
        )
        let appNotificationCenter = NotificationCenter()
        let provider = makeProvider(
            state: state,
            appNotificationCenter: appNotificationCenter
        )
        let safariShortcut = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )

        provider.track([safariShortcut])
        #expect(provider.status(for: safariShortcut).isUnavailable == false)

        state.applicationURLs["com.apple.Safari"] = nil
        appNotificationCenter.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        drainMainRunLoop()

        #expect(provider.status(for: safariShortcut).isUnavailable == true)
    }
}

@MainActor
private func makeProvider(
    state: ShortcutStatusProviderState,
    workspaceNotificationCenter: NotificationCenter = NotificationCenter(),
    appNotificationCenter: NotificationCenter = NotificationCenter()
) -> ShortcutStatusProvider {
    ShortcutStatusProvider(
        client: .init(
            applicationURL: { bundleIdentifier in
                state.applicationURLs[bundleIdentifier]
            },
            runningBundleIdentifiers: {
                state.runningBundleIdentifiers
            }
        ),
        workspaceNotificationCenter: workspaceNotificationCenter,
        appNotificationCenter: appNotificationCenter
    )
}

@MainActor
private func drainMainRunLoop() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

@MainActor
private final class ShortcutStatusProviderState {
    var applicationURLs: [String: URL]
    var runningBundleIdentifiers: Set<String>

    init(
        applicationURLs: [String: URL],
        runningBundleIdentifiers: Set<String>
    ) {
        self.applicationURLs = applicationURLs
        self.runningBundleIdentifiers = runningBundleIdentifiers
    }
}
