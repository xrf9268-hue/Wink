import Foundation
import SQLite3
import Testing
@testable import Wink

@Suite("PersistenceService disk loading")
struct PersistenceServiceDiskLoadingTests {
    @Test
    func sharedHarnessWritesToTemporaryStorage() throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }

        let shortcuts = [
            AppShortcut(
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["command", "shift"]
            ),
        ]

        let service = harness.makePersistenceService()
        try service.save(shortcuts)

        let liveShortcutsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wink", isDirectory: true)
            .appendingPathComponent("shortcuts.json")

        #expect(harness.shortcutsURL != liveShortcutsURL)
        #expect(harness.shortcutsURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(try service.load() == shortcuts)
    }

    @Test
    func roundTripsCurrentSchemaThroughDisk() throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let diagnostics = DiagnosticRecorder()

        let shortcuts = [
            AppShortcut(
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["command", "shift"]
            ),
            AppShortcut(
                appName: "IINA",
                bundleIdentifier: "com.colliderli.iina",
                keyEquivalent: "i",
                modifierFlags: ["command", "option"],
                isEnabled: false
            ),
        ]

        let service = harness.makePersistenceService(
            diagnosticClient: .init(log: { message in
                diagnostics.append(message)
            })
        )
        try service.save(shortcuts)

        let loaded = try service.load()

        #expect(loaded == shortcuts)
        #expect(diagnostics.messages.isEmpty)
    }

    @Test
    func preservesMalformedJSONAndThrows() throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let diagnostics = DiagnosticRecorder()

        let malformed = Data("{ definitely not json".utf8)
        try malformed.write(to: harness.shortcutsURL)

        let service = harness.makePersistenceService(
            diagnosticClient: .init(log: { message in
                diagnostics.append(message)
            }),
            backupIDProvider: { "malformed" }
        )

        #expect(throws: PersistenceService.LoadError.self) {
            try service.load()
        }

        let backupURL = harness.directory.appendingPathComponent("shortcuts.load-failure-malformed.json")
        #expect(try Data(contentsOf: harness.shortcutsURL) == malformed)
        #expect(try Data(contentsOf: backupURL) == malformed)
        #expect(diagnostics.messages.contains {
            $0.contains("path=\(harness.shortcutsURL.path)") && $0.contains("reason=")
        })
    }

    @Test
    func duplicateIDsAreRejectedBeforeLoadReturns() throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let diagnostics = DiagnosticRecorder()
        let invalidPayload = try JSONEncoder().encode(makeDuplicateShortcutIDFixture())
        try invalidPayload.write(to: harness.shortcutsURL)

        let service = harness.makePersistenceService(
            diagnosticClient: .init(log: { message in
                diagnostics.append(message)
            }),
            backupIDProvider: { "duplicate-id" }
        )

        do {
            let shortcuts = try service.load()
            Issue.record("Expected duplicate shortcut IDs to fail loading; loaded \(shortcuts.count) shortcuts")
        } catch let error as PersistenceService.LoadError {
            guard case let .duplicateShortcutID(path, id, preservedCopyPath) = error else {
                Issue.record("Expected duplicateShortcutID, got \(error)")
                return
            }
            #expect(path == harness.shortcutsURL.path)
            #expect(id == duplicateShortcutFixtureID)
            #expect(
                preservedCopyPath
                    == harness.directory
                        .appendingPathComponent("shortcuts.load-failure-duplicate-id.json")
                        .path
            )
        }

        let backupURL = harness.directory.appendingPathComponent("shortcuts.load-failure-duplicate-id.json")
        #expect(try Data(contentsOf: harness.shortcutsURL) == invalidPayload)
        #expect(try Data(contentsOf: backupURL) == invalidPayload)
        #expect(diagnostics.messages.contains {
            $0.contains("path=\(harness.shortcutsURL.path)")
                && $0.contains(duplicateShortcutFixtureID.uuidString)
                && $0.contains("preservedCopyPath=\(backupURL.path)")
        })

        let replacement = [
            AppShortcut(
                appName: "Terminal",
                bundleIdentifier: "com.apple.Terminal",
                keyEquivalent: "t",
                modifierFlags: ["command"]
            ),
        ]
        let replacementPayload = try JSONEncoder().encode(replacement)
        try replacementPayload.write(to: harness.shortcutsURL, options: .atomic)

        #expect(try service.load() == replacement)
        #expect(try Data(contentsOf: backupURL) == invalidPayload)
    }

    @Test
    func duplicateIDsAreRejectedBeforeSaveOverwritesCanonicalPayload() throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let diagnostics = DiagnosticRecorder()
        let service = harness.makePersistenceService(
            diagnosticClient: .init(log: { message in
                diagnostics.append(message)
            })
        )
        let canonical = [
            AppShortcut(
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                keyEquivalent: "s",
                modifierFlags: ["command"]
            ),
        ]
        try service.save(canonical)
        let canonicalPayload = try Data(contentsOf: harness.shortcutsURL)
        let duplicateShortcuts = makeDuplicateShortcutIDFixture()

        do {
            try service.save(duplicateShortcuts)
            Issue.record("Expected duplicate shortcut IDs to fail saving")
        } catch let error as PersistenceService.SaveError {
            guard case let .duplicateShortcutID(path, id) = error else {
                Issue.record("Expected duplicateShortcutID, got \(error)")
                return
            }
            #expect(path == harness.shortcutsURL.path)
            #expect(id == duplicateShortcutFixtureID)
        }

        #expect(try Data(contentsOf: harness.shortcutsURL) == canonicalPayload)
        #expect(try service.load() == canonical)
        #expect(diagnostics.messages.contains {
            $0.contains("path=\(harness.shortcutsURL.path)")
                && $0.contains(duplicateShortcutFixtureID.uuidString)
        })
    }

    @Test
    func rejectsMissingIsEnabledPayloadWithoutSilentMigration() throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let diagnostics = DiagnosticRecorder()

        let legacyPayload = Data(
            """
            [
              {
                "id": "12345678-1234-1234-1234-123456789012",
                "appName": "Safari",
                "bundleIdentifier": "com.apple.Safari",
                "keyEquivalent": "s",
                "modifierFlags": ["command"]
              }
            ]
            """.utf8
        )
        try legacyPayload.write(to: harness.shortcutsURL)

        let service = harness.makePersistenceService(
            diagnosticClient: .init(log: { message in
                diagnostics.append(message)
            }),
            backupIDProvider: { "missing-enabled" }
        )

        #expect(throws: PersistenceService.LoadError.self) {
            try service.load()
        }

        let backupURL = harness.directory.appendingPathComponent("shortcuts.load-failure-missing-enabled.json")
        #expect(try Data(contentsOf: harness.shortcutsURL) == legacyPayload)
        #expect(try Data(contentsOf: backupURL) == legacyPayload)
        #expect(diagnostics.messages.contains {
            $0.contains("path=\(harness.shortcutsURL.path)") && $0.contains("reason=")
        })
    }

    @Test
    func rejectsUnsupportedSchemaPayload() throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let diagnostics = DiagnosticRecorder()

        let unsupportedPayload = Data(
            """
            {
              "schemaVersion": 2,
              "shortcuts": []
            }
            """.utf8
        )
        try unsupportedPayload.write(to: harness.shortcutsURL)

        let service = harness.makePersistenceService(
            diagnosticClient: .init(log: { message in
                diagnostics.append(message)
            }),
            backupIDProvider: { "unsupported-schema" }
        )

        #expect(throws: PersistenceService.LoadError.self) {
            try service.load()
        }

        let backupURL = harness.directory.appendingPathComponent("shortcuts.load-failure-unsupported-schema.json")
        #expect(try Data(contentsOf: harness.shortcutsURL) == unsupportedPayload)
        #expect(try Data(contentsOf: backupURL) == unsupportedPayload)
    }

    @Test
    func saveThrowsWhenStorageIsUnavailable() {
        let diagnostics = DiagnosticRecorder()
        let service = PersistenceService(
            storageURLProvider: { nil },
            diagnosticClient: .init(log: { message in
                diagnostics.append(message)
            })
        )

        #expect(throws: PersistenceService.SaveError.self) {
            try service.save([])
        }
        #expect(diagnostics.messages.contains {
            $0.contains("Failed to save shortcuts")
        })
    }

    @Test
    func saveThrowsWhenDiskWriteFails() throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let diagnostics = DiagnosticRecorder()

        let missingDirectoryURL = harness.directory
            .appendingPathComponent("missing-subdirectory", isDirectory: true)
            .appendingPathComponent("shortcuts.json")
        let service = PersistenceService(
            storageURLProvider: { missingDirectoryURL },
            diagnosticClient: .init(log: { message in
                diagnostics.append(message)
            })
        )

        #expect(throws: PersistenceService.SaveError.self) {
            try service.save([
                AppShortcut(
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    keyEquivalent: "s",
                    modifierFlags: ["command", "shift"]
                ),
            ])
        }
        #expect(diagnostics.messages.contains {
            $0.contains("path=\(missingDirectoryURL.path)") && $0.contains("reason=")
        })
    }
}

