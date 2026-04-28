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

    var summaryRangeText: String {
        switch self {
        case .day: "today"
        case .week: "in the past 7 days"
        case .month: "in the past 30 days"
        }
    }
}

struct RankedShortcut: Identifiable {
    let id: UUID
    let appName: String
    let bundleIdentifier: String
    let count: Int
}

struct InsightsAppRowModel: Identifiable, Equatable {
    let id: UUID
    let appName: String
    let bundleIdentifier: String
    let count: Int
    let progress: Double
    let delta: InsightsChange
    let sparklinePoints: [Int]
}

@Observable @MainActor
final class InsightsViewModel {
    var period: InsightsPeriod = .week {
        didSet { scheduleRefresh() }
    }
    var totalCount: Int = 0
    var previousPeriodTotal: Int = 0
    var currentStreakDays: Int = 0
    var activationSparklinePoints: [Int] = []
    var heatmapBuckets: [HourlyUsageBucket] = []
    var unusedShortcutNames: [String] = []
    var ranking: [RankedShortcut] = []
    var appRows: [InsightsAppRowModel] = []

    private let usageTracker: (any UsageTracking)?
    private let shortcutStore: ShortcutStore
    private let nowProvider: @Sendable () -> Date
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    init(
        usageTracker: (any UsageTracking)?,
        shortcutStore: ShortcutStore,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.usageTracker = usageTracker
        self.shortcutStore = shortcutStore
        self.nowProvider = nowProvider
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

    func waitForRefreshForTesting() async {
        await refreshTask?.value
    }

    private func doRefresh(for period: InsightsPeriod, generation: UInt64) async {
        let now = nowProvider()

        guard let usageTracker else {
            guard generation == refreshGeneration else { return }
            totalCount = 0
            previousPeriodTotal = 0
            currentStreakDays = 0
            activationSparklinePoints = []
            heatmapBuckets = []
            unusedShortcutNames = []
            ranking = []
            appRows = []
            return
        }

        let days = period.days
        let appSparklineDays = max(days, 7)
        let reportingTimeZone = await usageTracker.usageTimeZone()
        let previousReference = UsageWindowMath.previousWindowReference(
            days: days,
            relativeTo: now,
            in: reportingTimeZone
        )

        async let totalCountResult = usageTracker.totalSwitches(days: days, relativeTo: now)
        async let previousPeriodTotalResult = usageTracker.previousPeriodTotal(days: days, relativeTo: now)
        async let countsResult = usageTracker.usageCounts(days: days, relativeTo: now)
        async let previousCountsResult = usageTracker.usageCounts(days: days, relativeTo: previousReference)
        async let dailyCountsResult = usageTracker.dailyCounts(days: appSparklineDays, relativeTo: now)
        async let hourlyCountsResult = usageTracker.hourlyCounts(days: days, relativeTo: now)
        async let heatmapBucketsResult = usageTracker.hourlyCounts(days: 7, relativeTo: now)
        async let unusedCountsResult = usageTracker.usageCounts(days: 7, relativeTo: now)
        async let streakResult = usageTracker.streakDays(relativeTo: now)

        let totalCount = await totalCountResult
        let previousPeriodTotal = await previousPeriodTotalResult
        let counts = await countsResult
        let previousCounts = await previousCountsResult
        let dailyCounts = await dailyCountsResult
        let hourlyCounts = await hourlyCountsResult
        let heatmapBuckets = await heatmapBucketsResult
        let unusedCounts = await unusedCountsResult
        let streakDays = await streakResult
        let shortcuts = shortcutStore.shortcuts
        let shortcutMap = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.id, $0) })

        guard !Task.isCancelled else { return }
        guard generation == refreshGeneration else { return }

        self.totalCount = totalCount
        self.previousPeriodTotal = previousPeriodTotal
        self.currentStreakDays = streakDays
        self.activationSparklinePoints = Self.activationSparklinePoints(
            for: period,
            hourlyCounts: hourlyCounts
        )
        self.heatmapBuckets = heatmapBuckets
        self.unusedShortcutNames = shortcuts
            .filter(\.isEnabled)
            .filter { (unusedCounts[$0.id] ?? 0) == 0 }
            .map(\.appName)

        var ranked: [RankedShortcut] = []
        for (id, count) in counts {
            guard let shortcut = shortcutMap[id] else { continue }
            ranked.append(
                RankedShortcut(
                    id: id,
                    appName: shortcut.appName,
                    bundleIdentifier: shortcut.bundleIdentifier,
                    count: count
                )
            )
        }
        ranked.sort {
            if $0.count == $1.count {
                return $0.appName.localizedStandardCompare($1.appName) == .orderedAscending
            }

            return $0.count > $1.count
        }
        ranking = ranked

        let maxCount = max(ranked.map(\.count).max() ?? 0, 1)
        appRows = ranked.map { item in
            let sparklinePoints = Self.sparklinePoints(
                for: item.id.uuidString,
                days: appSparklineDays,
                relativeTo: now,
                timeZone: reportingTimeZone,
                dailyCounts: dailyCounts
            )

            return InsightsAppRowModel(
                id: item.id,
                appName: item.appName,
                bundleIdentifier: item.bundleIdentifier,
                count: item.count,
                progress: Double(item.count) / Double(maxCount),
                delta: InsightsChange.make(
                    current: item.count,
                    previous: previousCounts[item.id] ?? 0
                ),
                sparklinePoints: sparklinePoints
            )
        }
    }

    private static func activationSparklinePoints(
        for period: InsightsPeriod,
        hourlyCounts: [HourlyUsageBucket]
    ) -> [Int] {
        switch period {
        case .day:
            return hourlyCounts.map(\.count)
        case .week, .month:
            let grouped = Dictionary(grouping: hourlyCounts, by: \.date)
            let orderedDates = hourlyCounts.reduce(into: [String]()) { dates, bucket in
                if dates.last != bucket.date {
                    dates.append(bucket.date)
                }
            }

            return orderedDates.map { date in
                grouped[date, default: []].reduce(0) { partialResult, bucket in
                    partialResult + bucket.count
                }
            }
        }
    }

    private static func sparklinePoints(
        for shortcutID: String,
        days: Int,
        relativeTo now: Date,
        timeZone: TimeZone,
        dailyCounts: [String: [(date: String, count: Int)]]
    ) -> [Int] {
        let keys = dateKeys(days: days, relativeTo: now, timeZone: timeZone)
        let countsByDate = Dictionary(
            uniqueKeysWithValues: dailyCounts[shortcutID, default: []].map { ($0.date, $0.count) }
        )

        return keys.map { countsByDate[$0] ?? 0 }
    }

    private static func dateKeys(days: Int, relativeTo now: Date, timeZone: TimeZone) -> [String] {
        let window = UsageWindowMath.windowDates(days: days, relativeTo: now, in: timeZone)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone

        return window.days.map { date in
            formatter.string(from: date)
        }
    }
}
