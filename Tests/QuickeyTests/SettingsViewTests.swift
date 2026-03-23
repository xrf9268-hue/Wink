import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import Testing
@testable import Quickey

@Suite("SettingsView", .serialized)
struct SettingsViewTests {
    @Test @MainActor
    func onAppearAndAppReactivationRefreshLaunchAtLoginStatusFromLiveServiceState() async {
        let activationSubject = PassthroughSubject<Void, Never>()
        let launchAtLoginState = MutableLaunchAtLoginState(status: .notRegistered)
        let preferences = makePreferences(state: launchAtLoginState)

        #expect(preferences.launchAtLoginStatus == .disabled)

        launchAtLoginState.statusValue = .requiresApproval

        let hostedView = hostSettingsView(
            preferences: preferences,
            appDidBecomeActivePublisher: activationSubject.eraseToAnyPublisher()
        )
        defer {
            hostedView.close()
            pumpMainRunLoop()
        }

        pumpMainRunLoop()

        #expect(preferences.launchAtLoginStatus == .requiresApproval)

        launchAtLoginState.statusValue = .enabled
        activationSubject.send(())
        pumpMainRunLoop()

        #expect(preferences.launchAtLoginStatus == .enabled)
    }
}

@MainActor
private func hostSettingsView(
    preferences: AppPreferences,
    appDidBecomeActivePublisher: AnyPublisher<Void, Never>
) -> HostedSettingsView {
    _ = NSApplication.shared

    let controller = NSHostingController(rootView: SettingsView(
        editor: makeEditor(),
        preferences: preferences,
        insightsViewModel: makeInsightsViewModel(),
        appListProvider: makeAppListProvider(),
        appDidBecomeActivePublisher: appDidBecomeActivePublisher
    ))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.contentViewController = controller

    return HostedSettingsView(window: window)
}

@MainActor
private func pumpMainRunLoop(iterations: Int = 3) {
    for _ in 0..<iterations {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

@MainActor
private func makeEditor() -> ShortcutEditorState {
    ShortcutEditorState(
        shortcutStore: ShortcutStore(),
        shortcutManager: makeShortcutManager(
            permissionService: FakePermissionService(ax: true, input: true),
            eventTapManager: FakeEventTapManager()
        )
    )
}

@MainActor
private func makeInsightsViewModel() -> InsightsViewModel {
    InsightsViewModel(usageTracker: nil, shortcutStore: ShortcutStore())
}

@MainActor
private func makeAppListProvider() -> AppListProvider {
    AppListProvider(client: .init(
        now: Date.init,
        scanInstalledApps: { [] },
        runningApplications: { [] },
        loadRecents: { [] },
        saveRecents: { _ in },
        mainBundleIdentifier: { nil }
    ))
}

@MainActor
private func makePreferences(state: MutableLaunchAtLoginState) -> AppPreferences {
    AppPreferences(
        shortcutManager: makeShortcutManager(
            permissionService: FakePermissionService(ax: true, input: true),
            eventTapManager: FakeEventTapManager()
        ),
        launchAtLoginService: LaunchAtLoginService(client: .init(
            status: { state.statusValue },
            register: {
                state.statusValue = .enabled
            },
            unregister: {
                state.statusValue = .notRegistered
            },
            openSystemSettingsLoginItems: {}
        ))
    )
}

@MainActor
private func makeShortcutManager(
    permissionService: some PermissionServicing,
    eventTapManager: some EventTapManaging
) -> ShortcutManager {
    ShortcutManager(
        shortcutStore: ShortcutStore(),
        persistenceService: PersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        eventTapManager: eventTapManager,
        permissionService: permissionService
    )
}

private struct HostedSettingsView {
    let window: NSWindow

    @MainActor
    func close() {
        window.contentViewController = nil
        window.orderOut(nil)
        window.close()
    }
}

private struct FakePermissionService: PermissionServicing {
    let ax: Bool
    let input: Bool

    func isTrusted() -> Bool {
        ax && input
    }

    func isAccessibilityTrusted() -> Bool {
        ax
    }

    func isInputMonitoringTrusted() -> Bool {
        input
    }

    @discardableResult
    func requestIfNeeded(prompt: Bool) -> Bool {
        isTrusted()
    }
}

@MainActor
private final class FakeEventTapManager: EventTapManaging {
    var isRunning = false

    func start(onKeyPress: @escaping (Quickey.KeyPress) -> Bool) -> EventTapStartResult {
        isRunning = true
        return .started
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<Quickey.KeyPress>) {}

    func setHyperKeyEnabled(_ enabled: Bool) {}
}

@MainActor
private struct FakeAppSwitcher: AppSwitching {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        true
    }
}

private final class MutableLaunchAtLoginState: @unchecked Sendable {
    var status: SMAppService.Status

    init(status: SMAppService.Status) {
        self.status = status
    }
}

private extension MutableLaunchAtLoginState {
    var statusValue: SMAppService.Status {
        get { status }
        set { status = newValue }
    }
}
