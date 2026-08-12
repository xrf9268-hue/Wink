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
    @MainActor
    private static func readLogs() -> [(name: String, contents: String?)] {
        let url = DiagnosticLog.logFileURL()
        return [(name: url.lastPathComponent, contents: try? String(contentsOf: url, encoding: .utf8))]
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

    private static func write(_ package: DiagnosticsPackage, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in package.entries {
            try Data(entry.contents.utf8)
                .write(to: directory.appendingPathComponent(entry.name), options: .atomic)
        }
    }
}
