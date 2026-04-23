import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "UsageTracker")

actor UsageTracker: UsageTracking {
    private nonisolated(unsafe) let db: OpaquePointer?
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let timeZoneProvider: @Sendable () -> TimeZone
    private var dateFormatter: DateFormatter
    private var dateFormatterTimeZoneIdentifier: String

    private nonisolated(unsafe) var recordDailyUsageStmt: OpaquePointer?
    private nonisolated(unsafe) var recordHourlyUsageStmt: OpaquePointer?
    private nonisolated(unsafe) var deleteDailyUsageStmt: OpaquePointer?
    private nonisolated(unsafe) var deleteHourlyUsageStmt: OpaquePointer?
    private nonisolated(unsafe) var usageCountsStmt: OpaquePointer?
    private nonisolated(unsafe) var dailyCountsStmt: OpaquePointer?
    private nonisolated(unsafe) var totalSwitchesStmt: OpaquePointer?
    private nonisolated(unsafe) var hourlyCountsStmt: OpaquePointer?
    private nonisolated(unsafe) var previousPeriodTotalStmt: OpaquePointer?
    private nonisolated(unsafe) var streakDaysStmt: OpaquePointer?

    init(
        timeZoneProvider: @escaping @Sendable () -> TimeZone = { TimeZone.current }
    ) {
        self.timeZoneProvider = timeZoneProvider
        let tz = timeZoneProvider()
        (self.dateFormatter, self.dateFormatterTimeZoneIdentifier) = Self.makeDateFormatter(for: tz)
        db = Self.prepareDatabase(path: Self.defaultDatabasePath())
    }

    init(
        databasePath: String,
        timeZoneProvider: @escaping @Sendable () -> TimeZone = { TimeZone.current }
    ) {
        self.timeZoneProvider = timeZoneProvider
        let tz = timeZoneProvider()
        (self.dateFormatter, self.dateFormatterTimeZoneIdentifier) = Self.makeDateFormatter(for: tz)
        db = Self.prepareDatabase(path: databasePath)
    }

    deinit {
        for stmt in [
            recordDailyUsageStmt,
            recordHourlyUsageStmt,
            deleteDailyUsageStmt,
            deleteHourlyUsageStmt,
            usageCountsStmt,
            dailyCountsStmt,
            totalSwitchesStmt,
            hourlyCountsStmt,
            previousPeriodTotalStmt,
            streakDaysStmt,
        ] {
            sqlite3_finalize(stmt)
        }

        if let db {
            sqlite3_close(db)
        }
    }

    func recordUsage(shortcutId: UUID) {
        recordUsage(shortcutId: shortcutId, on: Date())
    }

    func recordUsage(shortcutId: UUID, on date: Date) {
        guard let db else {
            return
        }

        let tz = timeZoneProvider()
        let bucket = bucketComponents(for: date, in: tz)
        let shortcutID = shortcutId.uuidString

        let dailySQL = """
            INSERT INTO daily_usage (shortcut_id, date, count)
            VALUES (?, ?, 1)
            ON CONFLICT(shortcut_id, date) DO UPDATE SET count = count + 1
            """
        guard let dailyStmt = cachedStatement(&recordDailyUsageStmt, sql: dailySQL) else {
            return
        }

        let hourlySQL = """
            INSERT INTO usage_hourly (shortcut_id, date, hour, count)
            VALUES (?, ?, ?, 1)
            ON CONFLICT(shortcut_id, date, hour) DO UPDATE SET count = count + 1
            """
        guard let hourlyStmt = cachedStatement(&recordHourlyUsageStmt, sql: hourlySQL) else {
            return
        }

        performTransaction(named: "record usage", in: db) {
            sqlite3_bind_text(dailyStmt, 1, (shortcutID as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(dailyStmt, 2, (bucket.date as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)

            guard sqlite3_step(dailyStmt) == SQLITE_DONE else {
                let message = "Failed to record daily usage: \(String(cString: sqlite3_errmsg(db)))"
                logger.error("\(message, privacy: .public)")
                DiagnosticLog.log(message)
                return false
            }

            sqlite3_bind_text(hourlyStmt, 1, (shortcutID as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(hourlyStmt, 2, (bucket.date as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int(hourlyStmt, 3, Int32(bucket.hour))

            guard sqlite3_step(hourlyStmt) == SQLITE_DONE else {
                let message = "Failed to record hourly usage: \(String(cString: sqlite3_errmsg(db)))"
                logger.error("\(message, privacy: .public)")
                DiagnosticLog.log(message)
                return false
            }

            return true
        }
    }

    func deleteUsage(shortcutId: UUID) {
        guard let db else {
            return
        }

        let shortcutID = shortcutId.uuidString
        let dailySQL = "DELETE FROM daily_usage WHERE shortcut_id = ?"
        guard let dailyStmt = cachedStatement(&deleteDailyUsageStmt, sql: dailySQL) else {
            return
        }

        let hourlySQL = "DELETE FROM usage_hourly WHERE shortcut_id = ?"
        guard let hourlyStmt = cachedStatement(&deleteHourlyUsageStmt, sql: hourlySQL) else {
            return
        }

        performTransaction(named: "delete usage", in: db) {
            sqlite3_bind_text(dailyStmt, 1, (shortcutID as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
            guard sqlite3_step(dailyStmt) == SQLITE_DONE else {
                let message = "Failed to delete daily usage: \(String(cString: sqlite3_errmsg(db)))"
                logger.error("\(message, privacy: .public)")
                DiagnosticLog.log(message)
                return false
            }

            sqlite3_bind_text(hourlyStmt, 1, (shortcutID as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
            guard sqlite3_step(hourlyStmt) == SQLITE_DONE else {
                let message = "Failed to delete hourly usage: \(String(cString: sqlite3_errmsg(db)))"
                logger.error("\(message, privacy: .public)")
                DiagnosticLog.log(message)
                return false
            }

            return true
        }
    }

    func usageCounts(days: Int) async -> [UUID: Int] {
        await usageCounts(days: days, relativeTo: Date())
    }

    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] {
        let sql = """
            SELECT shortcut_id, SUM(count)
            FROM daily_usage
            WHERE date >= ? AND date <= ?
            GROUP BY shortcut_id
            """
        guard let stmt = cachedStatement(&usageCountsStmt, sql: sql) else {
            return [:]
        }

        let tz = timeZoneProvider()
        let range = windowDateRange(days: days, relativeTo: now, in: tz)
        sqlite3_bind_text(stmt, 1, (range.start as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (range.end as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)

        var result: [UUID: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(stmt, 0),
                let id = UUID(uuidString: String(cString: idPtr))
            else {
                continue
            }

            result[id] = Int(sqlite3_column_int64(stmt, 1))
        }

        return result
    }

    func dailyCounts(days: Int) async -> [String: [(date: String, count: Int)]] {
        await dailyCounts(days: days, relativeTo: Date())
    }

    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] {
        let sql = """
            SELECT shortcut_id, date, count
            FROM daily_usage
            WHERE date >= ? AND date <= ?
            ORDER BY date
            """
        guard let stmt = cachedStatement(&dailyCountsStmt, sql: sql) else {
            return [:]
        }

        let tz = timeZoneProvider()
        let range = windowDateRange(days: days, relativeTo: now, in: tz)
        sqlite3_bind_text(stmt, 1, (range.start as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (range.end as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)

        var result: [String: [(date: String, count: Int)]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idPtr = sqlite3_column_text(stmt, 0),
                let datePtr = sqlite3_column_text(stmt, 1)
            else {
                continue
            }

            let id = String(cString: idPtr)
            let date = String(cString: datePtr)
            let count = Int(sqlite3_column_int64(stmt, 2))
            result[id, default: []].append((date: date, count: count))
        }

        return result
    }

    func totalSwitches(days: Int) async -> Int {
        await totalSwitches(days: days, relativeTo: Date())
    }

    func totalSwitches(days: Int, relativeTo now: Date) async -> Int {
        let sql = """
            SELECT COALESCE(SUM(count), 0)
            FROM usage_hourly
            WHERE date >= ? AND date <= ?
            """
        guard let stmt = cachedStatement(&totalSwitchesStmt, sql: sql) else {
            return 0
        }

        let tz = timeZoneProvider()
        let range = windowDateRange(days: days, relativeTo: now, in: tz)
        sqlite3_bind_text(stmt, 1, (range.start as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (range.end as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int64(stmt, 0))
    }

    func hourlyCounts(days: Int) async -> [HourlyUsageBucket] {
        await hourlyCounts(days: days, relativeTo: Date())
    }

    func hourlyCounts(days: Int, relativeTo now: Date) async -> [HourlyUsageBucket] {
        let sql = """
            SELECT date, hour, COALESCE(SUM(count), 0)
            FROM usage_hourly
            WHERE date >= ? AND date <= ?
            GROUP BY date, hour
            ORDER BY date, hour
            """
        guard let stmt = cachedStatement(&hourlyCountsStmt, sql: sql) else {
            return []
        }

        let tz = timeZoneProvider()
        let range = windowDateRange(days: days, relativeTo: now, in: tz)
        sqlite3_bind_text(stmt, 1, (range.start as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (range.end as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)

        var mappedCounts: [String: [Int: Int]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let datePtr = sqlite3_column_text(stmt, 0)
            else {
                continue
            }

            let date = String(cString: datePtr)
            let hour = Int(sqlite3_column_int(stmt, 1))
            let count = Int(sqlite3_column_int64(stmt, 2))
            mappedCounts[date, default: [:]][hour] = count
        }

        return range.dateKeys.flatMap { dateKey in
            (0..<24).map { hour in
                HourlyUsageBucket(
                    date: dateKey,
                    hour: hour,
                    count: mappedCounts[dateKey]?[hour] ?? 0
                )
            }
        }
    }

    func previousPeriodTotal(days: Int) async -> Int {
        await previousPeriodTotal(days: days, relativeTo: Date())
    }

    func previousPeriodTotal(days: Int, relativeTo now: Date) async -> Int {
        let sql = """
            SELECT COALESCE(SUM(count), 0)
            FROM usage_hourly
            WHERE date >= ? AND date <= ?
            """
        guard let stmt = cachedStatement(&previousPeriodTotalStmt, sql: sql) else {
            return 0
        }

        let tz = timeZoneProvider()
        let previousRange = previousWindowDateRange(days: days, relativeTo: now, in: tz)
        sqlite3_bind_text(stmt, 1, (previousRange.start as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (previousRange.end as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int64(stmt, 0))
    }

    func streakDays(relativeTo now: Date) async -> Int {
        let sql = """
            SELECT DISTINCT date
            FROM daily_usage
            ORDER BY date DESC
            """
        guard let stmt = cachedStatement(&streakDaysStmt, sql: sql) else {
            return 0
        }

        let tz = timeZoneProvider()
        let calendar = UsageWindowMath.calendar(timeZone: tz)
        var expectedDate = calendar.startOfDay(for: now)
        var streak = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let datePtr = sqlite3_column_text(stmt, 0) else {
                continue
            }

            let activeDate = String(cString: datePtr)
            guard activeDate == dateString(for: expectedDate, in: tz) else {
                break
            }

            streak += 1
            expectedDate = calendar.date(byAdding: .day, value: -1, to: expectedDate) ?? expectedDate
        }

        return streak
    }

    func usageTimeZone() async -> TimeZone {
        timeZoneProvider()
    }

    private static func defaultDatabasePath() -> String {
        guard let directory = StoragePaths.appSupportDirectory() else {
            return ":memory:"
        }

        return directory.appendingPathComponent("usage.db").path
    }

    private static func prepareDatabase(path: String) -> OpaquePointer? {
        UsageDatabaseBootstrap.prepareDatabase(at: path)
        guard let db = openDatabase(path: path) else {
            return nil
        }

        createTables(db: db)
        return db
    }

    private static func openDatabase(path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open(path, &db) != SQLITE_OK {
            logger.error("Failed to open usage database at \(path, privacy: .public)")
            DiagnosticLog.log("Failed to open usage database at \(path)")
            if let db {
                sqlite3_close(db)
            }
            return nil
        }

        return db
    }

    private static func createTables(db: OpaquePointer) {
        let sql = """
            CREATE TABLE IF NOT EXISTS daily_usage (
                shortcut_id TEXT NOT NULL,
                date        TEXT NOT NULL,
                count       INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (shortcut_id, date)
            );
            CREATE TABLE IF NOT EXISTS usage_hourly (
                shortcut_id TEXT NOT NULL,
                date        TEXT NOT NULL,
                hour        INTEGER NOT NULL CHECK(hour BETWEEN 0 AND 23),
                count       INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (shortcut_id, date, hour)
            );
            CREATE INDEX IF NOT EXISTS idx_usage_hourly_date_hour
                ON usage_hourly(date, hour);
            PRAGMA user_version = \(UsageDatabaseBootstrap.requiredSchemaVersion);
            """

        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let error = errorMessage.map { String(cString: $0) } ?? "unknown"
            logger.error("Failed to create usage tables: \(error, privacy: .public)")
            DiagnosticLog.log("Failed to create usage tables: \(error)")
            sqlite3_free(errorMessage)
            return
        }
    }

    private func cachedStatement(_ slot: inout OpaquePointer?, sql: String) -> OpaquePointer? {
        if let stmt = slot {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            return stmt
        }

        guard let db else {
            return nil
        }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let message = "SQL prepare failed: \(String(cString: sqlite3_errmsg(db)))"
            logger.error("\(message, privacy: .public)")
            DiagnosticLog.log(message)
            return nil
        }

        slot = stmt
        return stmt
    }

    private func performTransaction(
        named name: String,
        in db: OpaquePointer,
        operation: () -> Bool
    ) {
        guard execute(sql: "BEGIN IMMEDIATE", in: db, failurePrefix: "Failed to begin \(name) transaction") else {
            return
        }

        guard operation() else {
            _ = execute(sql: "ROLLBACK", in: db, failurePrefix: "Failed to roll back \(name) transaction")
            return
        }

        guard execute(sql: "COMMIT", in: db, failurePrefix: "Failed to commit \(name) transaction") else {
            _ = execute(sql: "ROLLBACK", in: db, failurePrefix: "Failed to roll back \(name) transaction after commit error")
            return
        }
    }

    private func execute(sql: String, in db: OpaquePointer, failurePrefix: String) -> Bool {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let messageBody = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            let message = "\(failurePrefix): \(messageBody)"
            logger.error("\(message, privacy: .public)")
            DiagnosticLog.log(message)
            sqlite3_free(errorMessage)
            return false
        }

        sqlite3_free(errorMessage)
        return true
    }

    private func windowDateRange(days: Int, relativeTo now: Date, in tz: TimeZone) -> (start: String, end: String, dateKeys: [String]) {
        let window = UsageWindowMath.windowDates(days: days, relativeTo: now, in: tz)
        let dateKeys = window.days.map { dateString(for: $0, in: tz) }

        return (
            start: dateString(for: window.start, in: tz),
            end: dateString(for: window.end, in: tz),
            dateKeys: dateKeys
        )
    }

    private func previousWindowDateRange(days: Int, relativeTo now: Date, in tz: TimeZone) -> (start: String, end: String, dateKeys: [String]) {
        let previousReference = UsageWindowMath.previousWindowReference(days: days, relativeTo: now, in: tz)
        return windowDateRange(days: days, relativeTo: previousReference, in: tz)
    }

    private func bucketComponents(for date: Date, in tz: TimeZone) -> (date: String, hour: Int) {
        let dateKey = dateString(for: date, in: tz)
        let hour = UsageWindowMath.calendar(timeZone: tz).component(.hour, from: date)
        return (date: dateKey, hour: hour)
    }

    private func dateString(for date: Date, in tz: TimeZone) -> String {
        if tz.identifier != dateFormatterTimeZoneIdentifier {
            (dateFormatter, dateFormatterTimeZoneIdentifier) = Self.makeDateFormatter(for: tz)
        }

        return dateFormatter.string(from: date)
    }

    private static func makeDateFormatter(for timeZone: TimeZone) -> (DateFormatter, String) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        return (formatter, timeZone.identifier)
    }
}
