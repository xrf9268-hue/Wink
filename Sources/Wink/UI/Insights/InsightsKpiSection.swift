import SwiftUI

enum InsightsChangeTone: Equatable {
    case positive
    case negative
    case neutral
}

struct InsightsChange: Equatable {
    let text: String
    let tone: InsightsChangeTone

    static func make(current: Int, previous: Int) -> InsightsChange {
        if previous == 0 {
            if current == 0 {
                return InsightsChange(text: "No change", tone: .neutral)
            }

            return InsightsChange(text: "New activity", tone: .positive)
        }

        let delta = Double(current - previous) / Double(previous)
        let percentage = Int((delta * 100).rounded())
        if percentage == 0 {
            return InsightsChange(text: "0%", tone: .neutral)
        }

        let prefix = percentage > 0 ? "+" : ""
        let tone: InsightsChangeTone = percentage > 0 ? .positive : .negative
        return InsightsChange(text: "\(prefix)\(percentage)%", tone: tone)
    }
}

enum InsightsKpiFormatter {
    static func timeSavedText(totalActivations: Int) -> String {
        let totalSeconds = totalActivations * 3
        if totalSeconds >= 86_400 {
            let days = totalSeconds / 86_400
            let hours = (totalSeconds % 86_400) / 3_600
            return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
        }

        if totalSeconds >= 3_600 {
            let hours = totalSeconds / 3_600
            let minutes = (totalSeconds % 3_600) / 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }

        if totalSeconds >= 60 {
            return "\(totalSeconds / 60)m"
        }

        return "\(totalSeconds)s"
    }

    static func activationSubtitle(change: InsightsChange) -> String {
        switch change.text {
        case "New activity":
            return "New activity versus the previous period."
        case "No change":
            return "No change versus the previous period."
        default:
            return "\(change.text) versus the previous period."
        }
    }
}

private enum InsightsKpiLayout {
    static let cardMinHeight: CGFloat = 124
    static let bottomSlotHeight: CGFloat = 28
}

struct InsightsKpiSection: View {
    @Environment(\.winkPalette) private var palette

    let totalCount: Int
    let previousPeriodTotal: Int
    let currentStreakDays: Int
    let sparklinePoints: [Int]

    private var activationDelta: InsightsChange {
        InsightsChange.make(current: totalCount, previous: previousPeriodTotal)
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
            spacing: 12
        ) {
            metricCard(
                title: "Activations",
                value: totalCount.formatted(.number.grouping(.automatic)),
                subtitle: "vs previous period",
                help: InsightsKpiFormatter.activationSubtitle(change: activationDelta),
                badge: {
                    InsightsChangeBadge(change: activationDelta)
                },
                bottom: {
                    WinkSparkline(
                        points: sparklinePoints,
                        stroke: palette.accent,
                        fill: palette.accent.opacity(0.12)
                    )
                }
            )

            metricCard(
                title: "Time saved",
                value: InsightsKpiFormatter.timeSavedText(totalActivations: totalCount),
                subtitle: "~3 seconds each",
                help: "Assumes ~3 seconds per activation.",
                badge: {
                    EmptyView()
                },
                bottom: {
                    Color.clear
                }
            )

            metricCard(
                title: "Streak",
                value: "\(currentStreakDays)d",
                subtitle: "Consecutive active days",
                help: "Consecutive days with at least one activation.",
                badge: {
                    EmptyView()
                },
                bottom: {
                    Color.clear
                }
            )
        }
    }

    private func metricCard<Badge: View, Bottom: View>(
        title: String,
        value: String,
        subtitle: String,
        help: String,
        @ViewBuilder badge: @escaping () -> Badge,
        @ViewBuilder bottom: @escaping () -> Bottom
    ) -> some View {
        WinkCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textTertiary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    badge()
                }
                .padding(.top, 5)

                Text(subtitle)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .help(help)
                    .padding(.top, 4)

                Spacer(minLength: 8)

                bottom()
                    .frame(maxWidth: .infinity)
                    .frame(height: InsightsKpiLayout.bottomSlotHeight)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: InsightsKpiLayout.cardMinHeight, alignment: .topLeading)
        }
    }
}

struct InsightsChangeBadge: View {
    @Environment(\.winkPalette) private var palette

    let change: InsightsChange

    private var foreground: Color {
        switch change.tone {
        case .positive:
            return palette.green
        case .negative:
            return palette.red
        case .neutral:
            return palette.textSecondary
        }
    }

    private var background: Color {
        switch change.tone {
        case .positive:
            return palette.greenSoft
        case .negative:
            return palette.redBgSoft
        case .neutral:
            return palette.controlBgRest
        }
    }

    private var systemImage: String {
        switch change.tone {
        case .positive:
            return "arrow.up.right"
        case .negative:
            return "arrow.down.right"
        case .neutral:
            return "minus"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(change.text)
                .font(WinkType.labelSmall.weight(.semibold))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(background)
        .clipShape(Capsule())
    }
}
