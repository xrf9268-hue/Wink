import AppKit
import ServiceManagement
import SwiftUI
import Testing
@testable import Wink

@Suite("Layout regressions")
struct LayoutRegressionTests {
    @Test @MainActor
    func insightsRankingUsesScrollViewWhenRankingIsPopulated() async {
        let shortcutId = UUID()
        let store = ShortcutStore()
        store.replaceAll(with: [
            AppShortcut(
                id: shortcutId,
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["command"]
            )
        ])

        let viewModel = InsightsViewModel(
            usageTracker: StaticUsageTracker(shortcutId: shortcutId),
            shortcutStore: store
        )
        await viewModel.refresh(for: .week)

        let hostingView = makeHostingView(
            InsightsTabView(viewModel: viewModel),
            size: NSSize(width: 680, height: 420)
        )

        #expect(containsDescendant(in: hostingView) { $0 is NSScrollView })
    }

    @Test @MainActor
    func insightsCardUsesUpdatedSectionTitleCopy() {
        #expect(InsightsTabCopy.rankingSectionTitle == "Most used")
        #expect(InsightsTabCopy.rankingAccessoryText(totalCount: 112, period: .week) == "112 activations · 7 days")
    }

    @Test @MainActor
    func insightsKpiCardsUseEqualDesignHeight() {
        let hostingView = makeHostingView(
            InsightsKpiSection(
                totalCount: 1647,
                previousPeriodTotal: 1000,
                currentStreakDays: 12,
                sparklinePoints: [6, 9, 14, 11, 18, 21, 16]
            ),
            size: NSSize(width: 680, height: 220)
        )

        let cardFrames = hostingView.subviews
            .map(\.frame)
            .filter { $0.width > 150 && $0.height > 50 }
        let cardHeights = cardFrames.map(\.height)

        #expect(cardFrames.count == 3)
        #expect((cardHeights.max() ?? 0) - (cardHeights.min() ?? 0) <= 1)
    }

    @Test @MainActor
    func insightsHeatmapCellsExpandAcrossAvailableWidth() throws {
        let hostingView = makeHostingView(
            InsightsHourlyHeatmap(buckets: makeHeatmapBuckets()),
            size: NSSize(width: 680, height: 220)
        )

        let frames = descendants(in: hostingView).map { view in view.frame }
        let cells: [CGRect] = frames.filter { frame in
            abs(frame.height - 14) < 1 && frame.minX > 40 && frame.width > 18 && frame.width < 40
        }
        let firstRowY = try #require(cells.map { frame in frame.minY }.min())
        let firstRowCells = cells
            .filter { frame in abs(frame.minY - firstRowY) < 1 }
            .sorted { lhs, rhs in lhs.minX < rhs.minX }
        let first = try #require(firstRowCells.first)
        let last = try #require(firstRowCells.last)

        #expect(firstRowCells.count == 24)
        #expect(last.maxX - first.minX >= 580)
    }

    @Test @MainActor
    func insightsHeatmapWeekdayLabelsDoNotIncreaseRowHeight() throws {
        let hostingView = makeHostingView(
            InsightsHourlyHeatmap(buckets: makeHeatmapBuckets()),
            size: NSSize(width: 680, height: 220)
        )

        let cells: [CGRect] = descendants(in: hostingView)
            .map(\.frame)
            .filter { frame in
                abs(frame.height - 14) < 1 && frame.minX > 40 && frame.width > 18 && frame.width < 40
            }
        let rowOrigins = Dictionary(grouping: cells, by: { Int($0.minY.rounded()) })
            .filter { _, rowCells in rowCells.count >= 20 }
            .keys
            .sorted()
            .map(CGFloat.init)
        let rowGaps = zip(rowOrigins, rowOrigins.dropFirst()).map { $1 - $0 }

        #expect(rowOrigins.count == 7)
        #expect((rowGaps.max() ?? 0) <= 18)
    }

    @Test @MainActor
    func insightsMostUsedRowUsesCompactDesignColumns() {
        let hostingView = makeHostingView(
            InsightsAppRow(
                item: InsightsAppRowModel(
                    id: UUID(),
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    count: 70,
                    progress: 0.62,
                    delta: InsightsChange(text: "+18%", tone: .positive),
                    sparklinePoints: [4, 6, 8, 7, 12, 14, 11, 8]
                ),
                showsDivider: false
            ),
            size: NSSize(width: 660, height: 80)
        )

        let rootHeight = hostingView.subviews.first?.frame.height ?? 0
        let longProgressBars = descendants(in: hostingView)
            .map { view in view.frame }
            .filter { frame in frame.height <= 8 && frame.width >= 280 }

        #expect(rootHeight <= 56)
        #expect(!longProgressBars.isEmpty)
    }

