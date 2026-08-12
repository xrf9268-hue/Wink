import AppKit
import Foundation

/// The production wiring for `DiagnosticsState.Client`.
///
/// Kept apart from `DiagnosticsState` so the state machine stays testable
/// without a panel, a Finder call, or a write outside a temporary directory —
/// every effect below is one this file owns and the tests never run.
enum DiagnosticsClientLive {
    @MainActor
    static func make(
        preferences: AppPreferences,
        shortcutStore: ShortcutStore
    ) -> DiagnosticsState.Client {
        DiagnosticsState.Client(
            environment: { environment() },
            runtime: { runtime(preferences: preferences, shortcutStore: shortcutStore) },
            readLogs: { readLogs() },
            revealLog: { revealLog() },
            chooseExportDirectory: { suggestedName in try chooseExportDirectory(suggestedName: suggestedName) },
            writePackage: { directory, package in try write(package, to: directory) },
            now: Date.init
        )
    }

    // MARK: - Inputs

    @MainActor
    private static func environment() -> DiagnosticsPackageBuilder.Environment {
        let bundle = Bundle.main
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticsPackageBuilder.Environment(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            commitSHA: bundle.object(forInfoDictionaryKey: "WinkCommitSHA") as? String,
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: architecture(),
            signingMode: signingMode(),
            isNotarized: nil
        )
    }

