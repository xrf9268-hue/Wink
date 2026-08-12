import Foundation

/// Everything an export will contain, described before it is written.
///
/// The preview and the export are built from the *same* value, so the list the
/// user approves cannot drift from what lands on disk — a preview assembled
/// separately would be a second implementation of the same rules, and the one
/// that matters is the one nobody reads.
struct DiagnosticsPackage: Equatable, Sendable {
    struct Entry: Equatable, Sendable, Identifiable {
        var id: String { name }
        /// File name inside the exported folder.
        var name: String
        /// One line the preview shows verbatim. Written for a user deciding
        /// whether to send this to a stranger, not for a developer.
        var summary: String
        var contents: String

        var byteCount: Int { contents.utf8.count }
    }

    var entries: [Entry]

    var totalByteCount: Int {
        entries.reduce(0) { $0 + $1.byteCount }
    }

    /// Facts about the export the preview must state outright, because they
    /// are the ones a user would be surprised by afterwards.
    static let disclosures: [String] = [
        String(
            localized: "Application names and bundle identifiers are included. They are what make a report useful, and they reveal which apps you have shortcuts for.",
            bundle: WinkResourceBundle.bundle
        ),
        String(
            localized: "Your user name and home folder path are removed, as are passwords, tokens, and web addresses' query strings.",
            bundle: WinkResourceBundle.bundle
        ),
        String(
            localized: "Nothing is uploaded. The export is written where you choose and Wink sends no part of it anywhere.",
            bundle: WinkResourceBundle.bundle
        ),
    ]
}

/// Builds the export from values the caller supplies, so the whole package is
/// reproducible in a test without touching the real system.
struct DiagnosticsPackageBuilder: Sendable {
    /// Bounds are part of the contract, not a safety net: an unbounded export
    /// is one a user cannot reason about before sharing it.
    static let maximumLogLines = 2_000

    struct Environment: Equatable, Sendable {
        var appVersion: String
        var buildNumber: String
        var commitSHA: String?
        var osVersion: String
        var architecture: String
        /// "Developer ID", "Ad-hoc", "Unsigned" — never the certificate, the
        /// team identifier, or the designated requirement, none of which a
        /// support conversation needs.
        var signingMode: String
        var isNotarized: Bool?
    }

    struct Runtime: Equatable, Sendable {
        var captureStatus: ShortcutCaptureStatus
        var hyperKeyEnabled: Bool
        var shortcutCount: Int
        var enabledShortcutCount: Int
        var launchAtLoginStatus: String
    }

    var redactor: DiagnosticsRedactor
    var generatedAt: Date

    init(redactor: DiagnosticsRedactor = DiagnosticsRedactor(), generatedAt: Date) {
        self.redactor = redactor
        self.generatedAt = generatedAt
    }

    func build(
        environment: Environment,
        runtime: Runtime,
        logs: [(name: String, contents: String?)]
    ) -> DiagnosticsPackage {
        var entries: [DiagnosticsPackage.Entry] = [
            DiagnosticsPackage.Entry(
                name: "report.md",
                summary: String(
                    localized: "Wink and macOS versions, how Wink is signed, and which shortcut routes are currently ready.",
                    bundle: WinkResourceBundle.bundle
                ),
                contents: report(environment: environment, runtime: runtime)
            ),
        ]

        for log in logs {
            // A missing or unreadable log is included as an explicit note
            // rather than omitted: "there is no log" is itself a diagnostic,
            // and silently dropping the entry would make the export look
            // complete when it is not.
            // Redaction runs BEFORE the tail bound. The redactor folds a
            // legacy record's continuation lines back into one line, so the
            // bound then counts whole records — bounding first could cut a
            // record's timestamped label line away from its continuations,
            // and the unlabeled fragments would export unredacted.
            let body = log.contents.map { boundedTail(of: redactor.redact(text: $0)) }
                ?? String(
                    localized: "This log was missing or could not be read when the export was created.",
                    bundle: WinkResourceBundle.bundle
                )
            entries.append(
                DiagnosticsPackage.Entry(
                    name: log.name,
                    summary: String(
                        localized: "Recent Wink activity, with user name, home path, and secrets removed.",
                        bundle: WinkResourceBundle.bundle
                    ),
                    contents: body
                )
            )
        }

        return DiagnosticsPackage(entries: entries)
    }