    @Test @MainActor
    func generalTabDoesNotCreateNestedFormScroller() {
        let context = SettingsViewLayoutContext()
        defer { context.harness.cleanup() }

        let hostingView = makeHostingView(
            GeneralTabView(preferences: context.preferences, editor: context.editor),
            size: NSSize(width: 700, height: 560)
        )

        let scrollViewsWithVerticalScrollers = descendants(in: hostingView)
            .compactMap { $0 as? NSScrollView }
            .filter(\.hasVerticalScroller)

        #expect(scrollViewsWithVerticalScrollers.count == 1)
    }

    @Test @MainActor
    func generalKeyboardCardMatchesDesignRowDensity() {
        let context = SettingsViewLayoutContext()
        defer { context.harness.cleanup() }

        let hostingView = makeHostingView(
            GeneralTabView(preferences: context.preferences, editor: context.editor),
            size: NSSize(width: 700, height: 620)
        )

        let candidateCardHeights = hostingView.subviews
            .flatMap { descendants(in: $0) + [$0] }
            .map(\.frame.height)
            .filter { $0 >= 120 && $0 <= 180 }

        #expect(candidateCardHeights.contains { abs($0 - 138) <= 18 })
    }

    @Test
    func settingsWindowUsesGeneralDesignReferenceHeight() {
        #expect(SettingsWindowMetrics.width == 860)
        #expect(SettingsWindowMetrics.height == 780)
    }

    @Test @MainActor
    func winkCardExpandsToFillWidthInsideLeadingStack() {
        let hostingView = makeHostingView(
            CardWidthProbeView(),
            size: NSSize(width: 720, height: 220)
        )

        let widestDirectSubview = hostingView.subviews
            .map(\.frame.width)
            .max() ?? 0

        #expect(widestDirectSubview >= 660)
    }

    @Test @MainActor
    func shortcutsListRowPresentationUsesUsageSubtitleWithoutVisibleBundleIdentifier() {
        let shortcut = AppShortcut(
            appName: "Missing App",
            bundleIdentifier: "com.example.MissingApp",
            keyEquivalent: "m",
            modifierFlags: ["command", "shift"]
        )
        let presentation = ShortcutsListRowPresentation(
            shortcut: shortcut,
            usageCount: 732,
            runtimeStatus: ShortcutRuntimeStatus(
                isRunning: false,
                isUnavailable: true
            )
        )

        #expect(presentation.title == "Missing App")
        #expect(presentation.subtitle == "732× past 7 days")
        // usageCount > 0 but lastUsed is nil: show the em-dash placeholder so the
        // user still sees the "past 7 days" counter rather than a misleading "—".
        #expect(presentation.metadataText == "732× past 7 days · Last used —")
        #expect(presentation.contentOpacity == 1.0)
        #expect(presentation.showsRunningIndicator == false)
        #expect(presentation.runningStatusText == nil)
        #expect(presentation.unavailableStatusText == "App unavailable")
        #expect(presentation.unavailableHelpText == "Couldn't find this app. Rebind it to restore the shortcut.")
        #expect(presentation.title != "com.example.MissingApp")
        #expect(presentation.subtitle != "com.example.MissingApp")
        #expect(presentation.unavailableStatusText != "com.example.MissingApp")
        #expect(presentation.unavailableHelpText != "com.example.MissingApp")
    }

    @Test @MainActor
    func shortcutsListRowPresentationRendersNotUsedYetWhenUsageCountIsZero() {
        let shortcut = AppShortcut(
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            keyEquivalent: "n",
            modifierFlags: ["command", "option"]
        )
        let presentation = ShortcutsListRowPresentation(
            shortcut: shortcut,
            usageCount: 0,
            runtimeStatus: ShortcutRuntimeStatus(isRunning: false, isUnavailable: false)
        )

        #expect(presentation.metadataText == "Not used yet")
    }

