import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "PersistenceService")

struct PersistenceService: Sendable {
    struct DiagnosticClient: Sendable {
        let log: @Sendable (String) -> Void

        static let live = DiagnosticClient(log: DiagnosticLog.log)
    }

    enum SaveError: Error, LocalizedError, Sendable {
        case storageUnavailable
        case duplicateShortcutID(path: String, id: UUID)
        case writeFailed(path: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .storageUnavailable:
                return "Failed to save shortcuts: path unavailable"
            case let .duplicateShortcutID(path, id):
                return "Failed to save shortcuts: path=\(path) schema=duplicate-shortcut-id id=\(id.uuidString)"
            case let .writeFailed(path, reason):
                return "Failed to save shortcuts: path=\(path) reason=\(reason)"
            }
        }
    }

    enum LoadError: Error, LocalizedError, Sendable {
        case storageUnavailable
        case fileReadFailed(path: String, reason: String)
        case decodeFailed(path: String, reason: String, preservedCopyPath: String?)
        case duplicateShortcutID(path: String, id: UUID, preservedCopyPath: String?)

        var errorDescription: String? {
            switch self {
            case .storageUnavailable:
                return "Failed to load shortcuts: path unavailable"
            case let .fileReadFailed(path, reason):
                return "Failed to load shortcuts: path=\(path) reason=\(reason)"
            case let .decodeFailed(path, reason, preservedCopyPath):
                let backupDescription = preservedCopyPath ?? "none"
                return "Failed to load shortcuts: path=\(path) reason=\(reason) preservedCopyPath=\(backupDescription)"
            case let .duplicateShortcutID(path, id, preservedCopyPath):
                let backupDescription = preservedCopyPath ?? "none"
                return "Failed to load shortcuts: path=\(path) schema=duplicate-shortcut-id id=\(id.uuidString) preservedCopyPath=\(backupDescription)"
            }
        }
    }

    private let storageURLProvider: @Sendable () -> URL?
    private let diagnosticClient: DiagnosticClient
    private let backupIDProvider: @Sendable () -> String

    init(
        storageURLProvider: @escaping @Sendable () -> URL? = {
            StoragePaths.appSupportDirectory()?.appendingPathComponent("shortcuts.json")
        },
        diagnosticClient: DiagnosticClient = .live,
        backupIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.storageURLProvider = storageURLProvider
        self.diagnosticClient = diagnosticClient
        self.backupIDProvider = backupIDProvider
    }

    func load() throws -> [AppShortcut] {
        guard let url = storageURLProvider() else {
            let error = LoadError.storageUnavailable
            logLoadFailure(error)
            throw error
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let loadError = LoadError.fileReadFailed(
                path: url.path,
                reason: error.localizedDescription
            )
            logLoadFailure(loadError)
            throw loadError
        }

        let shortcuts: [AppShortcut]
        do {
            shortcuts = try JSONDecoder().decode([AppShortcut].self, from: data)
        } catch {
            let preservedCopyPath = preserveRejectedPayload(data, originalURL: url)
            let loadError = LoadError.decodeFailed(
                path: url.path,
                reason: error.localizedDescription,
                preservedCopyPath: preservedCopyPath
            )
            logLoadFailure(loadError)
            throw loadError
        }

        if let duplicateID = firstDuplicateID(in: shortcuts) {
            let preservedCopyPath = preserveRejectedPayload(data, originalURL: url)
            let loadError = LoadError.duplicateShortcutID(
                path: url.path,
                id: duplicateID,
                preservedCopyPath: preservedCopyPath
            )
            logLoadFailure(loadError)
            throw loadError
        }

        return shortcuts
    }

    func save(_ shortcuts: [AppShortcut]) throws {
        guard let url = storageURLProvider() else {
            let error = SaveError.storageUnavailable
            logSaveFailure(error)
            throw error
        }

        if let duplicateID = firstDuplicateID(in: shortcuts) {
            let error = SaveError.duplicateShortcutID(path: url.path, id: duplicateID)
            logSaveFailure(error)
            throw error
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(shortcuts)
            try data.write(to: url, options: .atomic)
        } catch {
            let saveError = SaveError.writeFailed(
                path: url.path,
                reason: error.localizedDescription
            )
            logSaveFailure(saveError)
            throw saveError
        }
    }

    private func logSaveFailure(_ error: SaveError) {
        let message = error.localizedDescription
        logger.error("\(message, privacy: .public)")
        diagnosticClient.log(message)
    }

    private func firstDuplicateID(in shortcuts: [AppShortcut]) -> UUID? {
        var seenIDs = Set<UUID>()
        for shortcut in shortcuts where !seenIDs.insert(shortcut.id).inserted {
            return shortcut.id
        }
        return nil
    }

    private func preserveRejectedPayload(_ data: Data, originalURL: URL) -> String? {
        let backupURL = backupURL(for: originalURL)

        do {
            try data.write(to: backupURL, options: .atomic)
            return backupURL.path
        } catch {
            let message = "Failed to preserve rejected shortcuts payload: path=\(originalURL.path) backupPath=\(backupURL.path) reason=\(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
            diagnosticClient.log(message)
            return nil
        }
    }

    private func backupURL(for originalURL: URL) -> URL {
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let pathExtension = originalURL.pathExtension.isEmpty ? "json" : originalURL.pathExtension
        let backupName = "\(baseName).load-failure-\(backupIDProvider()).\(pathExtension)"

        return originalURL.deletingLastPathComponent().appendingPathComponent(backupName)
    }

    private func logLoadFailure(_ error: LoadError) {
        let message = error.localizedDescription
        logger.error("\(message, privacy: .public)")
        diagnosticClient.log(message)
    }
}

