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
        /// `@Sendable`, not `@MainActor`: log reading and the redaction pass
        /// that follows it run OFF the main actor (see `prepareExport`), so
        /// this closure must not touch actor-bound state. The live client
        /// only flushes the writer's queue and reads files.
        var readLogs: @Sendable () -> [(name: String, contents: String?)]
        var revealLog: @MainActor () -> Bool
        /// Returns the chosen destination folder, or `nil` if the user
        /// cancelled. Cancelling is not an error.
        var chooseExportDirectory: @MainActor (_ suggestedName: String) throws -> URL?
        /// Returns the directory it actually wrote — the implementation may
        /// pick a unique sibling rather than merge into an existing folder,
        /// and the success message must name the folder the files are in.
        /// `@Sendable`, not `@MainActor`: the writes run OFF the main actor
        /// (see `confirmExport`) — a save onto a slow external or
        /// network-backed volume must not freeze Settings for the duration.
        var writePackage: @Sendable (_ directory: URL, _ package: DiagnosticsPackage) throws -> URL
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
    ///
    /// The actor-bound inputs (environment, runtime, the timestamp) are
    /// captured here, synchronously; the file reads and the redaction pass —
    /// twenty-odd regular-expression replacements per line, across two logs
    /// that can each approach their size cap — run detached, so opening the
    /// preview never blocks the Settings UI. `preview` is published back on
    /// the main actor when the package is ready.
    func prepareExport() {
        guard preparation == nil else { return }
        feedback = nil
        let builder = DiagnosticsPackageBuilder(generatedAt: client.now())
        let environment = client.environment()
        let runtime = client.runtime()
        let readLogs = client.readLogs
        preparation = Task { [weak self] in
            let package = await Task.detached(priority: .userInitiated) {
                builder.build(environment: environment, runtime: runtime, logs: readLogs())
            }.value
            // Cancellation check AFTER the hop: cancelExport() ran while the
            // build was in flight, already cleared the guard, and the user
            // saw the sheet close — publishing now would reopen it.
            guard let self, !Task.isCancelled else { return }
            self.preview = package
            self.previewGeneration &+= 1
            self.preparation = nil
        }
    }

    /// The in-flight preview build, if any. Also the re-entrancy guard: a
    /// second click while the first build runs must not race two packages.
    private var preparation: Task<Void, Never>?

    /// Lets a test await the published preview without polling.
    func waitForExportPreparationForTesting() async {
        await preparation?.value
    }

    func cancelExport() {
        // Cancels the in-flight build too: without this, a preparation
        // started before the cancel publishes its preview afterward —
        // reopening the sheet the user just dismissed — while the still-set
        // guard rejects every new prepareExport().
        preparation?.cancel()
        preparation = nil
        preview = nil
        previewGeneration &+= 1
    }

    /// Writes exactly the package the user was shown.
    func confirmExport() {
        guard let package = preview, saving == nil else { return }
        do {
            // The panel is modal and main-actor by nature; only the WRITES
            // hop off — saving onto a slow external or network-backed volume
            // must not freeze Settings for the duration.
            guard let directory = try client.chooseExportDirectory(Self.suggestedFolderName(at: client.now())) else {
                // Cancelling the panel is not a failure, and saying so would
                // train users to ignore the message area.
                preview = nil
                return
            }
            let writePackage = client.writePackage
            let generation = previewGeneration
            saving = Task { [weak self] in
                let outcome: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                    Result { try writePackage(directory, package) }
                }.value
                guard let self else { return }
                switch outcome {
                case let .success(written):
                    // Cleared only when the sheet still shows the GENERATION
                    // this save was confirmed from. On a slow volume the
                    // user may have cancelled and prepared a new preview
                    // meanwhile — dismissing that one on the old save's
                    // completion would close a sheet the user is reading.
                    // Generation, not package value: two previews built in
                    // the same second are value-equal and would alias. The
                    // feedback is published either way: the save DID
                    // complete.
                    if self.previewGeneration == generation {
                        self.preview = nil
                    }
                    self.feedback = .success(
                        String(
                            localized: "Saved \(package.entries.count) files to \(written.lastPathComponent).",
                            bundle: WinkResourceBundle.bundle
                        )
                    )
                case let .failure(error):
                    // The originating preview stays up so the user can retry
                    // a different folder without rebuilding. The error is
                    // generation-gated where the success toast is not: "Saved
                    // N files to X" is context-free and true whenever it
                    // fires, but an error RENDERS INSIDE whatever sheet is
                    // showing — and a newer preview that was never saved must
                    // not display a failure it did not have. A cancelled
                    // attempt's late failure has no surface left that would
                    // not lie, so it is dropped with the sheet it belonged to.
                    if self.previewGeneration == generation {
                        self.feedback = .error(
                            String(
                                localized: "Could not write the diagnostics: \(error.localizedDescription)",
                                bundle: WinkResourceBundle.bundle
                            )
                        )
                    }
                }
                self.saving = nil
            }
        } catch {
            feedback = .error(
                String(
                    localized: "Could not write the diagnostics: \(error.localizedDescription)",
                    bundle: WinkResourceBundle.bundle
                )
            )
        }
    }

    /// The in-flight save; also the re-entrancy guard against a double
    /// Save click racing two writes into sibling folders.
    private var saving: Task<Void, Never>?

    /// Bumped every time a preview is published or dismissed. A slow save's
    /// completion compares against the value it was confirmed under, so it
    /// can never dismiss a NEWER preview — package values cannot carry that
    /// identity, because two previews built in the same second are equal.
    private var previewGeneration: UInt64 = 0

    /// Lets a test await the published save outcome without polling.
    func waitForExportCompletionForTesting() async {
        await saving?.value
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
