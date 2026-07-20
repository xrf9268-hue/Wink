import Foundation
import ServiceManagement
import Testing
@testable import Wink

@Test @MainActor
func handleAppearRefreshesPermissionsAndLaunchAtLoginStatusFromLiveServiceState() {
    let permissionState = MutablePermissionState(ax: false, input: false)
    let launchAtLoginState = MutableLaunchAtLoginState(status: .notRegistered)
    let preferences = makePreferences(
        permissionState: permissionState,
        launchAtLoginState: launchAtLoginState
    )

    #expect(preferences.shortcutCaptureStatus == ShortcutCaptureStatus(
        accessibilityGranted: false,
        inputMonitoringGranted: false,
        carbonHotKeysRegistered: false,
        eventTapActive: false,
        standardShortcutsReady: false,
        hyperShortcutsReady: false
    ))
    #expect(preferences.launchAtLoginStatus == .disabled)

    permissionState.ax = true
    permissionState.input = true
    launchAtLoginState.statusValue = .requiresApproval

    SettingsViewLifecycleHandler(preferences: preferences).handleAppear()

    #expect(preferences.shortcutCaptureStatus == ShortcutCaptureStatus(
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        carbonHotKeysRegistered: false,
        eventTapActive: false,
        standardShortcutsReady: true,
        hyperShortcutsReady: true
    ))
    #expect(preferences.launchAtLoginStatus == .requiresApproval)
}

@Test @MainActor
func handleAppDidBecomeActiveRefreshesShortcutCaptureAndLaunchAtLoginStatus() {
    let permissionState = MutablePermissionState(ax: false, input: false)
    let launchAtLoginState = MutableLaunchAtLoginState(status: .requiresApproval)
    let preferences = makePreferences(
        permissionState: permissionState,
        launchAtLoginState: launchAtLoginState
    )

    permissionState.ax = true
    permissionState.input = true
    launchAtLoginState.statusValue = .enabled

    SettingsViewLifecycleHandler(preferences: preferences).handleAppDidBecomeActive()

    #expect(preferences.shortcutCaptureStatus == ShortcutCaptureStatus(
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        carbonHotKeysRegistered: false,
        eventTapActive: false,
        standardShortcutsReady: true,
        hyperShortcutsReady: true
    ))
    #expect(preferences.launchAtLoginStatus == .enabled)
}

@Test @MainActor
func didBecomeActiveWithInsightsSelectedRefreshesInsightsUsageOnly() {
    let counters = UsageRefreshCounters()
    let handler = makeLifecycleHandler(selectedTab: .insights, counters: counters)

    handler.handleAppDidBecomeActive()

    #expect(counters.insights == 1)
    #expect(counters.shortcuts == 0)
}

@Test @MainActor
func didBecomeActiveWithShortcutsSelectedRefreshesShortcutsUsageOnly() {
    let counters = UsageRefreshCounters()
    let handler = makeLifecycleHandler(selectedTab: .shortcuts, counters: counters)

    handler.handleAppDidBecomeActive()

    #expect(counters.insights == 0)
    #expect(counters.shortcuts == 1)
}

@Test @MainActor
func didBecomeActiveWithGeneralSelectedRefreshesNoUsage() {
    let counters = UsageRefreshCounters()
    let handler = makeLifecycleHandler(selectedTab: .general, counters: counters)

    handler.handleAppDidBecomeActive()

    #expect(counters.insights == 0)
    #expect(counters.shortcuts == 0)
}

@Test @MainActor
func reactivationBurstCoalescesToOneUsageRefreshPerWindow() {
    let counters = UsageRefreshCounters()
    let clock = MutableDateBox(date: Date(timeIntervalSinceReferenceDate: 0))
    let handler = makeLifecycleHandler(
        selectedTab: .insights,
        counters: counters,
        coalescer: SettingsUsageRefreshCoalescer(now: { clock.date })
    )

    handler.handleAppDidBecomeActive()
    clock.date = Date(timeIntervalSinceReferenceDate: 0.2)
    handler.handleAppDidBecomeActive()
    clock.date = Date(timeIntervalSinceReferenceDate: 0.9)
    handler.handleAppDidBecomeActive()

    #expect(counters.insights == 1)

    clock.date = Date(timeIntervalSinceReferenceDate: 1.5)
    handler.handleAppDidBecomeActive()

    #expect(counters.insights == 2)
}

@Test @MainActor
func generalTabActivationDoesNotConsumeTheCoalescingWindow() {
    let counters = UsageRefreshCounters()
    let clock = MutableDateBox(date: Date(timeIntervalSinceReferenceDate: 0))
    let selectedTab = MutableTabBox(tab: .general)
    let coalescer = SettingsUsageRefreshCoalescer(now: { clock.date })
    let handler = SettingsViewLifecycleHandler(
        preferences: makePreferences(
            permissionState: MutablePermissionState(ax: false, input: false),
            launchAtLoginState: MutableLaunchAtLoginState(status: .notRegistered)
        ),
        usageRefreshCoalescer: coalescer,
        selectedTab: { selectedTab.tab },
        refreshInsightsUsage: { counters.insights += 1 },
        refreshShortcutsUsage: { counters.shortcuts += 1 }
    )

    handler.handleAppDidBecomeActive()
    #expect(counters.insights == 0)

    // A suppressed General activation must not start the window; a refresh
    // 0.2s later on Insights still runs.
    selectedTab.tab = .insights
    clock.date = Date(timeIntervalSinceReferenceDate: 0.2)
    handler.handleAppDidBecomeActive()

    #expect(counters.insights == 1)
}

