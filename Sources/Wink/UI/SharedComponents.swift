import SwiftUI

struct SettingsTabHeader<Trailing: View>: View {
    @Environment(\.winkPalette) private var palette

    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(WinkType.tabTitle)
                    .tracking(-0.3)
                    .foregroundStyle(palette.textPrimary)
                Text(subtitle)
                    .font(WinkType.tabSubtitle)
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer(minLength: 8)
            trailing()
        }
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
