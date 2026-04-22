import SwiftUI

enum InsightsTabCopy {
    static let rankingSectionTitle = "Most used"
    static let emptyRankingText = "No shortcuts used in this period"
}

struct InsightsTabView: View {
    @Environment(\.winkPalette) private var palette

    @Bindable var viewModel: InsightsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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

                WinkCard(
                    title: {
                        Text(InsightsTabCopy.rankingSectionTitle)
                    },
                    accessory: {
                        Text("\(viewModel.totalCount.formatted(.number.grouping(.automatic))) activations")
                            .font(WinkType.labelSmall)
                            .foregroundStyle(palette.textTertiary)
                    }
                ) {
                    if viewModel.ranking.isEmpty {
                        Text(InsightsTabCopy.emptyRankingText)
                            .font(WinkType.bodyText)
                            .foregroundStyle(palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 18)
                    } else {
                        let maxCount = max(viewModel.ranking.map(\.count).max() ?? 0, 1)

                        VStack(spacing: 0) {
                            ForEach(Array(viewModel.ranking.enumerated()), id: \.element.id) { index, item in
                                InsightsRankingRow(
                                    item: item,
                                    maxCount: maxCount,
                                    showsDivider: index < viewModel.ranking.count - 1
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .background(palette.windowBg)
    }
}

private struct InsightsRankingRow: View {
    @Environment(\.winkPalette) private var palette

    let item: RankedShortcut
    let maxCount: Int
    let showsDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppIconView(bundleIdentifier: item.bundleIdentifier, size: 30)

                Text(item.appName)
                    .font(WinkType.bodyMedium)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .frame(minWidth: 110, alignment: .leading)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(palette.accentBgSoft)

                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(palette.accent)
                            .frame(width: filledWidth(totalWidth: geometry.size.width))
                    }
                }
                .frame(height: 12)

                Text(item.count.formatted(.number.grouping(.automatic)))
                    .font(WinkType.monoBadge)
                    .foregroundStyle(palette.textSecondary)
                    .frame(minWidth: 48, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if showsDivider {
                Divider()
                    .overlay(palette.hairline)
                    .padding(.leading, 56)
            }
        }
    }

    private func filledWidth(totalWidth: CGFloat) -> CGFloat {
        guard maxCount > 0 else { return 0 }
        let progress = max(CGFloat(item.count) / CGFloat(maxCount), 0)
        return max(totalWidth * progress, min(32, totalWidth))
    }
}
