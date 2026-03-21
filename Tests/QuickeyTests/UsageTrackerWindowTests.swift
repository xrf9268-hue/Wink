import Foundation
import Testing
@testable import Quickey

@Suite("UsageTracker window boundaries")
struct UsageTrackerWindowTests {
    @Test
    func oneDayWindowIncludesTodayOnly() async {
        let tracker = UsageTracker(databasePath: ":memory:")
        let id = UUID()
        let today = isoDate("2026-03-21")
        let yesterday = isoDate("2026-03-20")

        await tracker.recordUsage(shortcutId: id, on: yesterday)
        await tracker.recordUsage(shortcutId: id, on: today)

        let counts = await tracker.usageCounts(days: 1, relativeTo: today)
        #expect(counts[id] == 1)
    }

    @Test
    func sevenDayWindowExcludesTheEighthDayBack() async {
        let tracker = UsageTracker(databasePath: ":memory:")
        let id = UUID()
        let today = isoDate("2026-03-21")
        let seventhDayBack = isoDate("2026-03-15")
        let eighthDayBack = isoDate("2026-03-14")

        await tracker.recordUsage(shortcutId: id, on: seventhDayBack)
        await tracker.recordUsage(shortcutId: id, on: eighthDayBack)

        let counts = await tracker.usageCounts(days: 7, relativeTo: today)
        #expect(counts[id] == 1)
    }

    @Test
    func thirtyDayWindowExcludesTheThirtyFirstDayBack() async {
        let tracker = UsageTracker(databasePath: ":memory:")
        let id = UUID()
        let today = isoDate("2026-03-21")
        let thirtiethDayBack = isoDate("2026-02-20")
        let thirtyFirstDayBack = isoDate("2026-02-19")

        await tracker.recordUsage(shortcutId: id, on: thirtiethDayBack)
        await tracker.recordUsage(shortcutId: id, on: thirtyFirstDayBack)

        let total = await tracker.totalSwitches(days: 30, relativeTo: today)
        #expect(total == 1)
    }
}

private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: "\(value)T12:00:00Z")!
}
