import AppKit
import Foundation
import Observation

/// Drives Reveal and Export from Settings.
///
/// Every side effect the export needs — reading logs, choosing a folder,
/// writing files, revealing in Finder — goes through an injected client, so the
/// whole flow is exercisable in a test without a panel, a Finder call, or a
/// write outside a temporary directory.
@MainActor
@Observable
final class DiagnosticsState {
    struct Client {
        var environment: @MainActor () -> DiagnosticsPackageBuilder.Environment
        var runtime: @MainActor () -> DiagnosticsPackageBuilder.Runtime
        /// Log name → contents, or `nil` when it is missing or unreadable.
        /// Reading never throws: a log that cannot be read is a diagnostic in
        /// its own right and must not abort the export.
        var readLogs: @MainActor () -> [(name: String, contents: String?)]
        var revealLog: @MainActor () -> Bool
        /// Returns the chosen destination folder, or `nil` if the user
        /// cancelled. Cancelling is not an error.
        var chooseExportDirectory: @MainActor (_ suggestedName: String) throws -> URL?
        var writePackage: @MainActor (_ directory: URL, _ package: DiagnosticsPackage) throws -> Void
        var now: @MainActor () -> Date
    }

    enum Feedback: Equatable {
        case success(String)
        case error(String)

        var message: String {
            switch self {
            case let .success(message), let .error(message): return message
            }
        }

        var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }

    /// Non-nil while the preview sheet is up. Holding the built package here
    /// — rather than rebuilding it on save — is what makes the preview and the
    /// export the same bytes rather than two runs that could differ.
    private(set) var preview: DiagnosticsPackage?
    var feedback: Feedback?

    private let client: Client

    init(client: Client) {
        self.client = client
    }

    // MARK: - Reveal

    func revealDiagnosticLog() {
        guard client.revealLog() else {
            feedback = .error(
                String(
                    localized: "There is no diagnostic log yet. Use Wink for a moment and try again.",
                    bundle: WinkResourceBundle.bundle
                )
            )
            return
        }
        feedback = nil
    }

    // MARK: - Export

    /// Builds the package and shows it. Nothing is written yet — the user has
    /// to see the contents before any file leaves Wink's own storage.
    func prepareExport() {
        let builder = DiagnosticsPackageBuilder(generatedAt: client.now())
        preview = builder.build(
            environment: client.environment(),
            runtime: client.runtime(),
            logs: client.readLogs()
        )
        feedback = nil
    }

    func cancelExport() {
        preview = nil
    }

    /// Writes exactly the package the user was shown.
    func confirmExport() {
        guard let package = preview else { return }
        do {
            guard let directory = try client.chooseExportDirectory(Self.suggestedFolderName(at: client.now())) else {
                // Cancelling the panel is not a failure, and saying so would
                // train users to ignore the message area.
                preview = nil
                return
            }
            try client.writePackage(directory, package)
            preview = nil
            feedback = .success(
                String(
                    localized: "Saved \(package.entries.count) files to \(directory.lastPathComponent).",
                    bundle: WinkResourceBundle.bundle
                )
            )
        } catch {
            // The preview stays up so the user can retry a different folder
            // without rebuilding — and without the contents changing under
            // them between the two attempts.
            feedback = .error(
                String(
                    localized: "Could not write the diagnostics: \(error.localizedDescription)",
                    bundle: WinkResourceBundle.bundle
                )
            )
        }
    }

    /// Locale-stable folder name: this is a filename, so it must not change
    /// with the user's language (the same rule persisted identifiers follow).
    static func suggestedFolderName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Wink-diagnostics-\(formatter.string(from: date))"
    }
}

extension DiagnosticsState.Client {
    /// The live wiring. Kept out of `DiagnosticsState` so nothing in the flow
    /// can reach AppKit or the filesystem except through this one value.
    @MainActor
    static func live(
        environment: @escaping @MainActor () -> DiagnosticsPackageBuilder.Environment,
        runtime: @escaping @MainActor () -> DiagnosticsPackageBuilder.Runtime
    ) -> DiagnosticsState.Client {
        DiagnosticsState.Client(
            environment: environment,
            runtime: runtime,
            readLogs: {
                let primary = DiagnosticLog.logFileURL()
                let rotated = URL(fileURLWithPath: primary.path + ".1")
                return [
                    (primary.lastPathComponent, try? String(contentsOf: primary, encoding: .utf8)),
                    (rotated.lastPathComponent, try? String(contentsOf: rotated, encoding: .utf8)),
                ]
            },
            revealLog: {
                let url = DiagnosticLog.logFileURL()
                guard FileManager.default.fileExists(atPath: url.path) else { return false }
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return true
            },
            chooseExportDirectory: { suggestedName in
                let panel = NSSavePanel()
                panel.canCreateDirectories = true
                panel.nameFieldStringValue = suggestedName
                panel.prompt = String(localized: "Export", bundle: WinkResourceBundle.bundle)
                guard panel.runModal() == .OK, let url = panel.url else { return nil }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            },
            writePackage: { directory, package in
                for entry in package.entries {
                    try Data(entry.contents.utf8).write(
                        to: directory.appendingPathComponent(entry.name),
                        options: .atomic
                    )
                }
            },
            now: Date.init
        )
    }
}
