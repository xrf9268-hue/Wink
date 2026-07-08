import AppKit
import SwiftUI

/// Presents the one-time post-update "What's New" panel.
///
/// A non-activating floating `NSPanel` ordered front without key status: an
/// accessory app must never steal focus from the user's current work just to
/// announce an update (issue #290).
@MainActor
final class WhatsNewPresenter {
    private var panel: NSPanel?

    func present(version: String, notes: [WhatsNewNote]) {
        guard panel == nil, !notes.isEmpty else { return }

        let hosting = NSHostingView(rootView: WhatsNewView(
            version: version,
            notes: notes,
            dismiss: { [weak self] in self?.dismiss() }
        ))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct WhatsNewView: View {
    let version: String
    let notes: [WhatsNewNote]
    let dismiss: () -> Void

    var body: some View {
        WhatsNewContent(version: version, notes: notes, dismiss: dismiss)
            .winkChromeRoot()
    }
}

private struct WhatsNewContent: View {
    @Environment(\.winkPalette) private var palette

    let version: String
    let notes: [WhatsNewNote]
    let dismiss: () -> Void

    private static let releasesURL = URL(string: "https://github.com/xrf9268-hue/Wink/releases")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                WinkAppIcon(size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New in Wink")
                        .font(WinkType.tabTitle)
                        .foregroundStyle(palette.textPrimary)
                    Text("Version \(version)")
                        .font(WinkType.labelSmall)
                        .foregroundStyle(palette.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(notes, id: \.title) { note in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: note.symbolName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(palette.accent)
                            .frame(width: 22, alignment: .center)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title)
                                .font(WinkType.bodyMedium)
                                .foregroundStyle(palette.textPrimary)
                            Text(note.detail)
                                .font(WinkType.labelSmall)
                                .foregroundStyle(palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            HStack {
                Link("Full release notes", destination: Self.releasesURL)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textTertiary)

                Spacer()

                Button("OK", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(palette.windowBg)
    }
}
