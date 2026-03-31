import Foundation
import Observation

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
    let bundleIdentifier: String
    let count: Int
    let rank: Int
}

@Observable @MainActor
final class InsightsViewModel {
    var period: InsightsPeriod = .week {
        didSet { scheduleRefresh() }
    }
    var totalCount: Int = 0
    var bars: [DailyBar] = []
    var ranking: [RankedShortcut] = []

    private let usageTracker: (any UsageTracking)?
    private let shortcutStore: ShortcutStore
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    init(usageTracker: (any UsageTracking)?, shortcutStore: ShortcutStore) {
        self.usageTracker = usageTracker
        self.shortcutStore = shortcutStore
    }

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let selectedPeriod = period
        refreshTask = Task { @MainActor [weak self] in
            await self?.doRefresh(for: selectedPeriod, generation: generation)
        }
    }

    func refresh() async {
        refreshGeneration &+= 1
        await doRefresh(for: period, generation: refreshGeneration)
    }

    func refresh(for period: InsightsPeriod) async {
        refreshGeneration &+= 1
        await doRefresh(for: period, generation: refreshGeneration)
    }

    private func doRefresh(for period: InsightsPeriod, generation: UInt64) async {
        let now = Date()

        guard let usageTracker else {
            guard generation == refreshGeneration else { return }
            totalCount = 0
            bars = []
            ranking = []
            return
        }

        let days = period.days
        async let totalCountResult = usageTracker.totalSwitches(days: days, relativeTo: now)
        async let rawDailyResult = usageTracker.dailyCounts(days: days, relativeTo: now)
        async let countsResult = usageTracker.usageCounts(days: days, relativeTo: now)

        let totalCount = await totalCountResult
        let rawDaily = await rawDailyResult
        let counts = await countsResult
        let shortcuts = shortcutStore.shortcuts
        let shortcutMap = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.id, $0) })

        guard !Task.isCancelled else { return }
        guard generation == refreshGeneration else { return }

        self.totalCount = totalCount
        bars = period == .day ? [] : buildBars(rawDaily: rawDaily, days: days, relativeTo: now)

        var ranked: [RankedShortcut] = []
        for (id, count) in counts {
            guard let shortcut = shortcutMap[id] else { continue }
            ranked.append(RankedShortcut(id: id, appName: shortcut.appName, bundleIdentifier: shortcut.bundleIdentifier, count: count, rank: 0))
        }
        ranked.sort { $0.count > $1.count }
        ranking = ranked.enumerated().map {
            RankedShortcut(id: $1.id, appName: $1.appName, bundleIdentifier: $1.bundleIdentifier, count: $1.count, rank: $0 + 1)
        }
    }

    private func buildBars(
        rawDaily: [String: [(date: String, count: Int)]],
        days: Int,
        relativeTo now: Date
    ) -> [DailyBar] {
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
        for i in stride(from: days - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -i, to: now) else { continue }
            let dateStr = formatter.string(from: date)
            let label = labelFormatter.string(from: date)
            let count = dateTotals[dateStr] ?? 0
            result.append(DailyBar(id: dateStr, label: label, count: count))
        }
        return result
    }
}