    /// The hardware the process is actually executing as, so a Rosetta report
    /// does not read as native.
    private static func architecture() -> String {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated == 1 {
            return "x86_64 (Rosetta)"
        }
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Which KIND of signature, never the certificate, the team identifier, or
    /// the designated requirement — a support conversation needs to know
    /// whether TCC will hold across an update, not who signed the build.
    private static func signingMode() -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else {
            return "Unsigned"
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else {
            return "Unsigned"
        }
        guard let chain = info[kSecCodeInfoCertificates as String] as? [SecCertificate], !chain.isEmpty else {
            // Signed with no chain is the ad-hoc case, which is exactly the one
            // that silently breaks TCC across a Sparkle update (#283).
            return info[kSecCodeInfoIdentifier as String] == nil ? "Unsigned" : "Ad-hoc"
        }
        let names = chain.compactMap { certificate -> String? in
            var common: CFString?
            guard SecCertificateCopyCommonName(certificate, &common) == errSecSuccess else { return nil }
            return common as String?
        }
        if names.contains(where: { $0.hasPrefix("Developer ID Application") }) { return "Developer ID" }
        if names.contains(where: { $0.hasPrefix("Apple Development") }) { return "Development" }
        return "Self-signed"
    }

    @MainActor
    private static func runtime(
        preferences: AppPreferences,
        shortcutStore: ShortcutStore
    ) -> DiagnosticsPackageBuilder.Runtime {
        let shortcuts = shortcutStore.shortcuts
        return DiagnosticsPackageBuilder.Runtime(
            captureStatus: preferences.shortcutCaptureStatus,
            hyperKeyEnabled: preferences.hyperKeyEnabled,
            shortcutCount: shortcuts.count,
            enabledShortcutCount: shortcuts.filter(\.isEnabled).count,
            // The full status, not `launchAtLoginEnabled`: that boolean
            // collapses `.requiresApproval` and `.notFound` into the same
            // "disabled" report, even though one means "go approve it in
            // System Settings" and the other means "macOS never saw this
            // registration," which are different troubleshooting paths.
            launchAtLoginStatus: preferences.launchAtLoginStatus.diagnosticName
        )
    }

    /// A log that cannot be read is itself a diagnostic, so the failure is
    /// reported as content rather than raised — an export must not abort
    /// because the thing it is collecting is broken.
    // Deliberately NOT @MainActor: `prepareExport` runs this detached, and
    // the body needs nothing actor-bound — a queue barrier and file reads.
    private static func readLogs() -> [(name: String, contents: String?)] {
        // `DiagnosticLog.log()` queues its write asynchronously, so the last
        // few lines of the current session can still be sitting on the
        // writer's queue at the moment Export is pressed. Reading the file
        // straight through without this barrier would race that queue and
        // produce an export that is missing exactly the events a user is
        // most likely exporting to show someone.
        DiagnosticLog.flush()
        return collectLogs(primaryURL: DiagnosticLog.logFileURL(), fileManager: .default)
    }

    /// Reads the active log plus its rotated backup (`debug.log.1`) when one
    /// exists. `DiagnosticLogWriter` rotates the active file once it crosses
    /// its size cap, and `AppController.start()` can trigger that rotation
    /// moments before writing a fresh startup line — so an export taken
    /// right after rotation but before the file grows again would silently
    /// drop the entire earlier session if only `debug.log` were read. The
    /// backup is only added when it is actually there: most exports never
    /// rotate, and always listing a backup entry that does not exist would
    /// train users to ignore a "missing" note that is normal rather than a
    /// real gap.
    ///
    /// Free of `@MainActor`/AppKit so it can be exercised directly in tests
    /// against a temporary directory, unlike the rest of this file.
    static func collectLogs(primaryURL: URL, fileManager: FileManager) -> [(name: String, contents: String?)] {
        var logs: [(name: String, contents: String?)] = [
            (name: primaryURL.lastPathComponent, contents: try? String(contentsOf: primaryURL, encoding: .utf8)),
        ]
        let rotatedURL = URL(fileURLWithPath: primaryURL.path + ".1")
        if fileManager.fileExists(atPath: rotatedURL.path) {
            logs.append((
                name: rotatedURL.lastPathComponent,
                contents: try? String(contentsOf: rotatedURL, encoding: .utf8)
            ))
        }
        return logs
    }

    // MARK: - Effects

    @MainActor
    private static func revealLog() -> Bool {
        let url = DiagnosticLog.logFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    @MainActor
    private static func chooseExportDirectory(suggestedName: String) throws -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Export", bundle: WinkResourceBundle.bundle)
        panel.message = String(
            localized: "Choose where to save the diagnostics folder.",
            bundle: WinkResourceBundle.bundle
        )
        panel.nameFieldStringValue = suggestedName
        // Cancelling is a decision, not a failure.
        guard panel.runModal() == .OK, let directory = panel.url else { return nil }
        return directory.appendingPathComponent(suggestedName, isDirectory: true)
    }

    /// Writes into a directory that did not exist before this call, and
    /// returns it. Never merges into an existing folder: the suggested name
    /// has second resolution, so two rapid exports (or a clock rollback)
    /// resolve to the same path, and a silent reuse would leave files from
    /// the earlier export — an older `debug.log.1`, say — inside the folder
    /// the user shares, carrying data the preview never showed. A unique
    /// sibling keeps both exports complete instead of failing the second one
    /// for having clicked twice.
    ///
    /// Internal rather than private for the same reason as `collectLogs`:
    /// pure filesystem work, directly testable against a temp directory.
    static func write(_ package: DiagnosticsPackage, to directory: URL) throws -> URL {
        let destination = try claimUniqueDestination(for: directory)
        for entry in package.entries {
            try Data(entry.contents.utf8)
                .write(to: destination.appendingPathComponent(entry.name), options: .atomic)
        }
        return destination
    }

    /// `name`, `name-2`, `name-3`, … — the first sibling this process
    /// actually CREATES. The claim is the creation itself: an exists-check
    /// followed by `withIntermediateDirectories: true` lets two concurrent
    /// exports both observe the same name absent and both "succeed" into one
    /// folder, remerging what the unique name exists to keep apart. With
    /// `withIntermediateDirectories: false`, creation fails on an existing
    /// directory, so exactly one claimant wins each name and the loser moves
    /// to the next. The UUID tail is a bounded backstop; its create still
    /// throws honestly rather than claiming blindly.
    private static func claimUniqueDestination(for directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let base = directory.lastPathComponent
        for counter in 1...9_999 {
            let candidate = counter == 1
                ? directory
                : parent.appendingPathComponent("\(base)-\(counter)", isDirectory: true)
            do {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch {
                // Collision detection by SEMANTICS, not error code: the
                // existing-directory failure has surfaced as different
                // CocoaError/NSError codes across macOS releases, and a
                // missed bridging turns "try the next sibling" into a thrown
                // export. If the candidate exists now, someone holds it —
                // move on; anything else is a real failure.
                guard fileManager.fileExists(atPath: candidate.path) else { throw error }
                continue
            }
        }
        let backstop = parent.appendingPathComponent("\(base)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: backstop, withIntermediateDirectories: false)
        return backstop
    }
}
