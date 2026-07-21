import AppKit
import Foundation
import Testing
@testable import Wink

@Test @MainActor
func startupSequenceAppliesPersistedHyperStateBeforeStartingShortcutManager() {
    var events: [String] = []

    AppController.runStartupSequence(
        startUpdateService: {
            events.append("startUpdateService")
        },
        loadShortcuts: {
            events.append("load")
            return []
        },
        replaceShortcuts: { _ in
            events.append("replace")
        },
        reapplyHyperIfNeeded: {
            events.append("reapplyHyper")
            return true
        },
        isHyperEnabled: {
            events.append("readHyperEnabled")
            return true
        },
        setHyperKeyEnabled: { enabled in
            events.append("setHyper:\(enabled)")
        },
        startShortcutManager: {
            events.append("startShortcutManager")
        }
    )

    #expect(events == [
        "startUpdateService",
        "load",
        "replace",
        "readHyperEnabled",
        "reapplyHyper",
        "setHyper:true",
        "startShortcutManager",
    ])
}

@Test @MainActor
func startupSequenceDisablesHyperRoutingWhenPersistedReapplyFails() {
    var events: [String] = []

    AppController.runStartupSequence(
        startUpdateService: {
            events.append("startUpdateService")
        },
        loadShortcuts: {
            events.append("load")
            return []
        },
        replaceShortcuts: { _ in
            events.append("replace")
        },
        reapplyHyperIfNeeded: {
            events.append("reapplyHyper")
            return false
        },
        isHyperEnabled: {
            events.append("readHyperEnabled")
            return true
        },
        setHyperKeyEnabled: { enabled in
            events.append("setHyper:\(enabled)")
        },
        startShortcutManager: {
            events.append("startShortcutManager")
        }
    )

    #expect(events == [
        "startUpdateService",
        "load",
        "replace",
        "readHyperEnabled",
        "reapplyHyper",
        "setHyper:false",
        "startShortcutManager",
    ])
}

@Test @MainActor
func consumeFirstLaunchFlagReturnsTrueOnceForFreshInstall() throws {
    let suiteName = "AppControllerTests.firstLaunch.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(AppController.consumeFirstLaunchFlag(userDefaults: defaults, hasExistingShortcuts: false) == true)
    #expect(AppController.consumeFirstLaunchFlag(userDefaults: defaults, hasExistingShortcuts: false) == false)
}

@Test @MainActor
func consumeFirstLaunchFlagSilentlyMarksMigratingUsersOnboarded() throws {
    let suiteName = "AppControllerTests.firstLaunch.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(AppController.consumeFirstLaunchFlag(userDefaults: defaults, hasExistingShortcuts: true) == false)
    #expect(AppController.consumeFirstLaunchFlag(userDefaults: defaults, hasExistingShortcuts: false) == false)
}

@Test @MainActor
func startupSequenceStartsUpdateServiceBeforeShortcutManager() {
    var events: [String] = []

    AppController.runStartupSequence(
        startUpdateService: {
            events.append("startUpdateService")
        },
        loadShortcuts: {
            events.append("load")
            return []
        },
        replaceShortcuts: { _ in
            events.append("replace")
        },
        reapplyHyperIfNeeded: {
            events.append("reapplyHyper")
            return false
        },
        isHyperEnabled: {
            events.append("readHyperEnabled")
            return false
        },
        setHyperKeyEnabled: { enabled in
            events.append("setHyper:\(enabled)")
        },
        startShortcutManager: {
            events.append("startShortcutManager")
        }
    )

    let startUpdateIndex = events.firstIndex(of: "startUpdateService")
    let startShortcutIndex = events.firstIndex(of: "startShortcutManager")

    #expect(startUpdateIndex != nil)
    #expect(startShortcutIndex != nil)
    #expect(startUpdateIndex! < startShortcutIndex!)
}

@Test @MainActor
func startupSequenceAppliesPersistedPreferencesBeforeStartingShortcutManager() {
    var events: [String] = []

    AppController.runStartupSequence(
        startUpdateService: {
            events.append("startUpdateService")
        },
        loadShortcuts: {
            events.append("load")
            return []
        },
        replaceShortcuts: { _ in
            events.append("replace")
        },
        reapplyHyperIfNeeded: {
            events.append("reapplyHyper")
            return false
        },
        isHyperEnabled: {
            events.append("readHyperEnabled")
            return false
        },
        setHyperKeyEnabled: { enabled in
            events.append("setHyper:\(enabled)")
        },
        preparePreferences: {
            events.append("preparePreferences")
        },
        startShortcutManager: {
            events.append("startShortcutManager")
        }
    )

    let preparePreferencesIndex = events.firstIndex(of: "preparePreferences")
    let startShortcutIndex = events.firstIndex(of: "startShortcutManager")

    #expect(preparePreferencesIndex != nil)
    #expect(startShortcutIndex != nil)
    #expect(preparePreferencesIndex! < startShortcutIndex!)
}