    @Test @MainActor
    func shortcutsListRowPresentationShowsHistoricalLastUsedWhenSevenDayCountIsZero() {
        // Shortcut triggered more than 7 days ago: usageCount drops to 0 but the
        // hourly history still carries a timestamp. We should surface the historical
        // last-used rather than falsely claiming the shortcut was never used.
        let shortcut = AppShortcut(
            appName: "Zed",
            bundleIdentifier: "dev.zed.Zed",
            keyEquivalent: "z",
            modifierFlags: ["command", "option", "shift", "control"]
        )
        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-10 * 24 * 60 * 60)
        let presentation = ShortcutsListRowPresentation(
            shortcut: shortcut,
            usageCount: 0,
            runtimeStatus: ShortcutRuntimeStatus(isRunning: false, isUnavailable: false),
            lastUsed: tenDaysAgo,
            now: now
        )

        #expect(presentation.metadataText != "Not used yet")
        #expect(presentation.metadataText.hasPrefix("Last used "))
        #expect(!presentation.metadataText.contains("past 7 days"))
    }

    @Test @MainActor
    func shortcutsListRowPresentationRendersRelativeLastUsedWhenDateIsProvided() {
        let shortcut = AppShortcut(
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t",
            modifierFlags: ["command", "option"]
        )
        let now = Date()
        let twoHoursAgo = now.addingTimeInterval(-2 * 60 * 60)
        let presentation = ShortcutsListRowPresentation(
            shortcut: shortcut,
            usageCount: 32,
            runtimeStatus: ShortcutRuntimeStatus(isRunning: false, isUnavailable: false),
            lastUsed: twoHoursAgo,
            now: now
        )

        #expect(presentation.metadataText.hasPrefix("32× past 7 days · Last used "))
        #expect(presentation.metadataText != "32× past 7 days · Last used —")
        #expect(presentation.lastUsedText != "Last used —")
    }

    @Test @MainActor
    func shortcutsListRowPresentationShowsRunningIndicatorWhenAppIsActive() {
        let shortcut = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
        let presentation = ShortcutsListRowPresentation(
            shortcut: shortcut,
            usageCount: 12,
            runtimeStatus: ShortcutRuntimeStatus(
                isRunning: true,
                isUnavailable: false
            )
        )

        #expect(presentation.showsRunningIndicator == true)
        #expect(presentation.runningStatusText == nil)
        #expect(presentation.unavailableHelpText == nil)
    }

    @Test @MainActor
    func shortcutsListRowPresentationAddsRunningLabelWhenDifferentiateWithoutColorIsEnabled() {
        let shortcut = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
        let presentation = ShortcutsListRowPresentation(
            shortcut: shortcut,
            usageCount: 12,
            runtimeStatus: ShortcutRuntimeStatus(
                isRunning: true,
                isUnavailable: false
            ),
            accessibilityOptions: ShortcutRowAccessibilityOptions(
                differentiateWithoutColor: true,
                reduceMotion: false
            )
        )

        #expect(presentation.showsRunningIndicator == true)
        #expect(presentation.runningStatusText == "Running")
        #expect(presentation.unavailableStatusText == nil)
    }

    @Test @MainActor
    func shortcutsListRowPresentationOnlyDimsDisabledRows() {
        let shortcut = AppShortcut(
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t",
            modifierFlags: ["command"],
            isEnabled: false
        )
        let presentation = ShortcutsListRowPresentation(
            shortcut: shortcut,
            usageCount: 4,
            runtimeStatus: ShortcutRuntimeStatus(
                isRunning: false,
                isUnavailable: true
            )
        )

        #expect(presentation.contentOpacity == 0.65)
        #expect(presentation.unavailableStatusText == "App unavailable")
    }

    @Test @MainActor
    func shortcutComposerUsesExpectedRecorderPlaceholderAndDashSpec() {
        #expect(ShortcutRecorderIdleField.placeholderText == "Press a key combination…")
        #expect(ShortcutRecorderIdleField.dashPattern == [4, 4])
    }

    @Test @MainActor
    func shortcutsTabExposesSingleVerticalScroller() {
        let context = ShortcutsTabLayoutContext(shortcutCount: 4)
        defer { context.harness.cleanup() }

        let hostingView = makeHostingView(
            ShortcutsTabView(
                editor: context.editor,
                preferences: context.preferences,
                appListProvider: context.appListProvider,
                shortcutStatusProvider: context.shortcutStatusProvider
            ),
            size: NSSize(width: 700, height: 430)
        )

        let scrollViewsWithVerticalScrollers = descendants(in: hostingView)
            .compactMap { $0 as? NSScrollView }
            .filter(\.hasVerticalScroller)

        #expect(scrollViewsWithVerticalScrollers.count == 1)
    }

    @Test @MainActor
    func shortcutsListUsesAvailableHeightInsteadOfFixedCap() throws {
        let context = ShortcutsTabLayoutContext(shortcutCount: 4)
        defer { context.harness.cleanup() }

        let hostingView = makeHostingView(
            ShortcutsTabView(
                editor: context.editor,
                preferences: context.preferences,
                appListProvider: context.appListProvider,
                shortcutStatusProvider: context.shortcutStatusProvider
            ),
            size: NSSize(width: 700, height: 640)
        )

        let listScrollerHeight = try #require(
            descendants(in: hostingView)
                .compactMap { $0 as? NSScrollView }
                .filter(\.hasVerticalScroller)
                .map(\.frame.height)
                .max()
        )

        #expect(listScrollerHeight > 220)
    }

    @Test @MainActor
    func shortcutsLongListStaysInsideAvailableHeight() throws {
        let context = ShortcutsTabLayoutContext(shortcutCount: 24)
        defer { context.harness.cleanup() }

        let hostingView = makeHostingView(
            ShortcutsTabView(
                editor: context.editor,
                preferences: context.preferences,
                appListProvider: context.appListProvider,
                shortcutStatusProvider: context.shortcutStatusProvider
            ),
            size: NSSize(width: 700, height: 640)
        )

        let listScrollerHeight = try #require(
            descendants(in: hostingView)
                .compactMap { $0 as? NSScrollView }
                .filter(\.hasVerticalScroller)
                .map(\.frame.height)
                .max()
        )

        #expect(listScrollerHeight > 220)
        #expect(listScrollerHeight < 430)
    }

    @Test @MainActor
    func insightsTabExposesSinglePageScroller() async {
        let shortcutId = UUID()
        let store = ShortcutStore()
        store.replaceAll(with: [
            AppShortcut(
                id: shortcutId,
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["command"]
            )
        ])

        let viewModel = InsightsViewModel(
            usageTracker: StaticUsageTracker(shortcutId: shortcutId),
            shortcutStore: store
        )
        await viewModel.refresh(for: .week)

        let hostingView = makeHostingView(
            InsightsTabView(viewModel: viewModel),
            size: NSSize(width: 700, height: 430)
        )

        let scrollViewsWithVerticalScrollers = descendants(in: hostingView)
            .compactMap { $0 as? NSScrollView }
            .filter(\.hasVerticalScroller)

        #expect(scrollViewsWithVerticalScrollers.count == 1)
    }

    @Test @MainActor
    func importPreviewUsesDedicatedScrollerWithoutRestoringPageScroller() throws {
        let context = ShortcutsTabLayoutContext(shortcutCount: 4)
        defer { context.harness.cleanup() }

        let keyEquivalents = [
            "e", "f", "g", "h", "i", "j", "k", "l",
            "m", "n", "o", "p", "q", "r", "u", "v",
            "w", "x", "y", "z", "1", "2", "3", "4",
        ]
        let recipe = WinkRecipe(shortcuts: keyEquivalents.enumerated().map { index, keyEquivalent in
            WinkRecipeShortcut(
                appName: "Imported \(index + 1)",
                bundleIdentifier: "com.example.imported\(index + 1)",
                keyEquivalent: keyEquivalent,
                modifierFlags: ["command", "shift"],
                isEnabled: true
            )
        })
        let data = try WinkRecipeCodec().encode(recipe)
        try context.editor.beginImport(from: data, installedApps: [])

        let hostingView = makeHostingView(
            ShortcutsTabView(
                editor: context.editor,
                preferences: context.preferences,
                appListProvider: context.appListProvider,
                shortcutStatusProvider: context.shortcutStatusProvider
            ),
            size: NSSize(width: 700, height: 430)
        )

        let scrollViewsWithVerticalScrollers = descendants(in: hostingView)
            .compactMap { $0 as? NSScrollView }
            .filter(\.hasVerticalScroller)

        #expect(scrollViewsWithVerticalScrollers.count == 2)
    }

    @Test @MainActor
    func settingsViewUsesCompactSidebarColumnWidth() throws {
        let context = SettingsViewLayoutContext()
        defer { context.harness.cleanup() }

        let hostingView = makeHostingView(
            SettingsView(
                editor: context.editor,
                preferences: context.preferences,
                insightsViewModel: context.insightsViewModel,
                appListProvider: context.appListProvider,
                shortcutStatusProvider: context.shortcutStatusProvider,
                settingsLauncher: context.settingsLauncher
            ),
            size: NSSize(width: 900, height: 640)
        )

        let splitViews = descendants(in: hostingView)
            .compactMap { $0 as? NSSplitView }
        let splitView = try #require(splitViews.first)
        let sidebarWidth = splitView.arrangedSubviews.first?.frame.width ?? 0

        #expect(abs(sidebarWidth - 150) < 1)
        #expect(splitView.frame.minY >= -1)
        #expect(splitView.frame.height <= hostingView.bounds.height + 1)
    }

    @Test @MainActor
    func settingsWindowChromeConfiguratorGrowsTitlebarToDesignHeight() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = SettingsWindowChromeCoordinator()

        coordinator.attach(to: window)
        window.layoutIfNeeded()

        let topInset = window.frame.height - window.contentLayoutRect.maxY
        let accessory = try #require(window.titlebarAccessoryViewControllers.first)
        let closeButton = try #require(window.standardWindowButton(.closeButton))
        let titlebarView = try #require(closeButton.superview)
        let sidebarToggle = try #require(titlebarView.subviews.first {
            $0.identifier == SettingsTitlebarLayout.sidebarToggleIdentifier
        })
        let customTitle = try #require(titlebarView.subviews.first {
            $0.identifier == SettingsTitlebarLayout.titleIdentifier
        })
        let toggleCenterYFromTop = titlebarView.bounds.height - sidebarToggle.frame.midY
        let titleCenterYFromTop = titlebarView.bounds.height - customTitle.frame.midY

        #expect(abs(topInset - SettingsTitlebarLayout.height) < 0.5)
        #expect(abs(titlebarView.bounds.height - SettingsTitlebarLayout.height) < 0.5)
        #expect(accessory.layoutAttribute == .bottom)
        #expect(accessory.automaticallyAdjustsSize == false)
        #expect(abs(accessory.view.frame.height - SettingsTitlebarLayout.titlebarAccessoryHeight) < 0.5)
        #expect(abs(sidebarToggle.frame.minX - SettingsTitlebarLayout.toggleLeadingX) < 0.5)
        #expect(abs(toggleCenterYFromTop - SettingsTitlebarLayout.baselineCenterY) < 0.5)
        #expect(abs(customTitle.frame.midX - titlebarView.bounds.midX) < 0.5)
        #expect(abs(titleCenterYFromTop - SettingsTitlebarLayout.baselineCenterY) < 0.5)
    }
}

