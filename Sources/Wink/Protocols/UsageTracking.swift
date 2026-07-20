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

protocol UsageTracking: Sendable {
    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int]
    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]]
    func totalSwitches(days: Int, relativeTo now: Date) async -> Int
    func hourlyCounts(days: Int, relativeTo now: Date) async -> [HourlyUsageBucket]
    func previousPeriodTotal(days: Int, relativeTo now: Date) async -> Int
    func streakDays(relativeTo now: Date) async -> Int
    func usageTimeZone() async -> TimeZone
    func lastUsedPerShortcut() async -> [UUID: Date]
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
}