private final class DiagnosticRecorder: @unchecked Sendable {
    private(set) var messages: [String] = []

    func append(_ message: String) {
        messages.append(message)
    }
}

@Suite("Usage database bootstrap")
struct UsageDatabaseBootstrapTests {
    @Test
    func usageTrackerWritesHourlyRowsAndIndexToPersistentDatabase() async throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("usage.db")
        let tracker = UsageTracker(
            databasePath: databaseURL.path,
            timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }
        )
        let shortcutID = UUID()
        let timestamp = isoDateTime("2026-04-22T09:15:00Z")

        await tracker.recordUsage(shortcutId: shortcutID, on: timestamp)
        await tracker.recordUsage(shortcutId: shortcutID, on: timestamp)

        let row = try #require(try usageHourlyRows(at: databaseURL).first)
        #expect(row.date == "2026-04-22")
        #expect(row.hour == 9)
        #expect(row.count == 2)
        #expect(try userVersion(at: databaseURL) == UsageDatabaseBootstrap.requiredSchemaVersion)
        #expect(try tableColumns(named: "daily_usage", at: databaseURL) == ["shortcut_id", "date", "count"])
        #expect(try tableColumns(named: "usage_hourly", at: databaseURL) == ["shortcut_id", "date", "hour", "count"])
        #expect(try indexNames(for: "usage_hourly", at: databaseURL).contains("idx_usage_hourly_date_hour"))
    }

    @Test
    func startupBootstrapDeletesLegacyUsageDailySchemaBeforeHourlyBoot() throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let diagnostics = DiagnosticRecorder()
        let databaseURL = harness.directory.appendingPathComponent("usage.db")

        try seedLegacyUsageDatabase(at: databaseURL)

        UsageDatabaseBootstrap.prepareDatabase(
            at: databaseURL.path,
            diagnosticClient: .init(log: { message in
                diagnostics.append(message)
            })
        )

        #expect(FileManager.default.fileExists(atPath: databaseURL.path) == false)
        _ = UsageTracker(databasePath: databaseURL.path)

        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(try tableNames(at: databaseURL).contains("usage_daily") == false)
        #expect(try tableColumns(named: "daily_usage", at: databaseURL) == ["shortcut_id", "date", "count"])
        #expect(try tableColumns(named: "usage_hourly", at: databaseURL) == ["shortcut_id", "date", "hour", "count"])
        #expect(diagnostics.messages.contains {
            $0.contains("Reset usage database for hourly schema migration")
                && $0.contains("oldUserVersion=1")
        })
    }

    @Test
    func recordUsageRollsBackDailyWriteWhenHourlyInsertFails() async throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("usage.db")
        let tracker = UsageTracker(
            databasePath: databaseURL.path,
            timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }
        )
        let shortcutID = UUID()

        try withSQLiteDatabase(at: databaseURL) { db in
            try executeSQL(
                """
                CREATE TRIGGER fail_usage_hourly_insert
                BEFORE INSERT ON usage_hourly
                BEGIN
                    SELECT RAISE(FAIL, 'forced hourly insert failure');
                END;
                """,
                in: db
            )
        }

        await tracker.recordUsage(shortcutId: shortcutID, on: isoDateTime("2026-04-22T09:15:00Z"))

        #expect(try rowCount("SELECT COUNT(*) FROM daily_usage", at: databaseURL) == 0)
        #expect(try rowCount("SELECT COUNT(*) FROM usage_hourly", at: databaseURL) == 0)
    }

    @Test
    func deleteUsageRollsBackDailyDeleteWhenHourlyDeleteFails() async throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }

        let databaseURL = harness.directory.appendingPathComponent("usage.db")
        let tracker = UsageTracker(
            databasePath: databaseURL.path,
            timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }
        )
        let shortcutID = UUID()

        await tracker.recordUsage(shortcutId: shortcutID, on: isoDateTime("2026-04-22T09:15:00Z"))

        try withSQLiteDatabase(at: databaseURL) { db in
            try executeSQL(
                """
                CREATE TRIGGER fail_usage_hourly_delete
                BEFORE DELETE ON usage_hourly
                BEGIN
                    SELECT RAISE(FAIL, 'forced hourly delete failure');
                END;
                """,
                in: db
            )
        }

        await tracker.deleteUsage(shortcutId: shortcutID)

        #expect(
            try rowCount(
                "SELECT COUNT(*) FROM daily_usage WHERE shortcut_id = '\(shortcutID.uuidString)'",
                at: databaseURL
            ) == 1
        )
        #expect(
            try rowCount(
                "SELECT COUNT(*) FROM usage_hourly WHERE shortcut_id = '\(shortcutID.uuidString)'",
                at: databaseURL
            ) == 1
        )
    }
}

