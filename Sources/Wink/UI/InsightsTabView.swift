import Foundation
import SwiftUI

enum InsightsTabCopy {
    static var rankingSectionTitle: String {
        String(localized: "Most used", bundle: WinkResourceBundle.bundle)
    }
    static var emptyRankingText: String {
        String(localized: "No shortcuts used in this period", bundle: WinkResourceBundle.bundle)
    }

    static func rankingAccessoryText(totalCount: Int, period: InsightsPeriod) -> String {
        // The plural "%lld activations" phrase is resolved on its own so the
        // catalog's plural `variations` can pick "one" vs "other"; grouping
        // (thousands separator) is dropped for this compact composed form.
        let activations = String(localized: "\(totalCount) activations", bundle: WinkResourceBundle.bundle)
        return "\(activations) · \(compactRangeText(for: period))"
    }

    private static func compactRangeText(for period: InsightsPeriod) -> String {
        switch period {
        case .day:
            return String(localized: "today", bundle: WinkResourceBundle.bundle)
        case .week:
            return String(localized: "7 days", bundle: WinkResourceBundle.bundle)
        case .month:
            return String(localized: "30 days", bundle: WinkResourceBundle.bundle)
        }
    }
}

struct InsightsTabView: View {
    @Environment(\.winkPalette) private var palette

    @Bindable var viewModel: InsightsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            InsightsKpiSection(
                totalCount: viewModel.totalCount,
                previousPeriodTotal: viewModel.previousPeriodTotal,
                currentStreakDays: viewModel.currentStreakDays,
                sparklinePoints: viewModel.activationSparklinePoints
            )

            InsightsHourlyHeatmap(buckets: viewModel.heatmapBuckets)

            // The tab keeps the repo's one-scroller-per-surface contract
            // (see LayoutRegressionTests' scroller tests), but the region
            // now spans ranking + nudge + suggestions instead of the ranking
            // card alone: with the nudge AND a populated suggestions card,
            // the fixed blocks' natural heights exceeded the window and the
            // tail cards were silently clipped at the window edge (#393 —
            // the suggestions card showed 1.5 of its 3 rows). Header, KPIs,
            // and heatmap stay fixed; everything below shares the scroller,
            // so every card is always reachable at any window height.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    mostUsedCard

                    InsightsUnusedNudge(appNames: viewModel.unusedShortcutNames)

                    suggestedShortcutsCard
                }
            }
            .scrollIndicators(.automatic, axes: .vertical)
            // The 140pt floor carries over from the pre-#393 ranking region:
            // at compact window heights the fixed blocks above would
            // otherwise compress this flexible region to zero, leaving the
            // tail cards neither visible nor scrollable.
            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 18)
        .padding(.bottom, 22)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.windowBg)
    }

    @ViewBuilder
    private var suggestedShortcutsCard: some View {
        if !viewModel.suggestedApps.isEmpty {
            WinkCard(title: { Text("Suggested shortcuts", bundle: WinkResourceBundle.bundle) }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Apps you switch to often that have no shortcut yet. Add one in Shortcuts.", bundle: WinkResourceBundle.bundle)
                            .font(WinkType.labelSmall)
                            .foregroundStyle(palette.textSecondary)
                        ForEach(viewModel.suggestedApps) { suggestion in
                            HStack(spacing: 8) {
                                AppIconView(bundleIdentifier: suggestion.bundleIdentifier, size: 20)
                                Text(suggestion.name)
                                    .font(WinkType.bodyText)
                                    .foregroundStyle(palette.textPrimary)
                                Spacer(minLength: 8)
                                Text("\(suggestion.count)× this period", bundle: WinkResourceBundle.bundle)
                                    .font(WinkType.labelSmall)
                                    .foregroundStyle(palette.textTertiary)
                            }
                        }
                    }
                    // WinkCard pads only its title row; content insets are
                    // each caller's job (cf. the ranking card's empty state)
                    // — omitting them here is what glued the subtitle to the
                    // divider and the count labels to the card edge (#393).
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Insights", bundle: WinkResourceBundle.bundle)
                    .font(WinkType.tabTitle)
                    .foregroundStyle(palette.textPrimary)
                Text("Usage trends for your saved shortcuts.", bundle: WinkResourceBundle.bundle)
                    .font(WinkType.bodyText)
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer(minLength: 8)

            WinkSegmented(
                options: InsightsPeriod.allCases.map { (label: $0.segmentLabel, value: $0) },
                selection: $viewModel.period,
                accessibilityLabel: String(localized: "Insights period", bundle: WinkResourceBundle.bundle)
            )
        }
    }

    private var mostUsedCard: some View {
        WinkCard(
            title: {
                Text(InsightsTabCopy.rankingSectionTitle)
            },
            accessory: {
                Text(InsightsTabCopy.rankingAccessoryText(totalCount: viewModel.totalCount, period: viewModel.period))
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textTertiary)
            }
        ) {
            if viewModel.appRows.isEmpty {
                Text(InsightsTabCopy.emptyRankingText)
                    .font(WinkType.bodyText)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)
            } else {
                // Full-flow rows, no internal ScrollView: the surrounding
                // region scroller in `body` is the tab's single scroller
                // (LayoutRegressionTests pins that contract), and the row
                // count is bounded by the shortcut count. Plain VStack, not
                // Lazy — every row participates in the region's layout.
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.appRows.enumerated()), id: \.element.id) { index, item in
                        InsightsAppRow(
                            item: item,
                            showsDivider: index < viewModel.appRows.count - 1
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
