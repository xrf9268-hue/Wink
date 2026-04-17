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

    @Test
    func recordUsageFollowsLiveTimeZoneChange() async {
        let box = MutableTimeZoneBox(initial: TimeZone(secondsFromGMT: -10 * 3600)!)
        let tracker = UsageTracker(databasePath: ":memory:", timeZoneProvider: { box.current })
        let id = UUID()
        let moment = isoDate("2026-03-21") // 2026-03-21T12:00:00Z

        // GMT-10 → 2026-03-21 02:00 local → bucket "2026-03-21"
        await tracker.recordUsage(shortcutId: id, on: moment)

        // GMT+12 → 2026-03-22 00:00 local → bucket "2026-03-22"
        box.current = TimeZone(secondsFromGMT: 12 * 3600)!
        await tracker.recordUsage(shortcutId: id, on: moment)

        let counts = await tracker.dailyCounts(days: 7, relativeTo: moment)
        let dates = counts[id.uuidString]?.map(\.date).sorted() ?? []
        #expect(dates == ["2026-03-21", "2026-03-22"])
    }

    @Test
    func windowStartStringSnapshotsTimeZoneOncePerQuery() async {
        // Regression for Codex review on PR #163: windowStartString previously
        // read `timeZoneProvider()` once for the Calendar and a second time
        // inside `dateString(for:)`. If the system zone changed between those
        // reads, the cutoff was computed in one zone and formatted in another.
        // With the fix the query path takes exactly one snapshot per call.
        let counter = CountingTimeZoneBox(TimeZone(secondsFromGMT: 0)!)
        let tracker = UsageTracker(databasePath: ":memory:", timeZoneProvider: { counter.provide() })

        await tracker.recordUsage(shortcutId: UUID(), on: isoDate("2026-03-21"))
        counter.reset()

        _ = await tracker.usageCounts(days: 7, relativeTo: isoDate("2026-03-21"))

        #expect(counter.count == 1)
    }

    @Test
    func windowStartStringUsesCurrentTimeZone() async {
        let box = MutableTimeZoneBox(initial: TimeZone(secondsFromGMT: -10 * 3600)!)
        let tracker = UsageTracker(databasePath: ":memory:", timeZoneProvider: { box.current })
        let id = UUID()
        let moment = isoDate("2026-03-21") // 2026-03-21T12:00:00Z

        // Pre-seed the bucket that's "today" in GMT+12 but "yesterday" in GMT-10.
        await tracker.recordUsage(shortcutId: id, on: moment) // GMT-10: "2026-03-21"

        // Switch to GMT+12 where the same moment is "2026-03-22".
        box.current = TimeZone(secondsFromGMT: 12 * 3600)!
        // 1-day window anchored at `moment` in GMT+12 covers only "2026-03-22",
        // which has no records — the GMT-10 entry sits in a different bucket.
        let counts = await tracker.usageCounts(days: 1, relativeTo: moment)
        #expect(counts[id] == nil)
    }
}

private final class CountingTimeZoneBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private let tz: TimeZone

    init(_ tz: TimeZone) { self.tz = tz }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }

    func provide() -> TimeZone {
        lock.lock(); defer { lock.unlock() }
        _count += 1
        return tz
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        _count = 0
    }
}

private final class MutableTimeZoneBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _current: TimeZone

    init(initial: TimeZone) {
        self._current = initial
    }

    var current: TimeZone {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); defer { lock.unlock() }; _current = newValue }
    }
}

private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: "\(value)T12:00:00Z")!
}
