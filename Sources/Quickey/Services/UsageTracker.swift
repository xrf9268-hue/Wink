import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "UsageTracker")

actor UsageTracker {
    // Safety: db is only accessed from actor-isolated methods and deinit.
    // nonisolated(unsafe) is required because OpaquePointer is not Sendable,
    // but the actor serializes all access. Do not add nonisolated methods that touch db.
    private nonisolated(unsafe) let db: OpaquePointer?

    /// Destructor constant that tells SQLite to copy bound text immediately,
    /// preventing use-after-free when the source NSString buffer is deallocated.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    init() {
        db = Self.openDatabase(path: Self.defaultDatabasePath())
        if let db {
            Self.createTable(db: db)
        }
    }

    init(databasePath: String) {
        db = Self.openDatabase(path: databasePath)
        if let db {
            Self.createTable(db: db)
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Write

    func recordUsage(shortcutId: UUID) {
        let sql = """
            INSERT INTO daily_usage (shortcut_id, date, count)
            VALUES (?, ?, 1)
            ON CONFLICT(shortcut_id, date) DO UPDATE SET count = count + 1
            """
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }

        let idString = shortcutId.uuidString
        sqlite3_bind_text(stmt, 1, (idString as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (todayString() as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let errMsg = String(cString: sqlite3_errmsg(self.db!))
            logger.error("Failed to record usage: \(errMsg)")
            DiagnosticLog.log("Failed to record usage: \(errMsg)")
        }
    }

    func deleteUsage(shortcutId: UUID) {
        let sql = "DELETE FROM daily_usage WHERE shortcut_id = ?"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }

        let idString = shortcutId.uuidString
        sqlite3_bind_text(stmt, 1, (idString as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let errMsg = String(cString: sqlite3_errmsg(self.db!))
            logger.error("Failed to delete usage: \(errMsg)")
            DiagnosticLog.log("Failed to delete usage: \(errMsg)")
        }
    }

    // MARK: - Read

    func usageCounts(days: Int) -> [UUID: Int] {
        let sql = "SELECT shortcut_id, SUM(count) FROM daily_usage WHERE date >= ? GROUP BY shortcut_id"
        guard let stmt = prepare(sql) else { return [:] }
        defer { sqlite3_finalize(stmt) }

        let cutoff = dateString(daysAgo: days)
        sqlite3_bind_text(stmt, 1, (cutoff as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)

        var result: [UUID: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idPtr)) else { continue }
            let count = Int(sqlite3_column_int64(stmt, 1))
            result[id] = count
        }
        return result
    }

    func dailyCounts(days: Int) -> [String: [(date: String, count: Int)]] {
        let sql = "SELECT shortcut_id, date, count FROM daily_usage WHERE date >= ? ORDER BY date"
        guard let stmt = prepare(sql) else { return [:] }
        defer { sqlite3_finalize(stmt) }

        let cutoff = dateString(daysAgo: days)
        sqlite3_bind_text(stmt, 1, (cutoff as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)

        var result: [String: [(date: String, count: Int)]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0),
                  let datePtr = sqlite3_column_text(stmt, 1) else { continue }
            let id = String(cString: idPtr)
            let date = String(cString: datePtr)
            let count = Int(sqlite3_column_int64(stmt, 2))
            result[id, default: []].append((date: date, count: count))
        }
        return result
    }

    func totalSwitches(days: Int) -> Int {
        let sql = "SELECT COALESCE(SUM(count), 0) FROM daily_usage WHERE date >= ?"
        guard let stmt = prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }

        let cutoff = dateString(daysAgo: days)
        sqlite3_bind_text(stmt, 1, (cutoff as NSString).utf8String, -1, Self.SQLITE_TRANSIENT)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    // MARK: - Database setup

    private static func defaultDatabasePath() -> String {
        guard let directory = StoragePaths.appSupportDirectory() else {
            return ":memory:"
        }
        return directory.appendingPathComponent("usage.db").path
    }

    private static func openDatabase(path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open(path, &db) != SQLITE_OK {
            logger.error("Failed to open database at \(path)")
            DiagnosticLog.log("Failed to open database at \(path)")
            return nil
        }
        return db
    }

    private static func createTable(db: OpaquePointer) {
        let sql = """
            CREATE TABLE IF NOT EXISTS daily_usage (
                shortcut_id TEXT NOT NULL,
                date        TEXT NOT NULL,
                count       INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (shortcut_id, date)
            )
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("SQL prepare failed for CREATE TABLE")
            DiagnosticLog.log("SQL prepare failed for CREATE TABLE")
            return
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) != SQLITE_DONE {
            let errMsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to create table: \(errMsg)")
            DiagnosticLog.log("Failed to create table: \(errMsg)")
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let errMsg = String(cString: sqlite3_errmsg(db))
            logger.error("SQL prepare failed: \(errMsg)")
            DiagnosticLog.log("SQL prepare failed: \(errMsg)")
            return nil
        }
        return stmt
    }

    // MARK: - Date helpers

    private func todayString() -> String {
        dateString(daysAgo: 0)
    }

    private func dateString(daysAgo days: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return Self.dateFormatter.string(from: date)
    }
}