@Suite("Usage date key locale migration")
struct UsageDateKeyLocaleMigrationTests {
    private static let arabicKey = "\u{0662}\u{0660}\u{0662}\u{0665}-\u{0660}\u{0661}-\u{0660}\u{0661}"
    private static let persianSameDayKey = "\u{06F2}\u{06F0}\u{06F2}\u{06F5}-\u{06F0}\u{06F1}-\u{06F0}\u{06F1}"
    private static let persianOtherDayKey = "\u{06F2}\u{06F0}\u{06F2}\u{06F5}-\u{06F0}\u{06F1}-\u{06F0}\u{06F2}"
    private static let malformedKey = "\u{0662}\u{0660}\u{0662}\u{0665}-\u{0660}\u{0661}"

    @Test
    func dateKeyFormatterPinsPOSIXLocaleAndEmitsASCIIKeys() {
        let formatter = UsageWindowMath.dateKeyFormatter(timeZone: TimeZone(secondsFromGMT: 0)!)

        #expect(formatter.locale.identifier == "en_US_POSIX")
        #expect(formatter.string(from: isoDateTime("2025-01-01T12:00:00Z")) == "2025-01-01")

        // The bug this pin fixes: an unpinned formatter under an Arabic
        // locale emits localized digits for the same Gregorian date.
        let unpinned = DateFormatter()
        unpinned.locale = Locale(identifier: "ar_SA")
        unpinned.calendar = Calendar(identifier: .gregorian)
        unpinned.dateFormat = "yyyy-MM-dd"
        unpinned.timeZone = TimeZone(secondsFromGMT: 0)
        #expect(unpinned.string(from: isoDateTime("2025-01-01T12:00:00Z")) == Self.arabicKey)
    }

