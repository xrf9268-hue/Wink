import Foundation
import SQLite3
import Testing
@testable import Wink

@Suite("Insights KPI")
struct InsightsKpiSectionTests {
    @Test
    func deltaToneMatchesPositiveNegativeAndNeutralChanges() {
        #expect(InsightsChange.make(current: 12, previous: 10) == InsightsChange(text: "+20%", tone: .positive))
        #expect(InsightsChange.make(current: 8, previous: 10) == InsightsChange(text: "-20%", tone: .negative))
        #expect(InsightsChange.make(current: 10, previous: 10) == InsightsChange(text: "0%", tone: .neutral))
        #expect(InsightsChange.make(current: 4, previous: 0) == InsightsChange(text: "New activity", tone: .positive))
        #expect(InsightsChange.make(current: 0, previous: 0) == InsightsChange(text: "No change", tone: .neutral))
    }

    @Test
    func timeSavedFormatterRollsUpAcrossSecondsMinutesAndHours() {
        #expect(InsightsKpiFormatter.timeSavedText(totalActivations: 12) == "36s")
        #expect(InsightsKpiFormatter.timeSavedText(totalActivations: 20) == "1m")
        #expect(InsightsKpiFormatter.timeSavedText(totalActivations: 61) == "3m")
        #expect(InsightsKpiFormatter.timeSavedText(totalActivations: 1_200) == "1h")
        #expect(InsightsKpiFormatter.timeSavedText(totalActivations: 10_000) == "8h 20m")
    }

    @Test
    func activationSubtitleReadsNaturallyAcrossSpecialCases() {
        #expect(
            InsightsKpiFormatter.activationSubtitle(change: InsightsChange(text: "+20%", tone: .positive))
                == "+20% versus the previous period."
        )
        #expect(
            InsightsKpiFormatter.activationSubtitle(change: InsightsChange(text: "New activity", tone: .positive))
                == "New activity versus the previous period."
        )
        #expect(
            InsightsKpiFormatter.activationSubtitle(change: InsightsChange(text: "No change", tone: .neutral))
                == "No change versus the previous period."
        )
    }

    @Test
    func streakCountsOnlyConsecutiveActiveDaysEndingToday() async throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let databaseURL = harness.directory.appendingPathComponent("usage.db")
        let tracker = UsageTracker(
            databasePath: databaseURL.path,
            timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }
        )
        let shortcutID = UUID()
        let reference = isoDate("2026-04-22")

        await tracker.recordUsage(shortcutId: shortcutID, on: isoDate("2026-04-22"))
        await tracker.recordUsage(shortcutId: shortcutID, on: isoDate("2026-04-21"))
        await tracker.recordUsage(shortcutId: shortcutID, on: isoDate("2026-04-20"))
        await tracker.recordUsage(shortcutId: shortcutID, on: isoDate("2026-04-18"))

        let dailyCounts = await tracker.dailyCounts(days: 7, relativeTo: reference)
        let rawDates = try distinctUsageDates(at: databaseURL)
        #expect(dailyCounts[shortcutID.uuidString]?.map(\.date) == ["2026-04-18", "2026-04-20", "2026-04-21", "2026-04-22"])
        #expect(rawDates == ["2026-04-22", "2026-04-21", "2026-04-20", "2026-04-18"])
        let streak = await tracker.streakDays(relativeTo: reference)
        #expect(streak == 3)
    }

    @Test
    func streakResetsToZeroWhenTodayHasNoActivity() async {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let tracker = UsageTracker(
            databasePath: harness.directory.appendingPathComponent("usage.db").path,
            timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }
        )
        let shortcutID = UUID()
        let reference = isoDate("2026-04-22")

        await tracker.recordUsage(shortcutId: shortcutID, on: isoDate("2026-04-21"))
        await tracker.recordUsage(shortcutId: shortcutID, on: isoDate("2026-04-20"))

        let streak = await tracker.streakDays(relativeTo: reference)
        #expect(streak == 0)
    }
}

private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: "\(value)T12:00:00Z")!
}

private func distinctUsageDates(at url: URL) throws -> [String] {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
        throw SQLiteDebugError.openFailed
    }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    guard sqlite3_prepare_v2(
        db,
        "SELECT DISTINCT date FROM daily_usage ORDER BY date DESC",
        -1,
        &statement,
        nil
    ) == SQLITE_OK else {
        throw SQLiteDebugError.prepareFailed
    }

    var dates: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        guard let dateText = sqlite3_column_text(statement, 0) else {
            continue
        }
        dates.append(String(cString: dateText))
    }
    return dates
}

private enum SQLiteDebugError: Error {
    case openFailed
    case prepareFailed
}
