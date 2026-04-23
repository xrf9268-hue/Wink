import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wink

@Suite("Menu bar popover")
struct MenuBarPopoverViewTests {
    @Test @MainActor
    func viewRendersSearchSectionsRowsAndActions() async {
        let context = makePopoverContext(
            shortcuts: [
                AppShortcut(
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    keyEquivalent: "s",
                    modifierFlags: ["command"]
                ),
                AppShortcut(
                    appName: "IINA",
                    bundleIdentifier: "com.colliderli.iina",
                    keyEquivalent: "i",
                    modifierFlags: ["command", "option", "control", "shift"]
                ),
            ],
            runningBundleIdentifiers: ["com.apple.Safari"],
            usageTotal: 48,
            updateService: FakeUpdateService(
                isConfigured: true,
                canCheckForUpdates: true,
                currentVersion: "0.3.0",
                automaticallyChecksForUpdates: true,
                automaticallyDownloadsUpdates: true
            )
        )

        let host = makeHostingView(
            MenuBarPopoverView(model: context.model).winkChromeRoot(),
            size: NSSize(width: 356, height: 520)
        )
        let placeholders = Set(collectPlaceholders(in: host))
        await waitUntil("usage refresh populates Today count") {
            context.model.todayActivationCount == 48
        }

        #expect(placeholders.contains("Search shortcuts"))
        #expect(host.fittingSize.width > 0)
        #expect(host.fittingSize.height > 0)
        #expect(context.model.versionText == "v0.3.0")
        #expect(context.model.todayActivationCount == 48)
        #expect(context.model.shortcutRows.map(\.title) == ["Safari", "IINA"])
        #expect(context.model.shortcutRows[0].isRunning == true)
        #expect(context.model.shortcutsPaused == false)
    }

    @Test @MainActor
    func modelActionsRouteManageSettingsPauseUpdateAndQuit() throws {
        let defaults = try #require(UserDefaults(suiteName: "MenuBarPopoverViewTests.modelActions"))
        defaults.removePersistentDomain(forName: "MenuBarPopoverViewTests.modelActions")
        let openedTabs = OpenedTabsRecorder()
        let quitRecorder = FlagRecorder()
        let updateService = FakeUpdateService(
            isConfigured: true,
            canCheckForUpdates: true,
            currentVersion: "0.3.0",
            automaticallyChecksForUpdates: true,
            automaticallyDownloadsUpdates: true
        )
        let context = makePopoverContext(
            shortcuts: [],
            usageTotal: 0,
            userDefaults: defaults,
            updateService: updateService,
            openSettings: { tab in
                openedTabs.tabs.append(tab)
            },
            quit: {
                quitRecorder.didRun = true
            }
        )

        context.model.openManageShortcuts()
        context.model.openSettings()
        context.model.setShortcutsPaused(true)
        context.model.checkForUpdates()
        context.model.quit()

        #expect(openedTabs.tabs.count == 2)
        #expect(openedTabs.tabs[0] == .shortcuts)
        #expect(openedTabs.tabs[1] == nil)
        #expect(context.preferences.shortcutsPaused == true)
        #expect(defaults.bool(forKey: AppPreferences.shortcutsPausedDefaultsKey) == true)
        #expect(updateService.didRequestManualCheck == true)
        #expect(quitRecorder.didRun == true)
    }

    @Test @MainActor
    func refreshBuildsEvenTwentyFourBarHistogramFromTodayTotal() async {
        let context = makePopoverContext(
            shortcuts: [],
            usageTotal: 24
        )

        await waitUntil("usage refresh populates histogram") {
            context.model.todayActivationCount == 24
                && context.model.todayHistogramBars.count == 24
                && context.model.todayHistogramBars.allSatisfy { $0 == 1 }
        }

        #expect(context.model.todayActivationCount == 24)
        #expect(context.model.todayHistogramBars.count == 24)
        #expect(context.model.todayHistogramBars.allSatisfy { $0 == 1 })
    }

