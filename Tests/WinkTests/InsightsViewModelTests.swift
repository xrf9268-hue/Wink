import Foundation
import Testing
@testable import Wink

actor DelayedUsageTracker: UsageTracking {

    func appActivationTotals(days: Int, relativeTo now: Date) async -> [(bundleIdentifier: String, count: Int)] {
        []
    }
    func deleteUsage(shortcutId: UUID) {}
    let shortcutId: UUID

    init(shortcutId: UUID) {
        self.shortcutId = shortcutId
    }

    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] {
        try? await Task.sleep(for: .milliseconds(days == 30 ? 80 : 5))
        return [shortcutId: days]
    }

    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] {
        try? await Task.sleep(for: .milliseconds(days == 30 ? 80 : 5))
        return [:]
    }

    func totalSwitches(days: Int, relativeTo now: Date) async -> Int {
        try? await Task.sleep(for: .milliseconds(days == 30 ? 80 : 5))
        return days
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

actor BoundaryCrossingUsageTracker: UsageTracking {

    func appActivationTotals(days: Int, relativeTo now: Date) async -> [(bundleIdentifier: String, count: Int)] {
        []
    }
    func deleteUsage(shortcutId: UUID) {}
    let shortcutId: UUID

    init(shortcutId: UUID) {
        self.shortcutId = shortcutId
    }

    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] {
        [shortcutId: 1]
    }

    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] {
        [shortcutId.uuidString: [(date: dateString(for: now), count: 1)]]
    }

    func totalSwitches(days: Int, relativeTo now: Date) async -> Int {
        1
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

actor TimeZoneAlignedUsageTracker: UsageTracking {

    func appActivationTotals(days: Int, relativeTo now: Date) async -> [(bundleIdentifier: String, count: Int)] {
        []
    }
    func deleteUsage(shortcutId: UUID) {}
    let shortcutId: UUID
    let timeZone: TimeZone

    init(shortcutId: UUID, timeZone: TimeZone) {
        self.shortcutId = shortcutId
        self.timeZone = timeZone
    }

    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] {
        [shortcutId: 5]
    }

    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] {
        let keys = dateKeys(for: days, relativeTo: now, in: timeZone)
        return [
            shortcutId.uuidString: [
                (date: keys.last ?? "", count: 5),
            ]
        ]
    }

    func totalSwitches(days: Int, relativeTo now: Date) async -> Int {
        5
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
        timeZone
    }
}

/// Reports nonzero usage for exactly one shortcut id, zero (absent) for
/// every other — enough to distinguish "genuinely unused" from "excluded
/// from the nudge entirely" in `unusedShortcutNudgeExcludesTheSearchPaletteTrigger`.
private actor SingleShortcutUsageTracker: UsageTracking {
    let usedShortcutId: UUID

    init(usedShortcutId: UUID) {
        self.usedShortcutId = usedShortcutId
    }

    func appActivationTotals(days: Int, relativeTo now: Date) async -> [(bundleIdentifier: String, count: Int)] { [] }
    func deleteUsage(shortcutId: UUID) {}
    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] { [usedShortcutId: 5] }
    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] { [:] }
    func totalSwitches(days: Int, relativeTo now: Date) async -> Int { 5 }
    func hourlyCounts(days: Int, relativeTo now: Date) async -> [HourlyUsageBucket] { [] }
    func previousPeriodTotal(days: Int, relativeTo now: Date) async -> Int { 0 }
    func streakDays(relativeTo now: Date) async -> Int { 0 }
    func usageTimeZone() async -> TimeZone { .current }
}

/// #356: the search-palette trigger never records per-shortcut usage (its
/// key match dispatches through `onSearchPaletteTriggered`, not
/// `ShortcutManager.trigger(_:)`), so without an explicit exclusion it would
/// always read as zero-count and get nudged for removal — even a trigger the
/// user presses constantly. A genuinely unused real app shortcut (IINA)
/// stays in the nudge; the trigger never appears in it at all.
@Test @MainActor
func unusedShortcutNudgeExcludesTheSearchPaletteTrigger() async {
    let safari = AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command"]
    )
    let iina = AppShortcut(
        appName: "IINA",
        bundleIdentifier: "com.colliderli.iina",
        keyEquivalent: "i",
        modifierFlags: ["command", "option"]
    )
    let paletteTrigger = AppShortcut(
        appName: AppShortcut.searchPaletteTargetStableName,
        bundleIdentifier: AppShortcut.searchPaletteTargetSentinelBundleIdentifier,
        keyEquivalent: "space",
        modifierFlags: ["command", "option"],
        target: .searchPalette
    )
    let store = ShortcutStore()
    store.replaceAll(with: [safari, iina, paletteTrigger])

    let viewModel = InsightsViewModel(
        usageTracker: SingleShortcutUsageTracker(usedShortcutId: safari.id),
        shortcutStore: store
    )
    await viewModel.refresh(for: .week)

    #expect(viewModel.unusedShortcutNames == ["IINA"])
}

