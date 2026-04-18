import SwiftUI

// MARK: - Card container

struct CardView<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Alternating row background

extension View {
    func alternatingRowBackground(index: Int) -> some View {
        self.background(index.isMultiple(of: 2)
            ? Color.clear
            : Color.primary.opacity(0.03))
    }
}

// MARK: - App icon resolver

/// `NSWorkspace.icon(forFile:)` decodes the ICNS on the main thread; without
/// caching, every row in the picker / insights lists re-decodes on each render.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleIdentifier: String) -> NSImage? {
        if let cached = cache[bundleIdentifier] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleIdentifier] = icon
        return icon
    }
}

struct AppIconView: View {
    let bundleIdentifier: String
    let size: CGFloat

    @State private var icon: NSImage?

    var body: some View {
        Image(nsImage: icon ?? Self.fallbackIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            .onAppear { resolveIcon() }
            .onChange(of: bundleIdentifier) { resolveIcon() }
    }

    private func resolveIcon() {
        icon = AppIconCache.icon(for: bundleIdentifier) ?? Self.fallbackIcon
    }

    private static let fallbackIcon = NSWorkspace.shared.icon(for: .application)
}

// MARK: - Shortcut label badge

struct ShortcutLabel: View {
    let displayText: String
    let isHyper: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(displayText)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            if isHyper {
                Text("Hyper")
                    .font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.purple.opacity(0.2))
                    .foregroundStyle(.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }
}

// MARK: - Permission status banner

struct PermissionStatusBanner: View {
    let status: ShortcutCaptureStatus
    let onRefresh: () -> Void

    private var tint: Color {
        if !status.accessibilityGranted {
            return .red
        }
        if status.standardShortcutsReady && status.hyperShortcutsReady {
            return .green
        }
        return .orange
    }

    private var title: String {
        if !status.accessibilityGranted {
            return "Accessibility permission required"
        }
        if !status.inputMonitoringRequired && status.standardShortcutsReady {
            return "Standard shortcuts ready"
        }
        if status.standardShortcutsReady && status.hyperShortcutsReady {
            return "Shortcut capture ready"
        }
        if status.standardShortcutsReady {
            return "Standard shortcuts ready"
        }
        return "Shortcut capture needs attention"
    }

    private var detail: String {
        status.bannerDetail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                Spacer()
                Button("Refresh") { onRefresh() }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if let guidance = status.systemSettingsGuidance {
                    Text(guidance)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(tint.opacity(0.2), lineWidth: 1)
        )
    }
}