@Test @MainActor
func didBecomeActiveStillRefreshesPermissionsAndLaunchAtLoginAlongsideUsage() {
    let permissionState = MutablePermissionState(ax: false, input: false)
    let launchAtLoginState = MutableLaunchAtLoginState(status: .requiresApproval)
    let counters = UsageRefreshCounters()
    let preferences = makePreferences(
        permissionState: permissionState,
        launchAtLoginState: launchAtLoginState
    )
    let handler = SettingsViewLifecycleHandler(
        preferences: preferences,
        selectedTab: { .insights },
        refreshInsightsUsage: { counters.insights += 1 },
        refreshShortcutsUsage: { counters.shortcuts += 1 }
    )

    permissionState.ax = true
    permissionState.input = true
    launchAtLoginState.statusValue = .enabled

    handler.handleAppDidBecomeActive()

    #expect(preferences.launchAtLoginStatus == .enabled)
    #expect(preferences.shortcutCaptureStatus.accessibilityGranted)
    #expect(counters.insights == 1)
}

@MainActor
private func makeLifecycleHandler(
    selectedTab: SettingsTab,
    counters: UsageRefreshCounters,
    coalescer: SettingsUsageRefreshCoalescer = SettingsUsageRefreshCoalescer()
) -> SettingsViewLifecycleHandler {
    SettingsViewLifecycleHandler(
        preferences: makePreferences(
            permissionState: MutablePermissionState(ax: false, input: false),
            launchAtLoginState: MutableLaunchAtLoginState(status: .notRegistered)
        ),
        usageRefreshCoalescer: coalescer,
        selectedTab: { selectedTab },
        refreshInsightsUsage: { counters.insights += 1 },
        refreshShortcutsUsage: { counters.shortcuts += 1 }
    )
}

@MainActor
private final class UsageRefreshCounters {
    var insights = 0
    var shortcuts = 0
}

private final class MutableDateBox: @unchecked Sendable {
    var date: Date

    init(date: Date) {
        self.date = date
    }
}

@MainActor
private final class MutableTabBox {
    var tab: SettingsTab

    init(tab: SettingsTab) {
        self.tab = tab
    }
}

@MainActor
private func makePreferences(
    permissionState: MutablePermissionState,
    launchAtLoginState: MutableLaunchAtLoginState
) -> AppPreferences {
    AppPreferences(
        shortcutManager: makeShortcutManager(
            permissionService: FakePermissionService(state: permissionState),
            captureCoordinator: makeCaptureCoordinator()
        ),
        launchAtLoginService: LaunchAtLoginService(client: .init(
            status: { launchAtLoginState.statusValue },
            register: {
                launchAtLoginState.statusValue = .enabled
            },
            unregister: {
                launchAtLoginState.statusValue = .notRegistered
            },
            openSystemSettingsLoginItems: {}
        ))
    )
}

@MainActor
private func makeShortcutManager(
    permissionService: some PermissionServicing,
    captureCoordinator: ShortcutCaptureCoordinator,
    persistenceService: PersistenceService = TestPersistenceHarness().makePersistenceService()
) -> ShortcutManager {
    ShortcutManager(
        shortcutStore: ShortcutStore(),
        persistenceService: persistenceService,
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: captureCoordinator,
        permissionService: permissionService,
        diagnosticClient: .live
    )
}

@MainActor
private func makeCaptureCoordinator() -> ShortcutCaptureCoordinator {
    ShortcutCaptureCoordinator(
        standardProvider: FakeCaptureProvider(),
        hyperProvider: FakeHyperCaptureProvider()
    )
}

private final class MutablePermissionState: @unchecked Sendable {
    var ax: Bool
    var input: Bool

    init(ax: Bool, input: Bool) {
        self.ax = ax
        self.input = input
    }
}

private struct FakePermissionService: PermissionServicing {
    let state: MutablePermissionState

    func isTrusted() -> Bool {
        state.ax && state.input
    }

    func isAccessibilityTrusted() -> Bool {
        state.ax
    }

    func isInputMonitoringTrusted() -> Bool {
        state.input
    }

    @discardableResult
    func requestIfNeeded(prompt: Bool, inputMonitoringRequired: Bool) -> Bool {
        state.ax && (!inputMonitoringRequired || state.input)
    }
}

@MainActor
private final class FakeCaptureProvider: ShortcutCaptureProvider {
    var isRunning = false

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: isRunning ? 1 : 0,
            registeredShortcutCount: isRunning ? 1 : 0,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (Wink.KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<Wink.KeyPress>) {}
}

@MainActor
private final class FakeHyperCaptureProvider: HyperShortcutCaptureProvider {
    var isRunning = false

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: isRunning ? 1 : 0,
            registeredShortcutCount: isRunning ? 1 : 0,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (Wink.KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<Wink.KeyPress>) {}

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