@Test @MainActor
func latestPeriodWinsWhenRefreshesOverlap() async {
    let shortcutId = UUID()
    let store = ShortcutStore()
    store.replaceAll(with: [
        AppShortcut(
            id: shortcutId,
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t",
            modifierFlags: ["command"]
        )
    ])

    let viewModel = InsightsViewModel(
        usageTracker: DelayedUsageTracker(shortcutId: shortcutId),
        shortcutStore: store
    )

    viewModel.period = .month
    viewModel.period = .day

    await viewModel.waitForRefreshForTesting()

    #expect(viewModel.period == .day)
    #expect(viewModel.totalCount == 1)
    #expect(viewModel.ranking.first?.id == shortcutId)
    #expect(viewModel.ranking.first?.count == 1)
}

@Test @MainActor
func refreshForSyncsPeriodSelectionWithDisplayedData() async {
    let shortcutId = UUID()
    let store = ShortcutStore()
    store.replaceAll(with: [
        AppShortcut(
            id: shortcutId,
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t",
            modifierFlags: ["command"]
        )
    ])

    let viewModel = InsightsViewModel(
        usageTracker: DelayedUsageTracker(shortcutId: shortcutId),
        shortcutStore: store
    )
    #expect(viewModel.period == .week)

    // refresh(for:) must keep the picker state and the displayed data in
    // sync — month data with a week picker selection is a contract violation
    // (Issue #265).
    await viewModel.refresh(for: .month)

    #expect(viewModel.period == .month)
    #expect(viewModel.totalCount == 30)
}

@Test @MainActor
func refreshForIsSupersededByLaterPeriodSelection() async {
    let shortcutId = UUID()
    let store = ShortcutStore()
    store.replaceAll(with: [
        AppShortcut(
            id: shortcutId,
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t",
            modifierFlags: ["command"]
        )
    ])

    let viewModel = InsightsViewModel(
        usageTracker: DelayedUsageTracker(shortcutId: shortcutId),
        shortcutStore: store
    )

    // Slow month refresh through the async variant, superseded by a fast
    // day selection through the picker path. The last selection must win
    // even when the variants are mixed.
    let monthRefresh = Task { @MainActor in
        await viewModel.refresh(for: .month)
    }
    await Task.yield()
    viewModel.period = .day
    await monthRefresh.value
    await viewModel.waitForRefreshForTesting()

    #expect(viewModel.period == .day)
    #expect(viewModel.totalCount == 1)
    #expect(viewModel.ranking.first?.count == 1)
}

@Test @MainActor
func refreshUsesRelativeAnchorQueriesInsteadOfNonRelativeFallbacks() async {
    let shortcutId = UUID()
    let store = ShortcutStore()
    store.replaceAll(with: [
        AppShortcut(
            id: shortcutId,
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t",
            modifierFlags: ["command"]
        )
    ])

    let viewModel = InsightsViewModel(
        usageTracker: BoundaryCrossingUsageTracker(shortcutId: shortcutId),
        shortcutStore: store
    )

    await viewModel.refresh(for: .week)

    #expect(viewModel.totalCount == 1)
    #expect(viewModel.ranking.first?.count == 1)
}

@Test @MainActor
func refreshUsesTrackerTimeZoneForSparklineDateKeys() async {
    let shortcutId = UUID()
    let store = ShortcutStore()
    store.replaceAll(with: [
        AppShortcut(
            id: shortcutId,
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t",
            modifierFlags: ["command"]
        )
    ])
    let referenceNow = fixedDate("2026-04-22T23:30:00Z")
    let trackerTimeZone = timeZoneDistinctFromCurrent(relativeTo: referenceNow)
    let viewModel = InsightsViewModel(
        usageTracker: TimeZoneAlignedUsageTracker(shortcutId: shortcutId, timeZone: trackerTimeZone),
        shortcutStore: store,
        nowProvider: { referenceNow }
    )

    await viewModel.refresh(for: .week)

    #expect(viewModel.appRows.first?.sparklinePoints.last == 5)
}

private func dateString(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = .current
    return formatter.string(from: date)
}

private func dateKeys(for days: Int, relativeTo now: Date, in timeZone: TimeZone) -> [String] {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = timeZone

    return UsageWindowMath.windowDates(days: days, relativeTo: now, in: timeZone).days.map {
        formatter.string(from: $0)
    }
}