@Test @MainActor
func duplicatePersistencePayloadNeverPublishesIntoSettingsModels() async throws {
    let harness = TestPersistenceHarness()
    defer { harness.cleanup() }
    let invalidPayload = try JSONEncoder().encode(makeDuplicateShortcutIDFixture())
    try invalidPayload.write(to: harness.shortcutsURL)

    let service = harness.makePersistenceService(backupIDProvider: { "startup-duplicate" })
    let store = ShortcutStore()
    var didReplaceShortcuts = false
    var didStartShortcutManager = false

    AppController.runStartupSequence(
        startUpdateService: {},
        loadShortcuts: { try service.load() },
        replaceShortcuts: { shortcuts in
            didReplaceShortcuts = true
            store.replaceAll(with: shortcuts)
        },
        reapplyHyperIfNeeded: { false },
        isHyperEnabled: { false },
        setHyperKeyEnabled: { _ in },
        startShortcutManager: { didStartShortcutManager = true }
    )

    #expect(didReplaceShortcuts == false)
    #expect(didStartShortcutManager)
    #expect(store.shortcuts.isEmpty)
    #expect(try Data(contentsOf: harness.shortcutsURL) == invalidPayload)
    #expect(
        try Data(
            contentsOf: harness.directory
                .appendingPathComponent("shortcuts.load-failure-startup-duplicate.json")
        ) == invalidPayload
    )

    let statusProvider = ShortcutStatusProvider(
        client: .init(
            applicationURL: { _ in nil },
            runningBundleIdentifiers: { [] }
        ),
        workspaceNotificationCenter: NotificationCenter(),
        appNotificationCenter: NotificationCenter()
    )
    statusProvider.track(store.shortcuts)
    #expect(statusProvider.statusesByShortcutID.isEmpty)

    let insights = InsightsViewModel(
        usageTracker: EmptyUsageTracker(),
        shortcutStore: store
    )
    await insights.refresh(for: .week)
    #expect(insights.ranking.isEmpty)
    #expect(insights.appRows.isEmpty)
    #expect(insights.unusedShortcutNames.isEmpty)
}

@Test @MainActor
func openPrimarySettingsWindowUsesInstalledSettingsLauncherHandler() throws {
    ensureAppKitApplication()

    let suiteName = "AppControllerTests.openPrimarySettingsWindow.installed.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let controller = AppController(userDefaults: defaults)
    var openCount = 0
    controller.settingsLauncherService.installOpenSettingsHandler {
        openCount += 1
    }

    controller.openPrimarySettingsWindow()

    #expect(openCount == 1)
}

@Test @MainActor
func openPrimarySettingsWindowQueuesPendingOpenUntilHandlerInstalls() throws {
    ensureAppKitApplication()

    let suiteName = "AppControllerTests.openPrimarySettingsWindow.pending.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let controller = AppController(userDefaults: defaults)

    controller.openPrimarySettingsWindow()

    var openCount = 0
    controller.settingsLauncherService.installOpenSettingsHandler {
        openCount += 1
    }

    #expect(openCount == 1)
}

@MainActor
private func ensureAppKitApplication() {
    _ = NSApplication.shared
}

private actor EmptyUsageTracker: UsageTracking {

    func appActivationTotals(days: Int, relativeTo now: Date) async -> [(bundleIdentifier: String, count: Int)] {
        []
    }
    func deleteUsage(shortcutId: UUID) {}
    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] { [:] }
    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] { [:] }
    func totalSwitches(days: Int, relativeTo now: Date) async -> Int { 0 }
    func hourlyCounts(days: Int, relativeTo now: Date) async -> [HourlyUsageBucket] { [] }
    func previousPeriodTotal(days: Int, relativeTo now: Date) async -> Int { 0 }
    func streakDays(relativeTo now: Date) async -> Int { 0 }
    func usageTimeZone() async -> TimeZone { .current }
}
