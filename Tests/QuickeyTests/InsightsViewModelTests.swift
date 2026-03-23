import Foundation
import Testing
@testable import Quickey

actor DelayedUsageTracker: UsageTracking {
    let shortcutId: UUID

    init(shortcutId: UUID) {
        self.shortcutId = shortcutId
    }

    func usageCounts(days: Int) async -> [UUID: Int] {
        try? await Task.sleep(for: .milliseconds(days == 30 ? 80 : 5))
        return [shortcutId: days]
    }

    func dailyCounts(days: Int) async -> [String: [(date: String, count: Int)]] {
        try? await Task.sleep(for: .milliseconds(days == 30 ? 80 : 5))
        return [:]
    }

    func totalSwitches(days: Int) async -> Int {
        try? await Task.sleep(for: .milliseconds(days == 30 ? 80 : 5))
        return days
    }

    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] {
        await usageCounts(days: days)
    }

    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] {
        await dailyCounts(days: days)
    }

    func totalSwitches(days: Int, relativeTo now: Date) async -> Int {
        await totalSwitches(days: days)
    }
}

actor BoundaryCrossingUsageTracker: UsageTracking {
    let shortcutId: UUID

    init(shortcutId: UUID) {
        self.shortcutId = shortcutId
    }

    func usageCounts(days: Int) async -> [UUID: Int] {
        [shortcutId: 1]
    }

    func dailyCounts(days: Int) async -> [String: [(date: String, count: Int)]] {
        [shortcutId.uuidString: [(date: dateString(for: Date().addingTimeInterval(86_400)), count: 1)]]
    }

    func totalSwitches(days: Int) async -> Int {
        1
    }

    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] {
        [shortcutId: 1]
    }

    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] {
        [shortcutId.uuidString: [(date: dateString(for: now), count: 1)]]
    }

    func totalSwitches(days: Int, relativeTo now: Date) async -> Int {
        1
    }
}

@Test @MainActor
func latestPeriodWinsWhenRefreshesOverlap() async {
    let shortcutId = UUID()
    let store = ShortcutStore()
    store.replaceAll(with: [
        AppShortcut(
            id: shortcutId,
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t",
            modifierFlags: ["command"]
        )
    ])

    let viewModel = InsightsViewModel(
        usageTracker: DelayedUsageTracker(shortcutId: shortcutId),
        shortcutStore: store
    )

    viewModel.period = .month
    viewModel.period = .day

    try? await Task.sleep(for: .milliseconds(150))

    #expect(viewModel.period == .day)
    #expect(viewModel.totalCount == 1)
    #expect(viewModel.ranking.first?.id == shortcutId)
    #expect(viewModel.ranking.first?.count == 1)
}

@Test @MainActor
func refreshUsesOneAnchorDateForQueriesAndBars() async {
    let shortcutId = UUID()
    let store = ShortcutStore()
    store.replaceAll(with: [
        AppShortcut(
            id: shortcutId,
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t",
            modifierFlags: ["command"]
        )
    ])

    let viewModel = InsightsViewModel(
        usageTracker: BoundaryCrossingUsageTracker(shortcutId: shortcutId),
        shortcutStore: store
    )

    await viewModel.refresh(for: .week)

    #expect(viewModel.totalCount == 1)
    #expect(viewModel.ranking.first?.count == 1)
    #expect(viewModel.bars.reduce(0) { $0 + $1.count } == 1)
    #expect(viewModel.bars.last?.count == 1)
}

private func dateString(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = .current
    return formatter.string(from: date)
}