    /// Keeps the **last** N lines: a diagnostic is almost always about what
    /// just happened, and truncating the head would drop the reproduction the
    /// user just performed.
    private func boundedTail(of text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > Self.maximumLogLines else { return text }
        let dropped = lines.count - Self.maximumLogLines
        let kept = lines.suffix(Self.maximumLogLines).joined(separator: "\n")
        return "… \(dropped) earlier lines omitted\n" + kept
    }

    private func report(environment: Environment, runtime: Runtime) -> String {
        let status = runtime.captureStatus
        var lines: [String] = []

        lines.append("# Wink diagnostics")
        lines.append("")
        lines.append("Generated \(ISO8601DateFormatter().string(from: generatedAt))")
        lines.append("")
        lines.append("## Version")
        lines.append("- Wink: \(environment.appVersion) (\(environment.buildNumber))")
        lines.append("- Commit: \(environment.commitSHA ?? "unknown")")
        lines.append("- macOS: \(environment.osVersion)")
        lines.append("- Architecture: \(environment.architecture)")
        lines.append("")
        lines.append("## Signing")
        lines.append("- Mode: \(environment.signingMode)")
        lines.append("- Notarized: \(environment.isNotarized.map { $0 ? "yes" : "no" } ?? "unknown")")
        lines.append("")
        lines.append("Signing mode is separate from permissions: macOS keys Accessibility and")
        lines.append("Input Monitoring to the signing identity, so a change of identity can")
        lines.append("require re-granting them even though nothing about the app's behavior changed.")
        lines.append("")
        lines.append("## Shortcut routes")
        lines.append("- Accessibility granted: \(status.accessibilityGranted)")
        lines.append("- Input Monitoring granted: \(status.inputMonitoringGranted)")
        lines.append("- Input Monitoring required: \(status.inputMonitoringRequired)")
        lines.append("- Standard route ready: \(status.standardShortcutsReady)")
        lines.append("- Hyper route ready: \(status.hyperShortcutsReady)")
        lines.append("- Carbon hotkeys registered: \(status.carbonHotKeysRegistered)")
        lines.append("- Event tap active: \(status.eventTapActive)")
        lines.append("- Standard bindings: \(status.registeredStandardShortcutCount)/\(status.standardShortcutCount) registered")
        lines.append("- Handler state: \(status.standardHandlerState.diagnosticName)")
        lines.append("- Secure Input active: \(status.secureInputActive)")
        lines.append("- Capture paused: \(status.shortcutsPaused)")
        lines.append("")
        if status.secureInputActive {
            lines.append("Secure Input is engaged right now. While it is, macOS withholds key")
            lines.append("events from every tap-dependent route — Hyper chords AND standard")
            lines.append("Fn+F-row bindings, whose observer fails closed. Carbon-registered")
            lines.append("standard chords keep working. This is expected, not a Wink failure,")
            lines.append("and it ends when the secure field or prompt is dismissed.")
            lines.append("")
        }
        lines.append("## Configuration")
        lines.append("- Hyper key enabled: \(runtime.hyperKeyEnabled)")
        lines.append("- Shortcuts: \(runtime.enabledShortcutCount) enabled of \(runtime.shortcutCount)")
        lines.append("- Launch at login: \(runtime.launchAtLoginStatus)")
        lines.append("")

        if !status.standardRegistrationFailures.isEmpty {
            lines.append("## Registration failures")
            for failure in status.standardRegistrationFailures {
                lines.append("- keyCode=\(failure.keyPress.keyCode) modifiers=\(failure.keyPress.modifiers.rawValue) status=\(failure.status)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
