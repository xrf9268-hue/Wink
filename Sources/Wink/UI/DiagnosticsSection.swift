import SwiftUI

/// Reveal and Export, plus the sheet that shows exactly what an export will
/// contain before anything is written.
struct DiagnosticsSection: View {
    @Environment(\.winkPalette) private var palette

    @Bindable var diagnostics: DiagnosticsState

    var body: some View {
        WinkCard(
            title: { Text("Diagnostics", bundle: WinkResourceBundle.bundle) }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Share what Wink knows", bundle: WinkResourceBundle.bundle)
                            .font(WinkType.bodyMedium)
                            .foregroundStyle(palette.textPrimary)
                        Text(
                            "Everything stays on this Mac. Wink shows you the contents before you save them, and never uploads anything.",
                            bundle: WinkResourceBundle.bundle
                        )
                        .font(WinkType.labelSmall)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        WinkButton(String(localized: "Reveal Log", bundle: WinkResourceBundle.bundle)) {
                            diagnostics.revealDiagnosticLog()
                        }
                        WinkButton(
                            String(localized: "Export…", bundle: WinkResourceBundle.bundle),
                            variant: .primary
                        ) {
                            diagnostics.prepareExport()
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if let feedback = diagnostics.feedback {
                    Divider().overlay(palette.hairline)
                    Text(feedback.message)
                        .font(WinkType.labelSmall)
                        .foregroundStyle(feedback.isError ? palette.red : palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .accessibilityAddTraits(feedback.isError ? .isStaticText : .isStaticText)
                }
            }
        }
        .sheet(isPresented: previewPresented) {
            if let package = diagnostics.preview {
                DiagnosticsPreviewSheet(package: package, diagnostics: diagnostics)
            }
        }
    }

    private var previewPresented: Binding<Bool> {
        Binding(
            get: { diagnostics.preview != nil },
            set: { presented in
                if !presented { diagnostics.cancelExport() }
            }
        )
    }
}

/// The approval step. It lists every file that will be written, its size, and
/// what it contains — and states the three things a user would otherwise only
/// discover after sharing the export.
///
/// Contents are shown, not just summarized: the Diagnostics card promises the
/// user can verify what leaves the machine before it does, and a name plus a
/// byte count cannot be checked for a redaction miss. Entries are selectable
/// rather than all expanded at once so a multi-file package (report, current
/// log, rotated log) stays scannable instead of turning into one long scroll.
struct DiagnosticsPreviewSheet: View {
    @Environment(\.winkPalette) private var palette

    let package: DiagnosticsPackage
    @Bindable var diagnostics: DiagnosticsState

    @State private var selectedEntryID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Diagnostics", bundle: WinkResourceBundle.bundle)
                .font(WinkType.cardTitle)
                .foregroundStyle(palette.textPrimary)

            Text(
                "\(package.entries.count) files, \(byteCountText) in total.",
                bundle: WinkResourceBundle.bundle
            )
            .font(WinkType.labelSmall)
            .foregroundStyle(palette.textSecondary)

            List(package.entries, selection: $selectedEntryID) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(entry.name)
                            .font(WinkType.monoSmall)
                            .foregroundStyle(palette.textPrimary)
                        Spacer(minLength: 8)
                        Text(Self.formatted(bytes: entry.byteCount))
                            .font(WinkType.labelSmall)
                            .foregroundStyle(palette.textTertiary)
                    }
                    Text(entry.summary)
                        .font(WinkType.labelSmall)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
            .frame(minHeight: 110, maxHeight: 130)

            contentsPane

            VStack(alignment: .leading, spacing: 6) {
                ForEach(DiagnosticsPackage.disclosures, id: \.self) { disclosure in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(palette.textTertiary)
                        Text(disclosure)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textSecondary)
                }
            }

            if let feedback = diagnostics.feedback, feedback.isError {
                WinkBanner(kind: .error, title: feedback.message)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                WinkButton(String(localized: "Cancel", bundle: WinkResourceBundle.bundle)) {
                    diagnostics.cancelExport()
                }
                .keyboardShortcut(.cancelAction)

                WinkButton(
                    String(localized: "Save…", bundle: WinkResourceBundle.bundle),
                    variant: .primary
                ) {
                    diagnostics.confirmExport()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear {
            // Nothing is selected on first appearance; default to the first
            // entry so the contents pane below is never blank, and so the
            // list's own highlight agrees with what it is showing.
            if selectedEntryID == nil {
                selectedEntryID = package.entries.first?.id
            }
        }
    }

    /// The entry the contents pane below currently shows. Falls back to the
    /// first entry — before a selection is made, and if a stale id ever
    /// pointed at an entry that is no longer in this package — rather than
    /// going blank.
    private var displayedEntry: DiagnosticsPackage.Entry? {
        Self.displayedEntry(for: selectedEntryID, in: package)
    }

    /// `nonisolated` deliberately: this is pure selection logic with no UI
    /// affinity, and leaving it to inherit `DiagnosticsPreviewSheet`'s
    /// implicit `@MainActor` isolation (from its `View` conformance) would
    /// force every caller — including plain, non-`@MainActor` unit tests —
    /// through an actor hop for no reason.
    nonisolated static func displayedEntry(
        for selection: String?,
        in package: DiagnosticsPackage
    ) -> DiagnosticsPackage.Entry? {
        if let selection, let match = package.entries.first(where: { $0.id == selection }) {
            return match
        }
        return package.entries.first
    }

    @ViewBuilder
    private var contentsPane: some View {
        if let entry = displayedEntry {
            VStack(alignment: .leading, spacing: 4) {
                Text("Contents of \(entry.name)", bundle: WinkResourceBundle.bundle)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textTertiary)

                ScrollView {
                    Text(entry.contents)
                        .font(WinkType.monoSmall)
                        .foregroundStyle(palette.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 180)
                .background(palette.fieldBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(palette.fieldBorder)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var byteCountText: String {
        Self.formatted(bytes: package.totalByteCount)
    }

    /// Locale-aware for display only — this text never reaches a filename or
    /// any persisted value.
    private static func formatted(bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
