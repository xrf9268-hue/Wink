import Foundation
import SwiftUI

enum InsightsChangeTone: Equatable {
    case positive
    case negative
    case neutral
}

struct InsightsChange: Equatable {
    // `kind` drives comparisons (e.g. `activationSubtitle` below); `text` is
    // display-only and localized, so it must never be switched/compared on —
    // that would silently break once it stops being English (issue #358).
    enum Kind: Equatable {
        case noChange
        case newActivity
        case percentage
    }

    let text: String
    let tone: InsightsChangeTone
    let kind: Kind

    static func make(current: Int, previous: Int) -> InsightsChange {
        if previous == 0 {
            if current == 0 {
                return InsightsChange(
                    text: String(localized: "No change", bundle: WinkResourceBundle.bundle),
                    tone: .neutral,
                    kind: .noChange
                )
            }

            return InsightsChange(
                text: String(localized: "New activity", bundle: WinkResourceBundle.bundle),
                tone: .positive,
                kind: .newActivity
            )
        }

        let delta = Double(current - previous) / Double(previous)
        let percentage = Int((delta * 100).rounded())
        if percentage == 0 {
            // "0%" is a bare numeric+symbol value, not linguistic content.
            return InsightsChange(text: "0%", tone: .neutral, kind: .percentage)
        }

        let prefix = percentage > 0 ? "+" : ""
        let tone: InsightsChangeTone = percentage > 0 ? .positive : .negative
        return InsightsChange(text: "\(prefix)\(percentage)%", tone: tone, kind: .percentage)
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
        switch change.kind {
        case .newActivity:
            return String(localized: "New activity versus the previous period.", bundle: WinkResourceBundle.bundle)
        case .noChange:
            return String(localized: "No change versus the previous period.", bundle: WinkResourceBundle.bundle)
        case .percentage:
            return String(localized: "\(change.text) versus the previous period.", bundle: WinkResourceBundle.bundle)
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
                    InsightsKpiDelta(change: activationDelta)
                },
                bottom: {
                    WinkSparkline(
                        points: sparklinePoints,
                        stroke: palette.accent,
                        fill: palette.accentBgSoft
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
                    .font(WinkType.labelSmall.weight(.medium))
                    .foregroundStyle(palette.textSecondary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(WinkType.kpiValue)
                        .tracking(-0.6)
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    badge()
                }
                .padding(.top, 5)

                Text(subtitle)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textTertiary)
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

/// Plain-text delta used for the headline Activations KPI, matching
/// tab-insights.jsx's unadorned `{delta}` span (no icon, no capsule).
struct InsightsKpiDelta: View {
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

    var body: some View {
        Text(change.text)
            .font(WinkType.captionStrong)
            .foregroundStyle(foreground)
    }
}

/// Pill-style change badge. Not currently used by the Insights KPI row
/// (see `InsightsKpiDelta`) — kept for other, explicitly-designed badge uses.
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
