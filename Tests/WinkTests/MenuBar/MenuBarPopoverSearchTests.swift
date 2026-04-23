import Foundation
import Testing
@testable import Wink

@Suite("Menu bar popover search")
struct MenuBarPopoverSearchTests {
    @Test @MainActor
    func searchFiltersByAppNameAndBundleIdentifier() {
        let context = makeSearchPopoverContext(
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
                    modifierFlags: ["command", "option"]
                ),
                AppShortcut(
                    appName: "Notion",
                    bundleIdentifier: "notion.id",
                    keyEquivalent: "n",
                    modifierFlags: ["command", "shift"]
                ),
            ]
        )

        #expect(context.model.filteredShortcutRows.map(\.title) == ["Safari", "IINA", "Notion"])

        context.model.searchText = "saf"
        #expect(context.model.filteredShortcutRows.map(\.title) == ["Safari"])

        context.model.searchText = "COLLIDERLI"
        #expect(context.model.filteredShortcutRows.map(\.title) == ["IINA"])

        context.model.searchText = "zzz"
        #expect(context.model.filteredShortcutRows.isEmpty)
    }

    @Test @MainActor
    func blankSearchKeepsSavedOrdering() {
        let context = makeSearchPopoverContext(
            shortcuts: [
                AppShortcut(
                    appName: "Terminal",
                    bundleIdentifier: "com.apple.Terminal",
                    keyEquivalent: "t",
                    modifierFlags: ["command"]
                ),
                AppShortcut(
                    appName: "Music",
                    bundleIdentifier: "com.apple.Music",
                    keyEquivalent: "m",
                    modifierFlags: ["command"]
                ),
            ]
        )

        context.model.searchText = "term"
        #expect(context.model.filteredShortcutRows.map(\.title) == ["Terminal"])

        context.model.searchText = "   "
        #expect(context.model.filteredShortcutRows.map(\.title) == ["Terminal", "Music"])
    }
}

private struct SearchPopoverContext {
    let model: MenuBarPopoverModel
}

@MainActor
private func makeSearchPopoverContext(shortcuts: [AppShortcut]) -> SearchPopoverContext {
    let shortcutStore = ShortcutStore()
    shortcutStore.replaceAll(with: shortcuts)

    let harness = TestPersistenceHarness()
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: harness.makePersistenceService(),
        appSwitcher: SearchFakeAppSwitcher(),
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: SearchFakeCaptureProvider(),
            hyperProvider: SearchFakeHyperCaptureProvider()
        ),
        permissionService: SearchFakePermissionService(),
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
        updateService: nil,
        userDefaults: UserDefaults(suiteName: "MenuBarPopoverSearchTests.\(UUID().uuidString)")!
    )

    let runtimeState = SearchPopoverRuntimeState(
        applicationURLs: Dictionary(
            uniqueKeysWithValues: shortcuts.map { shortcut in
                (
                    shortcut.bundleIdentifier,
                    URL(fileURLWithPath: "/Applications/\(shortcut.appName).app")
                )
            }
        )
    )
    let statusProvider = ShortcutStatusProvider(
        client: .init(
            applicationURL: { bundleIdentifier in
                runtimeState.applicationURLs[bundleIdentifier]
            },
            runningBundleIdentifiers: { [] }
        ),
        workspaceNotificationCenter: NotificationCenter(),
        appNotificationCenter: NotificationCenter()
    )

    let model = MenuBarPopoverModel(
        shortcutStore: shortcutStore,
        preferences: preferences,
        shortcutStatusProvider: statusProvider,
        usageTracker: SearchNoopUsageTracker(),
        workspaceNotificationCenter: NotificationCenter(),
        appNotificationCenter: NotificationCenter(),
        openSettings: { _ in },
        quit: {}
    )

    return SearchPopoverContext(model: model)
}

@MainActor
private final class SearchPopoverRuntimeState {
    let applicationURLs: [String: URL]

    init(applicationURLs: [String: URL]) {
        self.applicationURLs = applicationURLs
    }
}

private actor SearchNoopUsageTracker: UsageTracking {
    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] { [:] }
    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] { [:] }
    func totalSwitches(days: Int, relativeTo now: Date) async -> Int { 0 }
    func hourlyCounts(days: Int, relativeTo now: Date) async -> [HourlyUsageBucket] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let date = formatter.string(from: now)
        return (0..<24).map { hour in
            HourlyUsageBucket(date: date, hour: hour, count: 0)
        }
    }
    func previousPeriodTotal(days: Int, relativeTo now: Date) async -> Int { 0 }
    func streakDays(relativeTo now: Date) async -> Int { 0 }
    func usageTimeZone() async -> TimeZone { .current }
}

private struct SearchFakePermissionService: PermissionServicing {
    func isTrusted() -> Bool { true }
    func isAccessibilityTrusted() -> Bool { true }
    func isInputMonitoringTrusted() -> Bool { true }

    @discardableResult
    func requestIfNeeded(prompt: Bool, inputMonitoringRequired: Bool) -> Bool {
        true
    }
}

@MainActor
private final class SearchFakeCaptureProvider: ShortcutCaptureProvider {
    var isRunning = false

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: isRunning ? 1 : 0,
            registeredShortcutCount: isRunning ? 1 : 0,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {}
}

@MainActor
private final class SearchFakeHyperCaptureProvider: HyperShortcutCaptureProvider {
    var isRunning = false

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: isRunning ? 1 : 0,
            registeredShortcutCount: isRunning ? 1 : 0,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {}

    func setHyperKeyEnabled(_ enabled: Bool) {}
}

private struct SearchFakeAppSwitcher: AppSwitching {
    @MainActor
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        true
    }
}