private actor StaticUsageTracker: UsageTracking {
    let shortcutId: UUID

    init(shortcutId: UUID) {
        self.shortcutId = shortcutId
    }

    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] {
        [shortcutId: 1647]
    }

    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        return [
            shortcutId.uuidString: [
                (date: formatter.string(from: now), count: 1647),
            ]
        ]
    }

    func totalSwitches(days: Int, relativeTo now: Date) async -> Int {
        1647
    }

    func hourlyCounts(days: Int, relativeTo now: Date) async -> [HourlyUsageBucket] {
        []
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

private struct CardWidthProbeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WinkCard(title: { Text("Startup") }) {
                Text("Launch at Login")
                    .padding(14)
            }

            Spacer()
        }
        .frame(width: 680, height: 180)
        .padding(20)
    }
}

private func makeHeatmapBuckets() -> [HourlyUsageBucket] {
    (0..<7).flatMap { day in
        (0..<24).map { hour in
            HourlyUsageBucket(
                date: "2026-04-\(String(format: "%02d", 20 + day))",
                hour: hour,
                count: (day + hour) % 5
            )
        }
    }
}

@MainActor
private final class ShortcutsTabLayoutContext {
    let harness = TestPersistenceHarness()
    let shortcutStore = ShortcutStore()
    let editor: ShortcutEditorState
    let preferences: AppPreferences
    let appListProvider: AppListProvider
    let shortcutStatusProvider: ShortcutStatusProvider

