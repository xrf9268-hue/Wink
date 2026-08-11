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
struct DiagnosticsPreviewSheet: View {
    @Environment(\.winkPalette) private var palette

    let package: DiagnosticsPackage
    @Bindable var diagnostics: DiagnosticsState

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

            List(package.entries) { entry in
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
            .frame(minHeight: 150)

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
        .frame(width: 520)
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
