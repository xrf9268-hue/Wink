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
        case writeFailed(path: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .storageUnavailable:
                return "Failed to save shortcuts: path unavailable"
            case let .writeFailed(path, reason):
                return "Failed to save shortcuts: path=\(path) reason=\(reason)"
            }
        }
    }

    enum LoadError: Error, LocalizedError, Sendable {
        case storageUnavailable
        case fileReadFailed(path: String, reason: String)
        case decodeFailed(path: String, reason: String, preservedCopyPath: String?)

        var errorDescription: String? {
            switch self {
            case .storageUnavailable:
                return "Failed to load shortcuts: path unavailable"
            case let .fileReadFailed(path, reason):
                return "Failed to load shortcuts: path=\(path) reason=\(reason)"
            case let .decodeFailed(path, reason, preservedCopyPath):
                let backupDescription = preservedCopyPath ?? "none"
                return "Failed to load shortcuts: path=\(path) reason=\(reason) preservedCopyPath=\(backupDescription)"
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

        do {
            return try JSONDecoder().decode([AppShortcut].self, from: data)
        } catch {
            let preservedCopyPath = preserveUnreadablePayload(data, originalURL: url)
            let loadError = LoadError.decodeFailed(
                path: url.path,
                reason: error.localizedDescription,
                preservedCopyPath: preservedCopyPath
            )
            logLoadFailure(loadError)
            throw loadError
        }
    }

    func save(_ shortcuts: [AppShortcut]) throws {
        guard let url = storageURLProvider() else {
            let error = SaveError.storageUnavailable
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

    private func preserveUnreadablePayload(_ data: Data, originalURL: URL) -> String? {
        let backupURL = backupURL(for: originalURL)

        do {
            try data.write(to: backupURL, options: .atomic)
            return backupURL.path
        } catch {
            let message = "Failed to preserve unreadable shortcuts payload: path=\(originalURL.path) backupPath=\(backupURL.path) reason=\(error.localizedDescription)"
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
    static let requiredSchemaVersion = 2

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
        let shouldReset =
            userVersion != requiredSchemaVersion ||
            dailyColumns != ["shortcut_id", "date", "count"] ||
            hourlyColumns != ["shortcut_id", "date", "hour", "count"]

        guard shouldReset else {
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