enum UsageDatabaseBootstrap {
    static let requiredSchemaVersion = 3
    /// Hourly schema whose only delta to v3 is that date keys may carry
    /// localized (non-ASCII) digits; migrated in place, never reset.
    static let localeMigratableSchemaVersion = 2

    static func prepareDatabase(
        at path: String,
        diagnosticClient: PersistenceService.DiagnosticClient = .live,
        fileManager: FileManager = .default
    ) {
        guard !path.isEmpty, path != ":memory:" else {
            return
        }

        guard fileManager.fileExists(atPath: path) else {
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = "Failed to inspect usage database before hourly schema bootstrap: path=\(path)"
            logger.error("\(message, privacy: .public)")
            diagnosticClient.log(message)
            if let db {
                sqlite3_close(db)
            }
            return
        }

        defer {
            if let db {
                sqlite3_close(db)
            }
        }

        let userVersion = integerPragma("PRAGMA user_version", in: db) ?? 0
        let dailyColumns = tableColumns(named: "daily_usage", in: db)
        let hourlyColumns = tableColumns(named: "usage_hourly", in: db)
        let columnsMatchHourlySchema =
            dailyColumns == ["shortcut_id", "date", "count"] &&
            hourlyColumns == ["shortcut_id", "date", "hour", "count"]

        if userVersion == requiredSchemaVersion && columnsMatchHourlySchema {
            return
        }

        if userVersion == localeMigratableSchemaVersion && columnsMatchHourlySchema {
            // On failure the transaction rolls back and user_version stays at
            // v2, so the next launch retries instead of losing history.
            migrateDateKeysToASCII(in: db, path: path, diagnosticClient: diagnosticClient)
            return
        }

        sqlite3_close(db)
        db = nil

        do {
            try fileManager.removeItem(atPath: path)
            let message = """
                Reset usage database for hourly schema migration: path=\(path) oldUserVersion=\(userVersion) \
                dailyColumns=\(dailyColumns.joined(separator: ",")) \
                hourlyColumns=\(hourlyColumns.joined(separator: ","))
                """
            logger.error("\(message, privacy: .public)")
            diagnosticClient.log(message)
        } catch {
            let message = "Failed to reset usage database for hourly schema migration: path=\(path) reason=\(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
            diagnosticClient.log(message)
        }
    }

    /// Reads the schema version recorded in the database header.
    static func schemaVersion(in db: OpaquePointer?) -> Int? {
        integerPragma("PRAGMA user_version", in: db)
    }

    /// Maps a persisted date key to canonical ASCII `yyyy-MM-dd`, translating
    /// decimal digits from any numbering system (Arabic-Indic, Eastern
    /// Arabic/Persian, ...). Returns nil when the key does not have the
    /// expected shape, so unrecognizable rows are left untouched rather than
    /// guessed at.
    static func normalizedASCIIDateKey(_ key: String) -> String? {
        var ascii = ""
        for character in key {
            if character == "-" {
                ascii.append("-")
                continue
            }

            guard
                character.unicodeScalars.count == 1,
                let scalar = character.unicodeScalars.first,
                scalar.properties.numericType == .decimal,
                let digit = character.wholeNumberValue,
                (0...9).contains(digit)
            else {
                return nil
            }

            ascii.append(String(digit))
        }

        let shape = ascii.split(separator: "-", omittingEmptySubsequences: false)
        guard shape.count == 3, shape[0].count == 4, shape[1].count == 2, shape[2].count == 2 else {
            return nil
        }

        return ascii
    }

