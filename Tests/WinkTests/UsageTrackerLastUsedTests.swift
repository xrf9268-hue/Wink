import Foundation
import SQLite3
import Testing

@testable import Wink

@Suite("UsageTracker last-used lookup")
struct UsageTrackerLastUsedTests {
    @Test
    func lastUsedReturnsLatestBucketPerShortcut() async throws {
        let tracker = UsageTracker(
            databasePath: ":memory:",
            timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }
        )
        let first = UUID()
        let second = UUID()

        await tracker.recordUsage(shortcutId: first, on: isoDateTime("2026-03-01T08:30:00Z"))
        await tracker.recordUsage(shortcutId: first, on: isoDateTime("2026-03-04T22:10:00Z"))
        await tracker.recordUsage(shortcutId: first, on: isoDateTime("2026-03-04T05:00:00Z"))
        await tracker.recordUsage(shortcutId: second, on: isoDateTime("2026-02-11T13:45:00Z"))

        let lastUsed = await tracker.lastUsedPerShortcut()

        #expect(lastUsed.count == 2)
        #expect(lastUsed[first] == isoDateTime("2026-03-04T22:00:00Z"))
        #expect(lastUsed[second] == isoDateTime("2026-02-11T13:00:00Z"))
    }

    @Test
    func lastUsedBreaksSameDayTiesByLatestHour() async throws {
        let tracker = UsageTracker(
            databasePath: ":memory:",
            timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }
        )
        let shortcut = UUID()

        await tracker.recordUsage(shortcutId: shortcut, on: isoDateTime("2026-03-04T05:00:00Z"))
        await tracker.recordUsage(shortcutId: shortcut, on: isoDateTime("2026-03-04T23:59:00Z"))
        await tracker.recordUsage(shortcutId: shortcut, on: isoDateTime("2026-03-04T12:00:00Z"))

        let lastUsed = await tracker.lastUsedPerShortcut()

        #expect(lastUsed[shortcut] == isoDateTime("2026-03-04T23:00:00Z"))
    }

    @Test
    func lastUsedIsEmptyForEmptyDatabaseAndOmitsNeverUsedShortcuts() async throws {
        let tracker = UsageTracker(
            databasePath: ":memory:",
            timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }
        )

        #expect(await tracker.lastUsedPerShortcut().isEmpty)

        let used = UUID()
        let neverUsed = UUID()
        await tracker.recordUsage(shortcutId: used, on: isoDateTime("2026-01-15T09:00:00Z"))

        let lastUsed = await tracker.lastUsedPerShortcut()
        #expect(lastUsed.count == 1)
        #expect(lastUsed[used] != nil)
        #expect(lastUsed[neverUsed] == nil)
    }

    @Test
    func looseIndexScanMatchesWindowFunctionBaselineOnRandomizedHistory() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("last-used-equivalence-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        try seedRandomizedUsageHourly(at: databaseURL, rowTarget: 2000)

        let baselineSQL = """
            SELECT shortcut_id, date, hour FROM (
                SELECT shortcut_id, date, hour,
                       ROW_NUMBER() OVER (
                           PARTITION BY shortcut_id
                           ORDER BY date DESC, hour DESC
                       ) AS rn
                FROM usage_hourly
            )
            WHERE rn = 1
            """

        let baseline = try queryRows(baselineSQL, at: databaseURL)
        let optimized = try queryRows(UsageTracker.lastUsedPerShortcutSQL, at: databaseURL)

        #expect(!baseline.isEmpty)
        #expect(Set(optimized) == Set(baseline))
    }

    @Test
    func lastUsedQueryPlanAvoidsTemporaryBTree() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("last-used-plan-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        try seedRandomizedUsageHourly(at: databaseURL, rowTarget: 200)

        let planSteps = try queryPlanSteps(UsageTracker.lastUsedPerShortcutSQL, at: databaseURL)

        #expect(!planSteps.isEmpty)
        #expect(planSteps.allSatisfy { !$0.contains("TEMP B-TREE") })
        #expect(planSteps.contains { $0.contains("COVERING INDEX sqlite_autoindex_usage_hourly_1") })
    }

    private func seedRandomizedUsageHourly(at url: URL, rowTarget: Int) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw LastUsedTestError.openFailed
        }
        defer { sqlite3_close(db) }

        guard sqlite3_exec(
            db,
            """
            CREATE TABLE usage_hourly (
                shortcut_id TEXT NOT NULL,
                date        TEXT NOT NULL,
                hour        INTEGER NOT NULL CHECK(hour BETWEEN 0 AND 23),
                count       INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (shortcut_id, date, hour)
            );
            CREATE INDEX idx_usage_hourly_date_hour ON usage_hourly(date, hour);
            BEGIN;
            """,
            nil, nil, nil
        ) == SQLITE_OK else {
            throw LastUsedTestError.execFailed
        }

        let shortcutIDs = (0..<7).map { index in
            "0000000\(index)-1111-4222-8333-444444444444"
        } + ["not-a-uuid-key"]
        var generator = DeterministicGenerator(seed: 0x324)

        var inserted = 0
        while inserted < rowTarget {
            let shortcut = shortcutIDs[Int(generator.next() % UInt64(shortcutIDs.count))]
            let year = 2021 + Int(generator.next() % 6)
            let month = 1 + Int(generator.next() % 12)
            let day = 1 + Int(generator.next() % 28)
            let hour = Int(generator.next() % 24)
            let date = String(format: "%04d-%02d-%02d", year, month, day)
            let sql = """
                INSERT INTO usage_hourly (shortcut_id, date, hour, count)
                VALUES ('\(shortcut)', '\(date)', \(hour), 1)
                ON CONFLICT(shortcut_id, date, hour) DO UPDATE SET count = count + 1
                """
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw LastUsedTestError.execFailed
            }
            inserted += 1
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw LastUsedTestError.execFailed
        }
    }

    private func queryRows(_ sql: String, at url: URL) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw LastUsedTestError.openFailed
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw LastUsedTestError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(stmt, 0),
                let dateText = sqlite3_column_text(stmt, 1)
            else {
                continue
            }
            rows.append(
                "\(String(cString: idText))|\(String(cString: dateText))|\(sqlite3_column_int(stmt, 2))"
            )
        }
        return rows
    }

    private func queryPlanSteps(_ sql: String, at url: URL) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw LastUsedTestError.openFailed
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN \(sql)", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw LastUsedTestError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        var steps: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let detail = sqlite3_column_text(stmt, 3) {
                steps.append(String(cString: detail))
            }
        }
        return steps
    }
}

/// SplitMix64 — deterministic across runs so the equivalence fixture is
/// reproducible without seeding global randomness.
private struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private enum LastUsedTestError: Error {
    case openFailed
    case prepareFailed
    case execFailed
}

private func isoDateTime(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: value)!
}
