import AppKit
import SwiftUI

/// Hosts the Wink-owned update panel (Issue #298): a floating window that
/// renders every `UpdatePhase` of an update session with Wink's design
/// system, replacing Sparkle's stock windows.
///
/// The panel is created once and re-presented for each session; SwiftUI
/// re-renders from the observable `AppPreferences.updatePhase` mirror. The
/// close button routes through `handleUpdatePanelCloseRequest()` so a held
/// Sparkle reply or acknowledgement is always consumed.
@MainActor
final class UpdatePanelPresenter: NSObject {
    private var panel: NSPanel?
    private weak var preferences: AppPreferences?

    func present(preferences: AppPreferences, activate: Bool) {
        self.preferences = preferences
        let panel = panel ?? makePanel(preferences: preferences)
        self.panel = panel

        if activate {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func makePanel(preferences: AppPreferences) -> NSPanel {
        let hosting = NSHostingView(rootView: UpdatePanelView(preferences: preferences))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Wink Update"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = hosting
        panel.center()
        return panel
    }
}

extension UpdatePanelPresenter: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Let the session action drive the dismissal (it calls back into
        // dismiss()); closing the window must never leak a Sparkle reply.
        preferences?.handleUpdatePanelCloseRequest()
        return false
    }
}

struct UpdatePanelView: View {
    let preferences: AppPreferences

    var body: some View {
        UpdatePanelContent(preferences: preferences)
            .winkChromeRoot()
    }
}

private struct UpdatePanelContent: View {
    @Environment(\.winkPalette) private var palette

    let preferences: AppPreferences

    private static let releasesURL = URL(string: "https://github.com/xrf9268-hue/Wink/releases")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            body(for: preferences.updatePhase)
        }
        .padding(20)
        .frame(width: 380)
        .background(palette.windowBg)
        .animation(.default, value: preferences.updatePhase)
    }

    private var header: some View {
        HStack(spacing: 10) {
            WinkAppIcon(size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(WinkType.tabTitle)
                    .foregroundStyle(palette.textPrimary)
                Text(headerSubtitle)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }

    private var headerTitle: String {
        switch preferences.updatePhase {
        case .idle, .checking:
            return "Checking for Updates"
        case .available:
            return "Update Available"
        case .downloading, .extracting:
            return "Downloading Update"
        case .ready:
            return "Update Ready"
        case .installing:
            return "Installing Update"
        case .upToDate:
            return "You're Up to Date"
        case .error:
            return "Update Check Failed"
        }
    }

    private var headerSubtitle: String {
        switch preferences.updatePhase {
        case .available(let version), .ready(let version):
            return "Wink \(version)"
        case .downloading(let version, _, _):
            return "Wink \(version)"
        default:
            return "Wink \(preferences.updatePresentation.currentVersion)"
        }
    }

    @ViewBuilder
    private func body(for phase: UpdatePhase) -> some View {
        switch phase {
        case .idle, .checking:
            progressSection(label: "Contacting the update feed…", fraction: nil)
            buttonRow(primary: nil, secondary: ("Cancel", { preferences.cancelUpdateOperation() }))

        case .available(let version):
            Text("Wink \(version) is available — you have \(preferences.updatePresentation.currentVersion). The update downloads in the background and installs on relaunch.")
                .font(WinkType.bodyText)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("View release notes", destination: Self.releasesURL)
                .font(WinkType.labelSmall)
                .foregroundStyle(palette.textTertiary)
            HStack {
                Button("Skip This Version") { preferences.skipUpdateVersion() }
                Spacer()
                Button("Later") { preferences.remindUpdateLater() }
                Button("Install Update") { preferences.installUpdateNow() }
                    .keyboardShortcut(.defaultAction)
            }

        case .downloading(_, let received, let expected):
            progressSection(
                label: downloadLabel(received: received, expected: expected),
                fraction: expected > 0 ? Double(received) / Double(expected) : nil
            )
            buttonRow(primary: nil, secondary: ("Cancel", { preferences.cancelUpdateOperation() }))

        case .extracting(let progress):
            progressSection(label: "Preparing update…", fraction: progress)
            buttonRow(primary: nil, secondary: nil)

        case .ready(let version):
            Text("Wink \(version) is downloaded. Relaunch now to finish installing, or keep working — it installs when Wink quits.")
                .font(WinkType.bodyText)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            buttonRow(
                primary: ("Install and Relaunch", { preferences.installUpdateNow() }),
                secondary: ("Later", { preferences.remindUpdateLater() })
            )

        case .installing:
            progressSection(label: "Installing… Wink will relaunch shortly.", fraction: nil)
            buttonRow(primary: nil, secondary: nil)

        case .upToDate:
            Text("Wink \(preferences.updatePresentation.currentVersion) is the latest version.")
                .font(WinkType.bodyText)
                .foregroundStyle(palette.textSecondary)
            buttonRow(primary: ("OK", { preferences.acknowledgeUpdateResult() }), secondary: nil)

        case .error(let message):
            Text(message)
                .font(WinkType.bodyText)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            buttonRow(primary: ("OK", { preferences.acknowledgeUpdateResult() }), secondary: nil)
        }
    }

    private func progressSection(label: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(WinkType.bodyText)
                .foregroundStyle(palette.textSecondary)
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
    }

    @ViewBuilder
    private func buttonRow(
        primary: (String, () -> Void)?,
        secondary: (String, () -> Void)?
    ) -> some View {
        if primary != nil || secondary != nil {
            HStack {
                Spacer()
                if let secondary {
                    Button(secondary.0, action: secondary.1)
                }
                if let primary {
                    Button(primary.0, action: primary.1)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func downloadLabel(received: UInt64, expected: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let got = formatter.string(fromByteCount: Int64(received))
        guard expected > 0 else { return "Downloading… \(got)" }
        let total = formatter.string(fromByteCount: Int64(expected))
        return "Downloading… \(got) of \(total)"
    }
}
