import Foundation

struct HourlyUsageBucket: Sendable, Equatable, Hashable {
    let date: String
    let hour: Int
    let count: Int
}

enum UsageWindowMath {
    static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Canonical formatter for persisted usage date keys. `en_US_POSIX` pins
    /// ASCII digits so keys stay byte-stable and lexicographically ordered
    /// regardless of the user's locale or numbering system (issue #323);
    /// Arabic/Persian locales otherwise emit localized digits that fall
    /// outside ASCII TEXT range queries.
    static func dateKeyFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        return formatter
    }

    static func previousWindowReference(days: Int, relativeTo now: Date, in timeZone: TimeZone) -> Date {
        calendar(timeZone: timeZone).date(byAdding: .day, value: -max(days, 1), to: now) ?? now
    }

    static func windowDates(days: Int, relativeTo now: Date, in timeZone: TimeZone) -> (start: Date, end: Date, days: [Date]) {
        let clampedDays = max(days, 1)
        let calendar = calendar(timeZone: timeZone)
        let endDate = calendar.startOfDay(for: now)
        let startDate = calendar.date(byAdding: .day, value: -(clampedDays - 1), to: endDate) ?? endDate
        let days = (0..<clampedDays).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: startDate)
        }

        return (start: startDate, end: endDate, days: days)
    }
}

/// Parameters for one Insights refresh. The single `referenceDate` anchor is
/// shared by every dataset in the resulting snapshot.
struct UsageDashboardRequest: Sendable, Equatable {
    /// Days in the selected period window.
    let days: Int
    /// Days of daily history for per-app sparklines (`max(days, 7)`).
    let sparklineDays: Int
    let referenceDate: Date
}

/// Every dataset one Insights refresh needs, produced from one coherent read
/// boundary. The fixed 7-day datasets (heatmap, unused detection) reuse the
/// period datasets when the period itself is 7 days.
struct UsageDashboardSnapshot: Sendable {
    let timeZone: TimeZone
    let totalCount: Int
    let previousPeriodTotal: Int
    let counts: [UUID: Int]
    let previousCounts: [UUID: Int]
    let dailyCounts: [String: [(date: String, count: Int)]]
    let hourlyCounts: [HourlyUsageBucket]
    let heatmapBuckets: [HourlyUsageBucket]
    let unusedCounts: [UUID: Int]
    let streakDays: Int
}

protocol UsageTracking: Sendable {
    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int]
    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]]
    func totalSwitches(days: Int, relativeTo now: Date) async -> Int
    func hourlyCounts(days: Int, relativeTo now: Date) async -> [HourlyUsageBucket]
    func previousPeriodTotal(days: Int, relativeTo now: Date) async -> Int
    func streakDays(relativeTo now: Date) async -> Int
    func usageTimeZone() async -> TimeZone
    func lastUsedPerShortcut() async -> [UUID: Date]
    func deleteUsage(shortcutId: UUID) async
    /// Returns nil when the surrounding task was cancelled; a cancelled
    /// refresh stops issuing further queries instead of completing the
    /// remaining phases.
    func dashboardSnapshot(for request: UsageDashboardRequest) async -> UsageDashboardSnapshot?
}

extension UsageTracking {
    func usageCounts(days: Int) async -> [UUID: Int] {
        await usageCounts(days: days, relativeTo: Date())
    }

    func dailyCounts(days: Int) async -> [String: [(date: String, count: Int)]] {
        await dailyCounts(days: days, relativeTo: Date())
    }

    func totalSwitches(days: Int) async -> Int {
        await totalSwitches(days: days, relativeTo: Date())
    }

    func hourlyCounts(days: Int) async -> [HourlyUsageBucket] {
        await hourlyCounts(days: days, relativeTo: Date())
    }

    func previousPeriodTotal(days: Int) async -> Int {
        await previousPeriodTotal(days: days, relativeTo: Date())
    }

    func streakDays() async -> Int {
        await streakDays(relativeTo: Date())
    }

    func lastUsedPerShortcut() async -> [UUID: Date] {
        [:]
    }

    // deleteUsage deliberately has NO extension default: an async default
    // alongside UsageTracker's synchronous actor method would create a
    // sync/async overload pair, and async contexts prefer the async
    // candidate — silently routing concrete calls to a no-op.

    /// Serial composition over the individual query methods with a
    /// cancellation check before each phase and the 7-day datasets
    /// deduplicated. Conformers backed by real storage should override this
    /// with an implementation that also guarantees one coherent read
    /// boundary (see `UsageTracker`).
    func dashboardSnapshot(for request: UsageDashboardRequest) async -> UsageDashboardSnapshot? {
        guard !Task.isCancelled else { return nil }
        let timeZone = await usageTimeZone()
        let previousReference = UsageWindowMath.previousWindowReference(
            days: request.days,
            relativeTo: request.referenceDate,
            in: timeZone
        )

        guard !Task.isCancelled else { return nil }
        let totalCount = await totalSwitches(days: request.days, relativeTo: request.referenceDate)
        guard !Task.isCancelled else { return nil }
        let previousPeriodTotal = await previousPeriodTotal(days: request.days, relativeTo: request.referenceDate)
        guard !Task.isCancelled else { return nil }
        let counts = await usageCounts(days: request.days, relativeTo: request.referenceDate)
        guard !Task.isCancelled else { return nil }
        let previousCounts = await usageCounts(days: request.days, relativeTo: previousReference)
        guard !Task.isCancelled else { return nil }
        let dailyCounts = await dailyCounts(days: request.sparklineDays, relativeTo: request.referenceDate)
        guard !Task.isCancelled else { return nil }
        let hourlyCounts = await hourlyCounts(days: request.days, relativeTo: request.referenceDate)

        let heatmapBuckets: [HourlyUsageBucket]
        if request.days == 7 {
            heatmapBuckets = hourlyCounts
        } else {
            guard !Task.isCancelled else { return nil }
            heatmapBuckets = await self.hourlyCounts(days: 7, relativeTo: request.referenceDate)
        }

        let unusedCounts: [UUID: Int]
        if request.days == 7 {
            unusedCounts = counts
        } else {
            guard !Task.isCancelled else { return nil }
            unusedCounts = await usageCounts(days: 7, relativeTo: request.referenceDate)
        }

        guard !Task.isCancelled else { return nil }
        let streakDays = await streakDays(relativeTo: request.referenceDate)

        return UsageDashboardSnapshot(
            timeZone: timeZone,
            totalCount: totalCount,
            previousPeriodTotal: previousPeriodTotal,
            counts: counts,
            previousCounts: previousCounts,
            dailyCounts: dailyCounts,
            hourlyCounts: hourlyCounts,
            heatmapBuckets: heatmapBuckets,
            unusedCounts: unusedCounts,
            streakDays: streakDays
        )
    }
}