    @Test
    func normalizedASCIIDateKeyTranslatesLocalizedDigitsAndRejectsMalformedKeys() {
        #expect(UsageDatabaseBootstrap.normalizedASCIIDateKey(Self.arabicKey) == "2025-01-01")
        #expect(UsageDatabaseBootstrap.normalizedASCIIDateKey(Self.persianSameDayKey) == "2025-01-01")
        #expect(UsageDatabaseBootstrap.normalizedASCIIDateKey("2025-01-01") == "2025-01-01")
        #expect(UsageDatabaseBootstrap.normalizedASCIIDateKey(Self.malformedKey) == nil)
        #expect(UsageDatabaseBootstrap.normalizedASCIIDateKey("2025-01-0a") == nil)
        #expect(UsageDatabaseBootstrap.normalizedASCIIDateKey("") == nil)
    }

    @Test
    func migrationNormalizesLocalizedKeysInPlaceAndMergesCollisions() throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let diagnostics = DiagnosticRecorder()
        let databaseURL = harness.directory.appendingPathComponent("usage.db")

        try seedLocalizedV2UsageDatabase(at: databaseURL)

        UsageDatabaseBootstrap.prepareDatabase(
            at: databaseURL.path,
            diagnosticClient: .init(log: { diagnostics.append($0) })
        )

        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(try userVersion(at: databaseURL) == UsageDatabaseBootstrap.requiredSchemaVersion)

