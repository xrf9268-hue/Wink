import SwiftUI

private enum InsightsAppRowLayout {
    static let iconSize: CGFloat = 28
    static let rowVerticalPadding: CGFloat = 10
    static let progressHeight: CGFloat = 5
    static let progressCornerRadius: CGFloat = 3
    static let sparklineWidth: CGFloat = 80
    static let sparklineHeight: CGFloat = 24
    static let countMinWidth: CGFloat = 28
}

struct InsightsAppRow: View {
    @Environment(\.winkPalette) private var palette

    let item: InsightsAppRowModel
    let showsDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppIconView(bundleIdentifier: item.bundleIdentifier, size: InsightsAppRowLayout.iconSize)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.appName)
                            .font(WinkType.bodyMedium)
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)

                        if item.count == 0 {
                            Text("unused", bundle: WinkResourceBundle.bundle)
                                .font(WinkType.labelSmall.weight(.semibold))
                                .foregroundStyle(palette.textTertiary)
                        } else if item.delta.tone != .neutral {
                            InsightsInlineChangeLabel(change: item.delta)
                        }
                    }

                    progressBar
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                WinkSparkline(
                    points: item.sparklinePoints,
                    stroke: item.count == 0 ? palette.textTertiary : palette.accent,
                    fill: item.count == 0 ? .clear : palette.accentBgSoft
                )
                .frame(width: InsightsAppRowLayout.sparklineWidth, height: InsightsAppRowLayout.sparklineHeight)

                Text(item.count.formatted(.number.grouping(.automatic)))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.textPrimary)
                    .frame(minWidth: InsightsAppRowLayout.countMinWidth, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, InsightsAppRowLayout.rowVerticalPadding)
            .opacity(item.count == 0 ? 0.62 : 1)

            if showsDivider {
                Divider()
                    .overlay(palette.hairline)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: InsightsAppRowLayout.progressCornerRadius, style: .continuous)
                    .fill(palette.progressTrackBg)

                if item.count > 0 {
                    RoundedRectangle(cornerRadius: InsightsAppRowLayout.progressCornerRadius, style: .continuous)
                        .fill(palette.accent)
                        .frame(width: max(geometry.size.width * item.progress, 2))
                }
            }
        }
        .frame(height: InsightsAppRowLayout.progressHeight)
    }
}

private struct InsightsInlineChangeLabel: View {
    @Environment(\.winkPalette) private var palette

    let change: InsightsChange

    private var foreground: Color {
        switch change.tone {
        case .positive:
            return palette.green
        case .negative:
            return palette.red
        case .neutral:
            return palette.textTertiary
        }
    }

    private var systemImage: String {
        switch change.tone {
        case .positive:
            return "arrow.up"
        case .negative:
            return "arrow.down"
        case .neutral:
            return "minus"
        }
    }

    private var displayText: String {
        if change.tone == .negative, change.text.hasPrefix("-") {
            return String(change.text.dropFirst())
        }
        return change.text
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
            Text(displayText)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(foreground)
        .lineLimit(1)
    }
}
