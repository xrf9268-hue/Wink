import SwiftUI

enum InsightsTabCopy {
    static let rankingSectionTitle = "Most used"
    static let emptyRankingText = "No shortcuts used in this period"

    static func rankingAccessoryText(totalCount: Int, period: InsightsPeriod) -> String {
        "\(totalCount.formatted(.number.grouping(.automatic))) activations · \(compactRangeText(for: period))"
    }

    private static func compactRangeText(for period: InsightsPeriod) -> String {
        switch period {
        case .day:
            return "today"
        case .week:
            return "7 days"
        case .month:
            return "30 days"
        }
    }
}

struct InsightsTabView: View {
    @Environment(\.winkPalette) private var palette

    @Bindable var viewModel: InsightsViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header

                InsightsUnusedNudge(appNames: viewModel.unusedShortcutNames)

                InsightsKpiSection(
                    totalCount: viewModel.totalCount,
                    previousPeriodTotal: viewModel.previousPeriodTotal,
                    currentStreakDays: viewModel.currentStreakDays,
                    sparklinePoints: viewModel.activationSparklinePoints
                )

                InsightsHourlyHeatmap(buckets: viewModel.heatmapBuckets)

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
                        VStack(spacing: 0) {
                            ForEach(Array(viewModel.appRows.enumerated()), id: \.element.id) { index, item in
                                InsightsAppRow(
                                    item: item,
                                    showsDivider: index < viewModel.appRows.count - 1
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(palette.windowBg)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Insights")
                    .font(WinkType.tabTitle)
                    .foregroundStyle(palette.textPrimary)
                Text("Usage trends for your saved shortcuts.")
                    .font(WinkType.bodyText)
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer(minLength: 8)

            Picker("", selection: $viewModel.period) {
                ForEach(InsightsPeriod.allCases, id: \.self) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .labelsHidden()
        }
    }
}
