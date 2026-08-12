import Foundation
@testable import Wink

/// A `DiagnosticsState` whose every effect is a no-op, for views that have to
/// construct one but are not testing it. Nothing here touches the filesystem,
/// a panel, or Finder.
@MainActor
func makeInertDiagnosticsState() -> DiagnosticsState {
    DiagnosticsState(
        client: DiagnosticsState.Client(
            environment: {
                .init(
                    appVersion: "0.0.0",
                    buildNumber: "0",
                    commitSHA: nil,
                    osVersion: "15.0",
                    architecture: "arm64",
                    signingMode: "Unsigned",
                    isNotarized: nil
                )
            },
            runtime: {
                .init(
                    captureStatus: ShortcutCaptureStatus(
                        accessibilityGranted: false,
                        inputMonitoringGranted: false,
                        inputMonitoringRequired: false,
                        carbonHotKeysRegistered: false,
                        eventTapActive: false,
                        standardShortcutsReady: false,
                        hyperShortcutsReady: false
                    ),
                    hyperKeyEnabled: false,
                    shortcutCount: 0,
                    enabledShortcutCount: 0,
                    launchAtLoginStatus: "disabled"
                )
            },
            readLogs: { [] },
            revealLog: { false },
            chooseExportDirectory: { _ in nil },
            writePackage: { url, _ in url },
            now: { Date(timeIntervalSince1970: 0) }
        )
    )
}