        // S1 2025-01-01 merges ASCII(3) + Arabic-Indic(2) + Persian(7) = 12.
        #expect(try rowCount("SELECT count FROM daily_usage WHERE shortcut_id = 'S1' AND date = '2025-01-01'", at: databaseURL) == 12)
        // S2 Persian-only key normalizes without collision.
        #expect(try rowCount("SELECT count FROM daily_usage WHERE shortcut_id = 'S2' AND date = '2025-01-02'", at: databaseURL) == 5)
        // Malformed key is preserved untouched rather than guessed at.
        #expect(try rowCount("SELECT count FROM daily_usage WHERE shortcut_id = 'S3' AND date = '\(Self.malformedKey)'", at: databaseURL) == 1)
        // Every other daily key is ASCII now.
        #expect(try rowCount("SELECT COUNT(*) FROM daily_usage WHERE date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'", at: databaseURL) == 2)
        #expect(try rowCount("SELECT COUNT(*) FROM daily_usage", at: databaseURL) == 3)
        // Global daily total is exactly preserved after merging.
        #expect(try rowCount("SELECT SUM(count) FROM daily_usage", at: databaseURL) == 18)

        // Hourly: same-hour collision merges, distinct hour normalizes alongside.
        #expect(try rowCount("SELECT count FROM usage_hourly WHERE shortcut_id = 'S1' AND date = '2025-01-01' AND hour = 9", at: databaseURL) == 5)
        #expect(try rowCount("SELECT count FROM usage_hourly WHERE shortcut_id = 'S1' AND date = '2025-01-01' AND hour = 10", at: databaseURL) == 4)
        #expect(try rowCount("SELECT count FROM usage_hourly WHERE shortcut_id = 'S2' AND date = '2025-01-02' AND hour = 0", at: databaseURL) == 5)
        #expect(try rowCount("SELECT COUNT(*) FROM usage_hourly", at: databaseURL) == 3)
        #expect(try rowCount("SELECT SUM(count) FROM usage_hourly", at: databaseURL) == 14)

