import Foundation
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
        service.save(shortcuts)

        let liveShortcutsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quickey", isDirectory: true)
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
        service.save(shortcuts)

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
}

private final class DiagnosticRecorder: @unchecked Sendable {
    private(set) var messages: [String] = []

    func append(_ message: String) {
        messages.append(message)
    }
}
