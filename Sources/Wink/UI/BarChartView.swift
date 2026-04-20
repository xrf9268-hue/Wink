import SwiftUI

struct BarChartView: View {
    let bars: [DailyBar]

    var body: some View {
        let maxCount = bars.map(\.count).max() ?? 1
        let ceiling = max(maxCount, 1)

        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(bars) { bar in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(bar.count > 0 ? Color.accentColor : Color.secondary.opacity(0.2))
                            .frame(height: max(geo.size.height * 0.05, geo.size.height * 0.85 * CGFloat(bar.count) / CGFloat(ceiling)))

                        Text(bar.label)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