        #expect(diagnostics.messages.contains {
            $0.contains("Migrated usage date keys to locale-stable schema v3")
                && $0.contains("dailyKeysNormalized=3")
                && $0.contains("hourlyKeysNormalized=3")
        })
        #expect(diagnostics.messages.allSatisfy { !$0.contains("Reset usage database") })
    }

    @Test
    func migrationIsIdempotentAcrossRepeatedBootstraps() throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let databaseURL = harness.directory.appendingPathComponent("usage.db")

        try seedLocalizedV2UsageDatabase(at: databaseURL)

        for _ in 0..<3 {
            UsageDatabaseBootstrap.prepareDatabase(at: databaseURL.path, diagnosticClient: .init(log: { _ in }))
        }

        #expect(try userVersion(at: databaseURL) == UsageDatabaseBootstrap.requiredSchemaVersion)
        #expect(try rowCount("SELECT SUM(count) FROM daily_usage", at: databaseURL) == 18)
        #expect(try rowCount("SELECT COUNT(*) FROM daily_usage", at: databaseURL) == 3)
        #expect(try rowCount("SELECT SUM(count) FROM usage_hourly", at: databaseURL) == 14)
        #expect(try rowCount("SELECT COUNT(*) FROM usage_hourly", at: databaseURL) == 3)
    }

    @Test
    func failedMigrationRollsBackBothTablesAndKeepsRetryableVersion() throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let diagnostics = DiagnosticRecorder()
        let databaseURL = harness.directory.appendingPathComponent("usage.db")

        try seedLocalizedV2UsageDatabase(at: databaseURL)
        try withSQLiteDatabase(at: databaseURL) { db in
            try executeSQL(
                """
                CREATE TRIGGER fail_usage_hourly_normalization
                BEFORE INSERT ON usage_hourly
                BEGIN
                    SELECT RAISE(FAIL, 'forced hourly normalization failure');
                END;
                """,
                in: db
            )
        }

        UsageDatabaseBootstrap.prepareDatabase(
            at: databaseURL.path,
            diagnosticClient: .init(log: { diagnostics.append($0) })
        )

        // daily_usage was processed first; the hourly failure must roll it back too.
        #expect(try userVersion(at: databaseURL) == UsageDatabaseBootstrap.localeMigratableSchemaVersion)
        #expect(try rowCount("SELECT COUNT(*) FROM daily_usage", at: databaseURL) == 5)
        #expect(try rowCount("SELECT count FROM daily_usage WHERE shortcut_id = 'S1' AND date = '2025-01-01'", at: databaseURL) == 3)
        #expect(try rowCount("SELECT count FROM daily_usage WHERE shortcut_id = 'S1' AND date = '\(Self.arabicKey)'", at: databaseURL) == 2)
        #expect(try rowCount("SELECT COUNT(*) FROM usage_hourly", at: databaseURL) == 4)
        #expect(diagnostics.messages.contains { $0.contains("Failed to migrate usage date keys") })
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))

        // A fresh UsageTracker boot over the failed migration must not stamp
        // the new version and strand the localized rows.
        _ = UsageTracker(databasePath: databaseURL.path)
        #expect(try userVersion(at: databaseURL) == UsageDatabaseBootstrap.localeMigratableSchemaVersion)

        // Removing the fault lets the next bootstrap complete the migration.
        try withSQLiteDatabase(at: databaseURL) { db in
            try executeSQL("DROP TRIGGER fail_usage_hourly_normalization", in: db)
        }
        UsageDatabaseBootstrap.prepareDatabase(at: databaseURL.path, diagnosticClient: .init(log: { _ in }))
        #expect(try userVersion(at: databaseURL) == UsageDatabaseBootstrap.requiredSchemaVersion)
        #expect(try rowCount("SELECT SUM(count) FROM daily_usage", at: databaseURL) == 18)
    }

    @Test
    func trackerBootMigratesLocalizedKeysAndServesMergedQueries() async throws {
        let harness = TestPersistenceHarness()
        defer { harness.cleanup() }
        let databaseURL = harness.directory.appendingPathComponent("usage.db")
        let shortcutID = UUID()

        try seedLocalizedV2UsageDatabase(at: databaseURL, shortcutID: shortcutID.uuidString)

        let tracker = UsageTracker(
            databasePath: databaseURL.path,
            timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }
        )

        let counts = await tracker.usageCounts(days: 7, relativeTo: isoDateTime("2025-01-03T12:00:00Z"))
        #expect(counts[shortcutID] == 12)

        let lastUsed = await tracker.lastUsedPerShortcut()
        #expect(lastUsed[shortcutID] == isoDateTime("2025-01-01T10:00:00Z"))
    }

    private func seedLocalizedV2UsageDatabase(at url: URL, shortcutID: String = "S1") throws {
        try withSQLiteDatabase(at: url) { db in
            try executeSQL(
                """
                CREATE TABLE daily_usage (
                    shortcut_id TEXT NOT NULL,
                    date        TEXT NOT NULL,
                    count       INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (shortcut_id, date)
                );
                CREATE TABLE usage_hourly (
                    shortcut_id TEXT NOT NULL,
                    date        TEXT NOT NULL,
                    hour        INTEGER NOT NULL CHECK(hour BETWEEN 0 AND 23),
                    count       INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (shortcut_id, date, hour)
                );
                CREATE INDEX idx_usage_hourly_date_hour ON usage_hourly(date, hour);
                CREATE INDEX idx_daily_usage_date ON daily_usage(date);
                INSERT INTO daily_usage (shortcut_id, date, count) VALUES
                    ('\(shortcutID)', '2025-01-01', 3),
                    ('\(shortcutID)', '\(Self.arabicKey)', 2),
                    ('\(shortcutID)', '\(Self.persianSameDayKey)', 7),
                    ('S2', '\(Self.persianOtherDayKey)', 5),
                    ('S3', '\(Self.malformedKey)', 1);
                INSERT INTO usage_hourly (shortcut_id, date, hour, count) VALUES
                    ('\(shortcutID)', '2025-01-01', 9, 3),
                    ('\(shortcutID)', '\(Self.arabicKey)', 9, 2),
                    ('\(shortcutID)', '\(Self.persianSameDayKey)', 10, 4),
                    ('S2', '\(Self.persianOtherDayKey)', 0, 5);
                PRAGMA user_version = 2;
                """,
                in: db
            )
        }
    }
}

