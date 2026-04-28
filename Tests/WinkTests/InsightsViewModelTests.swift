import Foundation
import Testing
@testable import Wink

actor DelayedUsageTracker: UsageTracking {
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