    private static func migrateDateKeysToASCII(
        in db: OpaquePointer?,
        path: String,
        diagnosticClient: PersistenceService.DiagnosticClient
    ) {
        guard executeSQL("BEGIN IMMEDIATE", in: db) else {
            logMigrationFailure(path: path, reason: "begin failed: \(errorMessage(in: db))", diagnosticClient: diagnosticClient)
            return
        }

        var normalizedKeyCounts: [String: Int] = [:]
        let tables: [(name: String, mergeSQL: String)] = [
            (
                name: "daily_usage",
                mergeSQL: """
                    INSERT INTO daily_usage (shortcut_id, date, count)
                    SELECT shortcut_id, ?1, count FROM daily_usage WHERE date = ?2
                    ON CONFLICT(shortcut_id, date) DO UPDATE SET count = count + excluded.count
                    """
            ),
            (
                name: "usage_hourly",
                mergeSQL: """
                    INSERT INTO usage_hourly (shortcut_id, date, hour, count)
                    SELECT shortcut_id, ?1, hour, count FROM usage_hourly WHERE date = ?2
                    ON CONFLICT(shortcut_id, date, hour) DO UPDATE SET count = count + excluded.count
                    """
            ),
        ]

        for table in tables {
            // A failed key scan must abort the migration: treating it as an
            // empty table would commit and stamp v3 with localized rows still
            // unread, which this migration exists to prevent.
            guard let dateKeys = stringColumnValues("SELECT DISTINCT date FROM \(table.name)", in: db) else {
                let reason = "reading \(table.name) date keys failed: \(errorMessage(in: db))"
                _ = executeSQL("ROLLBACK", in: db)
                logMigrationFailure(path: path, reason: reason, diagnosticClient: diagnosticClient)
                return
            }

            for key in dateKeys {
                guard let normalized = normalizedASCIIDateKey(key), normalized != key else {
                    continue
                }

                guard
                    executeUpdate(table.mergeSQL, bindings: [normalized, key], in: db),
                    executeUpdate("DELETE FROM \(table.name) WHERE date = ?1", bindings: [key], in: db)
                else {
                    // Capture the failure before ROLLBACK: a successful
                    // rollback resets sqlite3_errmsg to "not an error".
                    let reason = "normalizing \(table.name) key failed: \(errorMessage(in: db))"
                    _ = executeSQL("ROLLBACK", in: db)
                    logMigrationFailure(path: path, reason: reason, diagnosticClient: diagnosticClient)
                    return
                }

                normalizedKeyCounts[table.name, default: 0] += 1
            }
        }

        guard
            executeSQL("PRAGMA user_version = \(requiredSchemaVersion)", in: db),
            executeSQL("COMMIT", in: db)
        else {
            let reason = "commit failed: \(errorMessage(in: db))"
            _ = executeSQL("ROLLBACK", in: db)
            logMigrationFailure(path: path, reason: reason, diagnosticClient: diagnosticClient)
            return
        }

        let message = """
            Migrated usage date keys to locale-stable schema v\(requiredSchemaVersion): path=\(path) \
            dailyKeysNormalized=\(normalizedKeyCounts["daily_usage", default: 0]) \
            hourlyKeysNormalized=\(normalizedKeyCounts["usage_hourly", default: 0])
            """
        logger.info("\(message, privacy: .public)")
        diagnosticClient.log(message)
    }

    private static func logMigrationFailure(
        path: String,
        reason: String,
        diagnosticClient: PersistenceService.DiagnosticClient
    ) {
        let message = "Failed to migrate usage date keys to locale-stable schema: path=\(path) reason=\(reason)"
        logger.error("\(message, privacy: .public)")
        diagnosticClient.log(message)
    }

    private static func errorMessage(in db: OpaquePointer?) -> String {
        guard let db else {
            return "unknown"
        }
        return String(cString: sqlite3_errmsg(db))
    }

    private static func executeSQL(_ sql: String, in db: OpaquePointer?) -> Bool {
        guard let db else {
            return false
        }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func executeUpdate(_ sql: String, bindings: [String], in db: OpaquePointer?) -> Bool {
        guard let db else {
            return false
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return false
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(index + 1), (value as NSString).utf8String, -1, transient) == SQLITE_OK else {
                return false
            }
        }

        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Returns nil on any prepare or step error so callers can distinguish
    /// "no rows" from a scan that ended early (corruption, I/O error).
    private static func stringColumnValues(_ sql: String, in db: OpaquePointer?) -> [String]? {
        guard let db else {
            return nil
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var values: [String] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(stmt, 0) {
                    values.append(String(cString: text))
                }
            case SQLITE_DONE:
                return values
            default:
                return nil
            }
        }
    }

    private static func integerPragma(_ sql: String, in db: OpaquePointer?) -> Int? {
        guard let db else { return nil }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func tableColumns(named tableName: String, in db: OpaquePointer?) -> [String] {
        guard let db else { return [] }

        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(tableName))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var columns: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let columnName = sqlite3_column_text(stmt, 1) else {
                continue
            }
            columns.append(String(cString: columnName))
        }

        return columns
    }
}
