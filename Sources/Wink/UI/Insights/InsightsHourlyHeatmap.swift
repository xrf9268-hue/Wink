import SwiftUI

private enum InsightsHeatmapLayout {
    static let dayLabelWidth: CGFloat = 32
    static let labelGridSpacing: CGFloat = 8
    static let columnSpacing: CGFloat = 2
    static let rowSpacing: CGFloat = 3
    static let cellHeight: CGFloat = 14
    static let cellCornerRadius: CGFloat = 2
}

struct InsightsHourlyHeatmap: View {
    @Environment(\.winkPalette) private var palette

    let buckets: [HourlyUsageBucket]

    private var groupedRows: [(date: String, counts: [Int])] {
        let orderedDates = buckets.reduce(into: [String]()) { dates, bucket in
            if dates.last != bucket.date {
                dates.append(bucket.date)
            }
        }
        let grouped = Dictionary(grouping: buckets, by: \.date)

        return orderedDates.map { date in
            let counts = (0..<24).map { hour in
                grouped[date, default: []].first(where: { $0.hour == hour })?.count ?? 0
            }
            return (date: date, counts: counts)
        }
    }

    private var maxCount: Int {
        max(buckets.map(\.count).max() ?? 0, 1)
    }

    var body: some View {
        WinkCard(
            title: {
                Text("Hourly heatmap")
            },
            accessory: {
                Text("Past 7 days")
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textTertiary)
            }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: InsightsHeatmapLayout.rowSpacing) {
                    ForEach(groupedRows, id: \.date) { row in
                        HStack(spacing: InsightsHeatmapLayout.labelGridSpacing) {
                            Text(dayLabel(for: row.date))
                                .font(WinkType.labelSmall)
                                .foregroundStyle(palette.textTertiary)
                                .textCase(.uppercase)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(width: InsightsHeatmapLayout.dayLabelWidth, alignment: .leading)

                            HStack(spacing: InsightsHeatmapLayout.columnSpacing) {
                                ForEach(Array(row.counts.enumerated()), id: \.offset) { _, count in
                                    RoundedRectangle(cornerRadius: InsightsHeatmapLayout.cellCornerRadius, style: .continuous)
                                        .fill(fill(for: count))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: InsightsHeatmapLayout.cellHeight)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                hourScale
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hourScale: some View {
        HStack(spacing: InsightsHeatmapLayout.labelGridSpacing) {
            Color.clear
                .frame(width: InsightsHeatmapLayout.dayLabelWidth)

            HStack(spacing: InsightsHeatmapLayout.columnSpacing) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hourLabel(for: hour))
                        .font(WinkType.labelSmall)
                        .foregroundStyle(palette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func fill(for count: Int) -> Color {
        guard count > 0 else {
            return palette.heatmapBase
        }

        let normalized = Double(count) / Double(maxCount)
        return palette.accent.opacity(0.18 + (normalized * 0.72))
    }

    private func dayLabel(for dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        guard let date = formatter.date(from: dateString) else {
            return dateString
        }

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.calendar = Calendar(identifier: .gregorian)
        weekdayFormatter.dateFormat = "EEE"
        weekdayFormatter.timeZone = .current
        return weekdayFormatter.string(from: date)
    }

    private func hourLabel(for hour: Int) -> String {
        guard hour % 3 == 0 else {
            return ""
        }

        if hour == 0 {
            return "12a"
        }
        if hour == 12 {
            return "12p"
        }
        if hour < 12 {
            return "\(hour)a"
        }
        return "\(hour - 12)p"
    }
}
