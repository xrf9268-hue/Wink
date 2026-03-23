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

struct AppIconView: View {
    let bundleIdentifier: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: resolveIcon())
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }

    private func resolveIcon() -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
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
    let ready: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ready ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(ready ? "Shortcut capture ready" : "Permissions required for global shortcuts")
                .font(.system(size: 12))
                .foregroundStyle(ready ? .green : .orange)
            Spacer()
            Button("Refresh") { onRefresh() }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background((ready ? Color.green : Color.orange).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke((ready ? Color.green : Color.orange).opacity(0.2), lineWidth: 1)
        )
    }
}
