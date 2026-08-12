import Foundation
import Testing
@testable import Wink

@Suite("Diagnostics export flow")
@MainActor
struct DiagnosticsStateTests {
    private final class Recorder: @unchecked Sendable {
        var revealed = 0
        var chosen: [String] = []
        var written: [(URL, DiagnosticsPackage)] = []
        var cancelPanel = false
        var writeFails = false
        var logExists = true
    }

    private func makeState(
        recorder: Recorder,
        logs: [(name: String, contents: String?)] = [("debug.log", "hello /Users/alice/x")]
    ) -> DiagnosticsState {
        DiagnosticsState(
            client: DiagnosticsState.Client(
                environment: {
                    .init(
                        appVersion: "0.8.0",
                        buildNumber: "800",
                        commitSHA: "abc",
                        osVersion: "15.5",
                        architecture: "arm64",
                        signingMode: "Ad-hoc",
                        isNotarized: false
                    )
                },
                runtime: {
                    .init(
                        captureStatus: ShortcutCaptureStatus(
                            accessibilityGranted: true,
                            inputMonitoringGranted: true,
                            inputMonitoringRequired: false,
                            carbonHotKeysRegistered: true,
                            eventTapActive: false,
                            standardShortcutsReady: true,
                            hyperShortcutsReady: true,
                            shortcutsPaused: false,
                            standardShortcutCount: 1,
                            registeredStandardShortcutCount: 1,
                            standardHandlerState: .installed,
                            standardRegistrationFailures: [],
                            secureInputActive: false
                        ),
                        hyperKeyEnabled: false,
                        shortcutCount: 1,
                        enabledShortcutCount: 1,
                        launchAtLoginStatus: "disabled"
                    )
                },
                readLogs: { logs },
                revealLog: {
                    recorder.revealed += 1
                    return recorder.logExists
                },
                chooseExportDirectory: { name in
                    recorder.chosen.append(name)
                    if recorder.cancelPanel { return nil }
                    return URL(fileURLWithPath: "/tmp/\(name)")
                },
                writePackage: { url, package in
                    struct InjectedWriteFailure: Error {}
                    if recorder.writeFails { throw InjectedWriteFailure() }
                    recorder.written.append((url, package))
                    return url
                },
                now: { Date(timeIntervalSince1970: 1_770_000_000) }
            )
        )
    }

    // MARK: - Nothing happens without an explicit action

    @Test
    func preparingAnExportWritesNothing() async {
        let recorder = Recorder()
        let state = makeState(recorder: recorder)

        state.prepareExport()
        await state.waitForExportPreparationForTesting()

        #expect(state.preview != nil)
        #expect(recorder.written.isEmpty)
        #expect(recorder.chosen.isEmpty)
    }

    @Test
    func cancellingThePreviewWritesNothing() async {
        let recorder = Recorder()
        let state = makeState(recorder: recorder)

        state.prepareExport()
        await state.waitForExportPreparationForTesting()
        state.cancelExport()

        #expect(state.preview == nil)
        #expect(recorder.written.isEmpty)
    }

    @Test
    func cancellingDuringPreparationSuppressesTheLatePreview() async {
        let recorder = Recorder()
        let state = makeState(recorder: recorder)

        // Cancel while the build is still in flight: the late publish must
        // not reopen the sheet the user just dismissed, and the guard must
        // be free for the next attempt rather than pinned by a dead task.
        state.prepareExport()
        state.cancelExport()
        #expect(state.preview == nil)

        state.prepareExport()
        await state.waitForExportPreparationForTesting()
        #expect(state.preview != nil)
    }

    @Test
    func confirmingWithoutAPreviewIsANoOp() {
        let recorder = Recorder()
        let state = makeState(recorder: recorder)

        state.confirmExport()

        #expect(recorder.chosen.isEmpty)
        #expect(recorder.written.isEmpty)
    }

    // MARK: - The preview is what gets written

    @Test
    func exactlyThePreviewedPackageIsWritten() async {
        let recorder = Recorder()
        let state = makeState(recorder: recorder)

        state.prepareExport()
        await state.waitForExportPreparationForTesting()
        let previewed = try! #require(state.preview)
        state.confirmExport()

        #expect(recorder.written.count == 1)
        #expect(recorder.written[0].1 == previewed)
    }

    @Test
    func theExportedLogIsAlreadyRedacted() async {
        let recorder = Recorder()
        let state = makeState(
            recorder: recorder,
            logs: [("debug.log", "opened /Users/alice/secrets token=S3CRETVALUE")]
        )

        state.prepareExport()
        await state.waitForExportPreparationForTesting()
        state.confirmExport()

        let written = try! #require(recorder.written.first?.1)
        for entry in written.entries {
            #expect(!entry.contents.contains("S3CRETVALUE"))
            #expect(!entry.contents.contains("/Users/alice"))
        }
    }

    // MARK: - Failure paths

    @Test
    func cancellingTheFolderPanelIsNotReportedAsAFailure() async {
        let recorder = Recorder()
        recorder.cancelPanel = true
        let state = makeState(recorder: recorder)

        state.prepareExport()
        await state.waitForExportPreparationForTesting()
        state.confirmExport()

        // Reporting a cancel as an error trains users to ignore the message
        // area, which is where real failures also appear.
        #expect(state.feedback == nil)
        #expect(state.preview == nil)
        #expect(recorder.written.isEmpty)
    }

    @Test
    func aFailedWriteKeepsThePreviewSoARetryExportsTheSameBytes() async {
        let recorder = Recorder()
        recorder.writeFails = true
        let state = makeState(recorder: recorder)

        state.prepareExport()
        await state.waitForExportPreparationForTesting()
        let previewed = try! #require(state.preview)
        state.confirmExport()

        #expect(state.feedback?.isError == true)
        #expect(state.preview == previewed)
    }

    @Test
    func revealReportsAMissingLogInsteadOfFailingSilently() {
        let recorder = Recorder()
        recorder.logExists = false
        let state = makeState(recorder: recorder)

        state.revealDiagnosticLog()

        #expect(recorder.revealed == 1)
        #expect(state.feedback?.isError == true)
    }

    @Test
    func anUnreadableLogStillProducesAnExport() async {
        // A log that cannot be read is a diagnostic in its own right; it must
        // not abort the export.
        let recorder = Recorder()
        let state = makeState(recorder: recorder, logs: [("debug.log", nil)])

        state.prepareExport()
        await state.waitForExportPreparationForTesting()
        state.confirmExport()

        #expect(recorder.written.count == 1)
        #expect(try! #require(state.feedback).isError == false)
    }

    // MARK: - Naming

    @Test
    func theSuggestedFolderNameIsLocaleStable() {
        // It is a filename, so it must not change with the user's language —
        // the same rule persisted identifiers follow.
        let name = DiagnosticsState.suggestedFolderName(at: Date(timeIntervalSince1970: 1_770_000_000))
        #expect(name.hasPrefix("Wink-diagnostics-"))
        #expect(name.allSatisfy { $0.isASCII })
        #expect(name == DiagnosticsState.suggestedFolderName(at: Date(timeIntervalSince1970: 1_770_000_000)))
    }
}