    init(shortcutCount: Int) {
        let shortcuts = (0..<shortcutCount).map { index in
            AppShortcut(
                appName: "App \(index + 1)",
                bundleIdentifier: "com.example.app\(index + 1)",
                keyEquivalent: String(UnicodeScalar(97 + index)!),
                modifierFlags: index == 0
                    ? ["command", "option", "control", "shift"]
                    : ["command", "option"]
            )
        }
        shortcutStore.replaceAll(with: shortcuts)

        let manager = ShortcutManager(
            shortcutStore: shortcutStore,
            persistenceService: harness.makePersistenceService(),
            appSwitcher: LayoutFakeAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: LayoutFakeCaptureProvider(),
                hyperProvider: LayoutFakeHyperCaptureProvider()
            ),
            permissionService: LayoutFakePermissionService(),
            diagnosticClient: .live
        )

        editor = ShortcutEditorState(
            shortcutStore: shortcutStore,
            shortcutManager: manager
        )
        preferences = AppPreferences(
            shortcutManager: manager,
            launchAtLoginService: LaunchAtLoginService(client: .init(
                status: { .notRegistered },
                register: {},
                unregister: {},
                openSystemSettingsLoginItems: {}
            ))
        )
        appListProvider = AppListProvider(client: .init(
            now: { Date() },
            scanInstalledApps: { [] },
            runningApplications: { [] },
            loadRecents: { [] },
            saveRecents: { _ in },
            mainBundleIdentifier: { "dev.wink.tests" }
        ))
        shortcutStatusProvider = ShortcutStatusProvider(
            client: .init(
                applicationURL: { _ in URL(fileURLWithPath: "/Applications/Fake.app") },
                runningBundleIdentifiers: { [] }
            ),
            workspaceNotificationCenter: NotificationCenter(),
            appNotificationCenter: NotificationCenter()
        )
    }
}

