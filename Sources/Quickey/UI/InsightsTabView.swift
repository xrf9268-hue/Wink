import SwiftUI

struct InsightsTabView: View {
    @Bindable var viewModel: InsightsViewModel

    var body: some View {
        VStack(spacing: 20) {
            // Period picker
            Picker("", selection: $viewModel.period) {
                ForEach(InsightsPeriod.allCases, id: \.self) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            // Headline
            VStack(spacing: 4) {
                Text(viewModel.period.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(viewModel.totalCount)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Text("app switches")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Trend chart (week/month only)
            if viewModel.period != .day {
                if viewModel.bars.allSatisfy({ $0.count == 0 }) {
                    Text("No usage data yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(height: 120)
                } else {
                    BarChartView(bars: viewModel.bars)
                        .frame(height: 120)
                }
            }

            // Ranking
            if viewModel.ranking.isEmpty {
                Spacer()
                Text("No shortcuts used in this period")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                CardView("Top Apps") {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.ranking.enumerated()), id: \.element.id) { index, item in
                            rankingRow(item, index: index)
                        }
                    }
                }
            }
        }
        .task { viewModel.scheduleRefresh() }
    }

    @ViewBuilder
    private func rankingRow(_ item: RankedShortcut, index: Int) -> some View {
        let maxCount = viewModel.ranking.first?.count ?? 1

        HStack(spacing: 10) {
            // Rank circle
            Text("\(item.rank)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(item.rank == 1 ? Color(red: 1, green: 0.84, blue: 0.04) : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    item.rank == 1
                        ? Color(red: 1, green: 0.84, blue: 0.04).opacity(0.15)
                        : Color.secondary.opacity(0.08)
                )
                .clipShape(Circle())

            AppIconView(bundleIdentifier: item.bundleIdentifier, size: 20)

            Text(item.appName)
                .font(.system(size: 13))

            Spacer()

            // Mini progress bar
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 60, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 60 * CGFloat(item.count) / CGFloat(max(maxCount, 1)), height: 4)
            }

            Text("\(item.count)×")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .alternatingRowBackground(index: index)
    }
}