private func fixedDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: value)!
}

private func timeZoneDistinctFromCurrent(relativeTo now: Date) -> TimeZone {
    let candidates = [
        TimeZone(identifier: "Pacific/Kiritimati"),
        TimeZone(secondsFromGMT: -11 * 3_600),
        TimeZone(secondsFromGMT: 0),
        TimeZone(secondsFromGMT: 9 * 3_600),
    ].compactMap { $0 }
    let currentKeys = dateKeys(for: 7, relativeTo: now, in: .current)

    return candidates.first(where: {
        dateKeys(for: 7, relativeTo: now, in: $0) != currentKeys
    }) ?? TimeZone(secondsFromGMT: 0)!
}


// MARK: - Suggested shortcuts

/// Serves a fixed activation-totals list; every other tracking read is inert.
private actor ActivationTotalsUsageTracker: UsageTracking {
    let totals: [(bundleIdentifier: String, count: Int)]

    init(totals: [(bundleIdentifier: String, count: Int)]) {
        self.totals = totals
    }

    func appActivationTotals(days: Int, relativeTo now: Date) async -> [(bundleIdentifier: String, count: Int)] {
        totals
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

/// Historical `app_activations` rows can name background-only system
/// processes recorded before the record-time gate existed (the reported
/// case: universalAccessAuthWarn, the Accessibility auth-warning dialog).
/// The query side must drop them AND let the next resolvable app take the
/// freed suggestion slot, alongside the existing bound/unresolvable drops.
@Test @MainActor
func suggestionsDropIneligibleAppsAndBackfillFreedSlots() async throws {
    let boundShortcut = AppShortcut(
        appName: "Bound",
        bundleIdentifier: "com.example.bound",
        keyEquivalent: "b",
        modifierFlags: ["command"]
    )
    let store = ShortcutStore()
    store.replaceAll(with: [boundShortcut])

    let dialogFixtureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wink-insights-\(UUID().uuidString)")
    let dialogApp = dialogFixtureRoot.appendingPathComponent("authWarnFixture.app")
    let contents = dialogApp.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try PropertyListSerialization.data(
        fromPropertyList: ["LSUIElement": 1],
        format: .xml,
        options: 0
    ).write(to: contents.appendingPathComponent("Info.plist"))

    let urls: [String: URL] = [
        "com.example.bound": URL(fileURLWithPath: "/Applications/Bound.app"),
        "com.example.first": URL(fileURLWithPath: "/Applications/First.app"),
        "com.example.dialog": dialogApp,
        "com.example.second": URL(fileURLWithPath: "/Applications/Second.app"),
        "com.example.third": URL(fileURLWithPath: "/Applications/Third.app"),
        "com.example.fourth": URL(fileURLWithPath: "/Applications/Fourth.app"),
    ]
    var resolvedBundleIDs: [String] = []
    let viewModel = InsightsViewModel(
        usageTracker: ActivationTotalsUsageTracker(totals: [
            (bundleIdentifier: "com.example.bound", count: 40),
            (bundleIdentifier: "com.example.first", count: 30),
            (bundleIdentifier: "com.example.dialog", count: 20),
            (bundleIdentifier: "com.example.uninstalled", count: 15),
            (bundleIdentifier: "com.example.second", count: 10),
            (bundleIdentifier: "com.example.third", count: 5),
            (bundleIdentifier: "com.example.fourth", count: 2),
        ]),
        shortcutStore: store,
        appURLResolver: { bundleIdentifier in
            resolvedBundleIDs.append(bundleIdentifier)
            return urls[bundleIdentifier]
        }
    )
    await viewModel.refresh(for: .week)

    // bound → already has a shortcut; dialog → LSUIElement fixture;
    // uninstalled → unresolvable. Each freed slot backfills in count order.
    #expect(viewModel.suggestedApps.map(\.bundleIdentifier) == [
        "com.example.first",
        "com.example.second",
        "com.example.third",
    ])
    #expect(viewModel.suggestedApps.map(\.name) == ["First", "Second", "Third"])
    #expect(viewModel.suggestedApps.map(\.count) == [30, 10, 5])

    // The lazy pipeline stops at the third eligible suggestion: the bound
    // entry is filtered without resolving, ineligible rows are visited on
    // the way, and everything past "third" is never touched — the table has
    // no age-out, so a long history must not be resolved wholesale.
    #expect(resolvedBundleIDs == [
        "com.example.first",
        "com.example.dialog",
        "com.example.uninstalled",
        "com.example.second",
        "com.example.third",
    ])
}