    @Test @MainActor
    func modelRefreshesRunningStateForWorkspaceNotificationsWhilePopoverIsOpen() {
        let runtimeState = PopoverRuntimeState(
            applicationURLs: [
                "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app")
            ],
            runningBundleIdentifiers: []
        )
        let workspaceNotificationCenter = NotificationCenter()
        let context = makePopoverContext(
            shortcuts: [
                AppShortcut(
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    keyEquivalent: "s",
                    modifierFlags: ["command"]
                )
            ],
            usageTotal: 0,
            runtimeState: runtimeState,
            workspaceNotificationCenter: workspaceNotificationCenter
        )

        #expect(context.model.shortcutRows.first?.isRunning == false)

        runtimeState.runningBundleIdentifiers = ["com.apple.Safari"]
        workspaceNotificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        drainMainRunLoop()

        #expect(context.model.shortcutRows.first?.isRunning == true)

        runtimeState.runningBundleIdentifiers = []
        workspaceNotificationCenter.post(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        drainMainRunLoop()

        #expect(context.model.shortcutRows.first?.isRunning == false)
    }

    @Test @MainActor
    func modelRefreshesUnavailableStateForActivationNotificationsWhilePopoverIsOpen() {
        let runtimeState = PopoverRuntimeState(
            applicationURLs: [
                "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app")
            ],
            runningBundleIdentifiers: []
        )
        let appNotificationCenter = NotificationCenter()
        let context = makePopoverContext(
            shortcuts: [
                AppShortcut(
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    keyEquivalent: "s",
                    modifierFlags: ["command"]
                )
            ],
            usageTotal: 0,
            runtimeState: runtimeState,
            appNotificationCenter: appNotificationCenter
        )

        #expect(context.model.shortcutRows.first?.isUnavailable == false)

        runtimeState.applicationURLs["com.apple.Safari"] = nil
        appNotificationCenter.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        drainMainRunLoop()

        #expect(context.model.shortcutRows.first?.isUnavailable == true)
    }
}

private struct PopoverContext {
    let model: MenuBarPopoverModel
    let preferences: AppPreferences
}

@MainActor
private func makePopoverContext(
    shortcuts: [AppShortcut],
    runningBundleIdentifiers: Set<String> = [],
    usageTotal: Int,
    runtimeState: PopoverRuntimeState? = nil,
    workspaceNotificationCenter: NotificationCenter = NotificationCenter(),
    appNotificationCenter: NotificationCenter = NotificationCenter(),
    userDefaults: UserDefaults? = nil,
    updateService: FakeUpdateService? = nil,
    openSettings: @escaping @MainActor (SettingsTab?) -> Void = { _ in },
    quit: @escaping @MainActor () -> Void = {}
) -> PopoverContext {
    let defaults = userDefaults ?? UserDefaults(suiteName: "MenuBarPopoverViewTests.\(UUID().uuidString)")!
    let shortcutStore = ShortcutStore()
    shortcutStore.replaceAll(with: shortcuts)
    let harness = TestPersistenceHarness()
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: harness.makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: FakeCaptureProvider(),
            hyperProvider: FakeHyperCaptureProvider()
        ),
        permissionService: FakePermissionService(ax: true, input: true),
        diagnosticClient: .live
    )
    manager.save(shortcuts: shortcuts)

    let preferences = AppPreferences(
        shortcutManager: manager,
        launchAtLoginService: LaunchAtLoginService(client: .init(
            status: { .notRegistered },
            register: {},
            unregister: {},
            openSystemSettingsLoginItems: {}
        )),
        updateService: updateService,
        userDefaults: defaults
    )
    let resolvedRuntimeState = runtimeState ?? PopoverRuntimeState(
        applicationURLs: Dictionary(
            uniqueKeysWithValues: shortcuts.map { shortcut in
                (
                    shortcut.bundleIdentifier,
                    URL(fileURLWithPath: "/Applications/\(shortcut.appName).app")
                )
            }
        ),
        runningBundleIdentifiers: runningBundleIdentifiers
    )
    let statusProvider = ShortcutStatusProvider(
        client: .init(
            applicationURL: { bundleIdentifier in
                resolvedRuntimeState.applicationURLs[bundleIdentifier]
            },
            runningBundleIdentifiers: {
                resolvedRuntimeState.runningBundleIdentifiers
            }
        ),
        workspaceNotificationCenter: workspaceNotificationCenter,
        appNotificationCenter: appNotificationCenter
    )
    let model = MenuBarPopoverModel(
        shortcutStore: shortcutStore,
        preferences: preferences,
        shortcutStatusProvider: statusProvider,
        usageTracker: StaticUsageTracker(total: usageTotal),
        workspaceNotificationCenter: workspaceNotificationCenter,
        appNotificationCenter: appNotificationCenter,
        openSettings: openSettings,
        quit: quit
    )

    return PopoverContext(model: model, preferences: preferences)
}

