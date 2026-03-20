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
                List(viewModel.ranking) { item in
                    HStack {
                        Text("#\(item.rank)")
                            .font(.system(.body, design: .rounded).bold())
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .leading)
                        Text(item.appName)
                        Spacer()
                        Text("\(item.count)×")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task { await viewModel.refresh() }
    }
}