@MainActor
private final class SettingsViewLayoutContext {
    let harness = TestPersistenceHarness()
    let shortcutStore = ShortcutStore()
    let editor: ShortcutEditorState
    let preferences: AppPreferences
    let insightsViewModel: InsightsViewModel
    let appListProvider: AppListProvider
    let shortcutStatusProvider: ShortcutStatusProvider
    let settingsLauncher = SettingsLauncher(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)

    init() {
        let shortcut = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command", "option"]
        )
        shortcutStore.replaceAll(with: [shortcut])

        let manager = ShortcutManager(
            shortcutStore: shortcutStore,
            persistenceService: harness.makePersistenceService(),
            appSwitcher: LayoutFakeAppSwitcher(),
            captureCoordinator: ShortcutCaptureCoordinator(
                standardProvider: LayoutFakeCaptureProvider(),
                hyperProvider: LayoutFakeHyperCaptureProvider()
            ),
            permissionService: LayoutFakePermissionService(),
            diagnosticClient: .live
        )

        editor = ShortcutEditorState(
            shortcutStore: shortcutStore,
            shortcutManager: manager
        )
        preferences = AppPreferences(
            shortcutManager: manager,
            launchAtLoginService: LaunchAtLoginService(client: .init(
                status: { .notRegistered },
                register: {},
                unregister: {},
                openSystemSettingsLoginItems: {}
            ))
        )
        insightsViewModel = InsightsViewModel(
            usageTracker: StaticUsageTracker(shortcutId: shortcut.id),
            shortcutStore: shortcutStore
        )
        appListProvider = AppListProvider(client: .init(
            now: { Date() },
            scanInstalledApps: { [] },
            runningApplications: { [] },
            loadRecents: { [] },
            saveRecents: { _ in },
            mainBundleIdentifier: { "dev.wink.tests" }
        ))
        shortcutStatusProvider = ShortcutStatusProvider(
            client: .init(
                applicationURL: { _ in URL(fileURLWithPath: "/Applications/Fake.app") },
                runningBundleIdentifiers: { [] }
            ),
            workspaceNotificationCenter: NotificationCenter(),
            appNotificationCenter: NotificationCenter()
        )
    }
}

@MainActor
private struct LayoutFakeAppSwitcher: AppSwitching {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        true
    }
}

@MainActor
private final class LayoutFakeCaptureProvider: ShortcutCaptureProvider {
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
private final class LayoutFakeHyperCaptureProvider: HyperShortcutCaptureProvider {
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

private struct LayoutFakePermissionService: PermissionServicing {
    func isTrusted() -> Bool { true }
    func isAccessibilityTrusted() -> Bool { true }
    func isInputMonitoringTrusted() -> Bool { true }

    @discardableResult
    func requestIfNeeded(prompt: Bool, inputMonitoringRequired: Bool) -> Bool {
        true
    }
}

@MainActor
private func descendants(in view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { descendants(in: $0) }
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
private func containsDescendant(
    in view: NSView,
    where matches: (NSView) -> Bool
) -> Bool {
    if matches(view) {
        return true
    }

    for subview in view.subviews {
        if containsDescendant(in: subview, where: matches) {
            return true
        }
    }

    return false
}
