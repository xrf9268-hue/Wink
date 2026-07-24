import AppKit
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

    /// Display-only label for the period segmented control. `rawValue`
    /// ("D"/"W"/"M") stays the plain Latin option identifier used
    /// internally by `WinkSegmented`'s selection binding — this is what
    /// actually renders on screen, localized (matching Apple's own Screen
    /// Time-style compact period abbreviations).
    var segmentLabel: String {
        switch self {
        case .day: String(localized: "D", bundle: WinkResourceBundle.bundle)
        case .week: String(localized: "W", bundle: WinkResourceBundle.bundle)
        case .month: String(localized: "M", bundle: WinkResourceBundle.bundle)
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
    struct SuggestedApp: Equatable, Identifiable {
        let bundleIdentifier: String
        let name: String
        let count: Int
        var id: String { bundleIdentifier }
    }
    /// Top unbound apps by foreground activations in the period. Empty when
    /// collection is disabled (the toggle also clears the data), so the
    /// card simply disappears — no preference plumbing needed here.
    var suggestedApps: [SuggestedApp] = []
    var appRows: [InsightsAppRowModel] = []

    private let usageTracker: (any UsageTracking)?
    private let shortcutStore: ShortcutStore
    private let nowProvider: @Sendable () -> Date
    private let appURLResolver: (String) -> URL?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    // appURLResolver defaults to nil and resolves in the body — CI's Swift
    // 6.1.2 SILGen crashes on non-trivial init default arguments.
    init(
        usageTracker: (any UsageTracking)?,
        shortcutStore: ShortcutStore,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        appURLResolver: ((String) -> URL?)? = nil
    ) {
        self.usageTracker = usageTracker
        self.shortcutStore = shortcutStore
        self.nowProvider = nowProvider
        self.appURLResolver = appURLResolver ?? { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
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

    /// Selects `period` and awaits the resulting refresh. Drives the same
    /// task-tracked, last-selection-wins mechanism as the period picker, so a
    /// concurrent `scheduleRefresh()` can cancel and supersede this refresh.
    func refresh(for period: InsightsPeriod) async {
        self.period = period  // didSet calls scheduleRefresh()
        await refreshTask?.value
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
            suggestedApps = []
            return
        }

        let days = period.days
        let appSparklineDays = max(days, 7)
        let request = UsageDashboardRequest(
            days: days,
            sparklineDays: appSparklineDays,
            referenceDate: now
        )

        // One coherent snapshot from one read boundary; nil means the refresh
        // was cancelled mid-flight and a superseding refresh owns the UI.
        guard let snapshot = await usageTracker.dashboardSnapshot(for: request) else {
            return
        }

        let boundBundles = Set(shortcutStore.shortcuts.map(\.bundleIdentifier))
        let activationTotals = await usageTracker.appActivationTotals(days: days, relativeTo: now)
        // Resolve BEFORE limiting: an uninstalled app in the top three must
        // yield its slot to the next resolvable one, not shrink the card.
        let suggestions: [SuggestedApp] = Array(activationTotals
            .filter { !boundBundles.contains($0.bundleIdentifier) }
            .compactMap { entry -> SuggestedApp? in
                guard let url = appURLResolver(entry.bundleIdentifier) else {
                    // Uninstalled or un-resolvable apps make poor suggestions.
                    return nil
                }
                guard AppSuggestionEligibility.isSuggestable(appURL: url) else {
                    // Rows recorded before the record-time policy gate (or
                    // by an older build) can name system dialogs like
                    // universalAccessAuthWarn; app_activations has no
                    // age-out, so they must be dropped here.
                    return nil
                }
                return SuggestedApp(
                    bundleIdentifier: entry.bundleIdentifier,
                    name: url.deletingPathExtension().lastPathComponent,
                    count: entry.count
                )
            }
            .prefix(3))

        let reportingTimeZone = snapshot.timeZone
        let dailyCounts = snapshot.dailyCounts
        let previousCounts = snapshot.previousCounts
        let shortcuts = shortcutStore.shortcuts
        let shortcutMap = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.id, $0) })

        guard !Task.isCancelled else { return }
        guard generation == refreshGeneration else { return }

        self.suggestedApps = suggestions
        self.totalCount = snapshot.totalCount
        self.previousPeriodTotal = snapshot.previousPeriodTotal
        self.currentStreakDays = snapshot.streakDays
        self.activationSparklinePoints = Self.activationSparklinePoints(
            for: period,
            hourlyCounts: snapshot.hourlyCounts
        )
        self.heatmapBuckets = snapshot.heatmapBuckets
        self.unusedShortcutNames = shortcuts
            .filter(\.isEnabled)
            // The #356 search-palette trigger never records per-shortcut
            // usage (see ShortcutManager.handleKeyPress — it dispatches
            // through onSearchPaletteTriggered, not trigger(_:)), so it
            // would otherwise always read as zero-count and get nudged for
            // removal even when the user opens the palette constantly.
            .filter { !$0.isSearchPaletteTarget }
            .filter { (snapshot.unusedCounts[$0.id] ?? 0) == 0 }
            .map(\.displayAppName)

        var ranked: [RankedShortcut] = []
        for (id, count) in snapshot.counts {
            guard let shortcut = shortcutMap[id] else { continue }
            ranked.append(
                RankedShortcut(
                    id: id,
                    appName: shortcut.displayAppName,
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
        let formatter = UsageWindowMath.dateKeyFormatter(timeZone: timeZone)

        return window.days.map { date in
            formatter.string(from: date)
        }
    }
}
