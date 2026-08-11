import Foundation
import Testing
@testable import Wink

@Suite("Diagnostics package")
struct DiagnosticsPackageTests {
    private func builder() -> DiagnosticsPackageBuilder {
        DiagnosticsPackageBuilder(
            redactor: DiagnosticsRedactor(homeDirectoryPath: "/Users/alice", userName: "alice"),
            generatedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    private func environment() -> DiagnosticsPackageBuilder.Environment {
        .init(
            appVersion: "0.8.0",
            buildNumber: "800",
            commitSHA: "abc1234",
            osVersion: "15.5",
            architecture: "arm64",
            signingMode: "Ad-hoc",
            isNotarized: false
        )
    }

    private func runtime(
        secureInput: Bool = false,
        failures: [ShortcutCaptureRegistrationFailure] = []
    ) -> DiagnosticsPackageBuilder.Runtime {
        .init(
            captureStatus: ShortcutCaptureStatus(
                accessibilityGranted: true,
                inputMonitoringGranted: false,
                inputMonitoringRequired: false,
                carbonHotKeysRegistered: true,
                eventTapActive: false,
                standardShortcutsReady: true,
                hyperShortcutsReady: false,
                shortcutsPaused: false,
                standardShortcutCount: 3,
                registeredStandardShortcutCount: 3,
                standardHandlerState: .installed,
                standardRegistrationFailures: failures,
                secureInputActive: secureInput
            ),
            hyperKeyEnabled: false,
            shortcutCount: 4,
            enabledShortcutCount: 3,
            launchAtLoginStatus: "enabled"
        )
    }

    // MARK: - Contents

    @Test
    func theReportCarriesVersionSigningAndRouteReadiness() {
        let package = builder().build(environment: environment(), runtime: runtime(), logs: [])
        let report = try! #require(package.entries.first { $0.name == "report.md" }).contents

        #expect(report.contains("0.8.0 (800)"))
        #expect(report.contains("macOS: 15.5"))
        #expect(report.contains("Mode: Ad-hoc"))
        #expect(report.contains("Standard route ready: true"))
        #expect(report.contains("Hyper route ready: false"))
        #expect(report.contains("Secure Input active: false"))
    }

    @Test
    func theReportSeparatesSigningModeFromPermissionContinuity() {
        // The single most misread relationship in support threads: a signing
        // change can cost the TCC grants even though nothing behavioral moved.
        let report = builder().build(environment: environment(), runtime: runtime(), logs: [])
            .entries[0].contents
        #expect(report.contains("keys Accessibility and"))
        #expect(report.contains("re-granting"))
    }

    @Test
    func secureInputIsExplainedOnlyWhileItIsActive() {
        let quiet = builder().build(environment: environment(), runtime: runtime(), logs: [])
        #expect(!quiet.entries[0].contents.contains("Secure Input is engaged right now"))

        let engaged = builder().build(
            environment: environment(),
            runtime: runtime(secureInput: true),
            logs: []
        )
        #expect(engaged.entries[0].contents.contains("Secure Input is engaged right now"))
        #expect(engaged.entries[0].contents.contains("not a Wink failure"))
    }

    @Test
    func registrationFailuresAreListedWhenPresent() {
        let failure = ShortcutCaptureRegistrationFailure(
            keyPress: KeyPress(keyCode: 1, modifiers: [.command]),
            status: -9868
        )
        let package = builder().build(
            environment: environment(),
            runtime: runtime(failures: [failure]),
            logs: []
        )
        #expect(package.entries[0].contents.contains("status=-9868"))
    }

    // MARK: - Logs

    @Test
    func logsAreRedactedBeforeTheyEnterThePackage() {
        let package = builder().build(
            environment: environment(),
            runtime: runtime(),
            logs: [("debug.log", "opened /Users/alice/Library/Wink token=abc123 for alice")]
        )
        let log = try! #require(package.entries.first { $0.name == "debug.log" }).contents

        #expect(!log.contains("/Users/alice"))
        #expect(!log.contains("abc123"))
        #expect(!log.lowercased().contains("alice"))
    }

    @Test
    func aMissingLogIsNotedRatherThanOmitted() {
        // Omitting it would make the export look complete when it is not,
        // and "there is no log" is itself a diagnostic.
        let package = builder().build(
            environment: environment(),
            runtime: runtime(),
            logs: [("debug.log", nil)]
        )
        let entry = try! #require(package.entries.first { $0.name == "debug.log" })
        #expect(entry.contents.contains("missing or could not be read"))
    }

    @Test
    func anEmptyLogIsIncludedAsAnEmptyEntry() {
        let package = builder().build(
            environment: environment(),
            runtime: runtime(),
            logs: [("debug.log", "")]
        )
        #expect(package.entries.contains { $0.name == "debug.log" })
    }

    @Test
    func anOversizedLogKeepsItsTailAndSaysWhatItDropped() {
        let lines = (0..<5_000).map { "line \($0)" }.joined(separator: "\n")
        let package = builder().build(
            environment: environment(),
            runtime: runtime(),
            logs: [("debug.log", lines)]
        )
        let log = try! #require(package.entries.first { $0.name == "debug.log" }).contents

        // The tail is what a reproduction just wrote; the head is history.
        #expect(log.contains("line 4999"))
        #expect(!log.contains("line 0\n"))
        #expect(log.contains("earlier lines omitted"))
        #expect(log.split(separator: "\n").count <= DiagnosticsPackageBuilder.maximumLogLines + 1)
    }

    // MARK: - Preview honesty

    @Test
    func everyEntryCarriesASummaryTheUserCanRead() {
        let package = builder().build(
            environment: environment(),
            runtime: runtime(),
            logs: [("debug.log", "x"), ("debug.log.1", "y")]
        )
        #expect(package.entries.count == 3)
        for entry in package.entries {
            #expect(!entry.summary.isEmpty, "no summary for \(entry.name)")
            #expect(entry.byteCount > 0, "empty entry for \(entry.name)")
        }
    }

    @Test
    func disclosuresNameWhatSurvivesRedaction() {
        let joined = DiagnosticsPackage.disclosures.joined(separator: "\n")
        // Bundle identifiers and app names are deliberately kept, so the
        // preview has to say so — that is the whole reason they are allowed.
        #expect(joined.contains("bundle identifiers"))
        #expect(joined.contains("Nothing is uploaded"))
    }

    @Test
    func theSameValueBacksThePreviewAndTheExport() {
        // A preview assembled separately would be a second implementation of
        // these rules, and the one that matters is the one nobody reads.
        let package = builder().build(
            environment: environment(),
            runtime: runtime(),
            logs: [("debug.log", "hello")]
        )
        #expect(package.totalByteCount == package.entries.reduce(0) { $0 + $1.contents.utf8.count })
    }

    @Test
    func theExportIsDeterministicForTheSameInputs() {
        let first = builder().build(
            environment: environment(),
            runtime: runtime(),
            logs: [("debug.log", "path=/Users/alice/x")]
        )
        let second = builder().build(
            environment: environment(),
            runtime: runtime(),
            logs: [("debug.log", "path=/Users/alice/x")]
        )
        #expect(first == second)
    }

    @Test
    func nothingInThePackageContainsTheHomePathOrUserName() {
        // The end-to-end guarantee, asserted over the whole package rather
        // than per rule: no entry may carry either.
        let package = builder().build(
            environment: environment(),
            runtime: runtime(),
            logs: [
                ("debug.log", "/Users/alice/Library/Application Support/Wink/shortcuts.json"),
                ("debug.log.1", "user alice ran /Users/alice/bin/tool?token=x"),
            ]
        )
        for entry in package.entries {
            #expect(!entry.contents.contains("/Users/alice"), "home path leaked via \(entry.name)")
            #expect(!entry.contents.lowercased().contains("alice"), "user name leaked via \(entry.name)")
        }
    }
}
