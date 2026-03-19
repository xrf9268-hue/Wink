import Foundation

enum InsightsPeriod: String, CaseIterable {
    case day = "D"
    case week = "W"
    case month = "M"

    var days: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        }
    }

    var label: String {
        switch self {
        case .day: "Today"
        case .week: "Past 7 Days"
        case .month: "Past 30 Days"
        }
    }
}

struct DailyBar: Identifiable {
    let id: String // date string
    let label: String
    let count: Int
}

struct RankedShortcut: Identifiable {
    let id: UUID
    let appName: String
    let count: Int
    let rank: Int
}

@MainActor
final class InsightsViewModel: ObservableObject {
    @Published var period: InsightsPeriod = .week {
        didSet { Task { await refresh() } }
    }
    @Published var totalCount: Int = 0
    @Published var bars: [DailyBar] = []
    @Published var ranking: [RankedShortcut] = []

    private let usageTracker: UsageTracker?
    private let shortcutStore: ShortcutStore

    init(usageTracker: UsageTracker?, shortcutStore: ShortcutStore) {
        self.usageTracker = usageTracker
        self.shortcutStore = shortcutStore
    }

    func refresh() async {
        guard let usageTracker else { return }

        let days = period.days
        totalCount = await usageTracker.totalSwitches(days: days)

        // Build bars (zero-filled) for week/month
        if period != .day {
            let rawDaily = await usageTracker.dailyCounts(days: days)
            bars = buildBars(rawDaily: rawDaily, days: days)
        } else {
            bars = []
        }

        // Build ranking
        let counts = await usageTracker.usageCounts(days: days)
        let shortcuts = shortcutStore.shortcuts
        let shortcutMap = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.id, $0) })

        var ranked: [RankedShortcut] = []
        for (id, count) in counts {
            guard let shortcut = shortcutMap[id] else { continue }
            ranked.append(RankedShortcut(id: id, appName: shortcut.appName, count: count, rank: 0))
        }
        ranked.sort { $0.count > $1.count }
        ranking = ranked.enumerated().map {
            RankedShortcut(id: $1.id, appName: $1.appName, count: $1.count, rank: $0 + 1)
        }
    }

    private func buildBars(rawDaily: [String: [(date: String, count: Int)]], days: Int) -> [DailyBar] {
        // Aggregate across all shortcuts per date
        var dateTotals: [String: Int] = [:]
        for (_, entries) in rawDaily {
            for entry in entries {
                dateTotals[entry.date, default: 0] += entry.count
            }
        }

        // Generate zero-filled date range
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        let labelFormatter = DateFormatter()
        labelFormatter.dateFormat = days <= 7 ? "EEE" : "M/d"
        labelFormatter.timeZone = .current

        var result: [DailyBar] = []
        let today = Date()
        for i in stride(from: days - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -i, to: today) else { continue }
            let dateStr = formatter.string(from: date)
            let label = labelFormatter.string(from: date)
            let count = dateTotals[dateStr] ?? 0
            result.append(DailyBar(id: dateStr, label: label, count: count))
        }
        return result
    }
}