@MainActor
private final class PopoverRuntimeState {
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

private actor StaticUsageTracker: UsageTracking {
    let total: Int

    init(total: Int) {
        self.total = total
    }

    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] {
        [:]
    }

    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] {
        [
            UUID().uuidString: [
                (date: "2026-04-22", count: total),
            ]
        ]
    }

    func totalSwitches(days: Int, relativeTo now: Date) async -> Int {
        total
    }

    func hourlyCounts(days: Int, relativeTo now: Date) async -> [HourlyUsageBucket] {
        let date = "2026-04-22"
        let baseCount = total / 24
        let remainder = total % 24

        return (0..<24).map { hour in
            HourlyUsageBucket(
                date: date,
                hour: hour,
                count: baseCount + (hour < remainder ? 1 : 0)
            )
        }
    }

    func previousPeriodTotal(days: Int, relativeTo now: Date) async -> Int {
        0
    }

    func streakDays(relativeTo now: Date) async -> Int {
        0
    }

    func usageTimeZone() async -> TimeZone {
        .current
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
    func requestIfNeeded(prompt: Bool, inputMonitoringRequired: Bool) -> Bool {
        ax && (!inputMonitoringRequired || input)
    }
}

@MainActor
private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(20),
    condition: @escaping @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline {
            Issue.record("Timed out waiting for: \(description)")
            return
        }
        try? await Task.sleep(for: pollInterval)
    }
}

@MainActor
private func drainMainRunLoop() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
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

@MainActor
private final class FakeUpdateService: UpdateServicing {
    let isConfigured: Bool
    let canCheckForUpdates: Bool
    let currentVersion: String
    let automaticallyChecksForUpdates: Bool
    let automaticallyDownloadsUpdates: Bool
    private(set) var didRequestManualCheck = false

    init(
        isConfigured: Bool,
        canCheckForUpdates: Bool,
        currentVersion: String,
        automaticallyChecksForUpdates: Bool,
        automaticallyDownloadsUpdates: Bool
    ) {
        self.isConfigured = isConfigured
        self.canCheckForUpdates = canCheckForUpdates
        self.currentVersion = currentVersion
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
    }

    func checkForUpdates() {
        didRequestManualCheck = true
    }
}

private final class OpenedTabsRecorder: @unchecked Sendable {
    var tabs: [SettingsTab?] = []
}

private final class FlagRecorder: @unchecked Sendable {
    var didRun = false
}

@MainActor
private func makeHostingView<Content: View>(_ rootView: Content, size: NSSize) -> NSHostingView<Content> {
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    hostingView.layoutSubtreeIfNeeded()
    return hostingView
}

@MainActor
private func collectPlaceholders(in view: NSView) -> [String] {
    var values: [String] = []
    if let textField = view as? NSTextField,
       let placeholder = textField.placeholderString,
       !placeholder.isEmpty {
        values.append(placeholder)
    }

    for subview in view.subviews {
        values.append(contentsOf: collectPlaceholders(in: subview))
    }

    return values
}
