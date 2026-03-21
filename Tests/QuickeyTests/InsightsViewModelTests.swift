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