private func isoDateTime(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: value)!
}

private func userVersion(at url: URL) throws -> Int {
    try withSQLiteDatabase(at: url) { db in
        try integerResult(for: "PRAGMA user_version", in: db)
    }
}

private func rowCount(_ sql: String, at url: URL) throws -> Int {
    try withSQLiteDatabase(at: url) { db in
        try integerResult(for: sql, in: db)
    }
}

private func usageHourlyRows(at url: URL) throws -> [(date: String, hour: Int, count: Int)] {
    try withSQLiteDatabase(at: url) { db in
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(
            db,
            "SELECT date, hour, count FROM usage_hourly ORDER BY date, hour",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw SQLiteTestError.prepareFailed(message: sqliteMessage(from: db))
        }

        var rows: [(date: String, hour: Int, count: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let dateText = sqlite3_column_text(statement, 0) else {
                continue
            }

            rows.append(
                (
                    date: String(cString: dateText),
                    hour: Int(sqlite3_column_int(statement, 1)),
                    count: Int(sqlite3_column_int64(statement, 2))
                )
            )
        }

        return rows
    }
}

private func tableColumns(named tableName: String, at url: URL) throws -> [String] {
    try withSQLiteDatabase(at: url) { db in
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = "PRAGMA table_info(\(tableName))"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteTestError.prepareFailed(message: sqliteMessage(from: db))
        }

        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let columnText = sqlite3_column_text(statement, 1) else {
                continue
            }
            columns.append(String(cString: columnText))
        }
        return columns
    }
}

private func indexNames(for tableName: String, at url: URL) throws -> [String] {
    try withSQLiteDatabase(at: url) { db in
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = "PRAGMA index_list(\(tableName))"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteTestError.prepareFailed(message: sqliteMessage(from: db))
        }

        var indexes: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let indexText = sqlite3_column_text(statement, 1) else {
                continue
            }
            indexes.append(String(cString: indexText))
        }
        return indexes
    }
}

private func tableNames(at url: URL) throws -> [String] {
    try withSQLiteDatabase(at: url) { db in
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(
            db,
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw SQLiteTestError.prepareFailed(message: sqliteMessage(from: db))
        }

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameText = sqlite3_column_text(statement, 0) else {
                continue
            }
            names.append(String(cString: nameText))
        }
        return names
    }
}

private func seedLegacyUsageDatabase(at url: URL) throws {
    try withSQLiteDatabase(at: url) { db in
        try executeSQL(
            """
            CREATE TABLE usage_daily (
                date  TEXT NOT NULL PRIMARY KEY,
                count INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO usage_daily (date, count) VALUES ('2026-04-22', 7);
            PRAGMA user_version = 1;
            """,
            in: db
        )
    }
}

private func integerResult(for sql: String, in db: OpaquePointer?) throws -> Int {
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw SQLiteTestError.prepareFailed(message: sqliteMessage(from: db))
    }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw SQLiteTestError.stepFailed(message: sqliteMessage(from: db))
    }

    return Int(sqlite3_column_int64(statement, 0))
}

private func executeSQL(_ sql: String, in db: OpaquePointer?) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? sqliteMessage(from: db)
        sqlite3_free(errorMessage)
        throw SQLiteTestError.execFailed(message: message)
    }
}

private func withSQLiteDatabase<T>(at url: URL, body: (OpaquePointer?) throws -> T) throws -> T {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
        let message = sqliteMessage(from: db)
        sqlite3_close(db)
        throw SQLiteTestError.openFailed(message: message)
    }

    defer { sqlite3_close(db) }
    return try body(db)
}

private func sqliteMessage(from db: OpaquePointer?) -> String {
    guard let db else {
        return "unknown SQLite error"
    }
    return String(cString: sqlite3_errmsg(db))
}

private enum SQLiteTestError: Error {
    case openFailed(message: String)
    case prepareFailed(message: String)
    case stepFailed(message: String)
    case execFailed(message: String)
}
