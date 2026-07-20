import Foundation
import Testing

@testable import Wink

@Suite("Usage dashboard snapshot")
struct UsageDashboardSnapshotTests {
    @Test
    func weekSnapshotExecutesEachLogicalDatasetAtMostOnce() async throws {
        let tracker = try await makeSeededTracker()
        let request = UsageDashboardRequest(
            days: 7,
            sparklineDays: 7,
            referenceDate: isoDateTime("2026-04-22T12:00:00Z")
        )

        let snapshot = try #require(await tracker.dashboardSnapshot(for: request))

        let executions = await tracker.queryExecutionCountsForTesting()
        // Current + previous period; the unused-shortcut dataset reuses the
        // current-period counts instead of a third query.
        #expect(executions["usageCounts"] == 2)
        // The 7-day heatmap reuses the period dataset instead of a second query.
        #expect(executions["hourlyCounts"] == 1)
        #expect(executions["totalSwitches"] == 1)
        #expect(executions["previousPeriodTotal"] == 1)
        #expect(executions["dailyCounts"] == 1)
        #expect(executions["streakDays"] == 1)

        #expect(snapshot.heatmapBuckets == snapshot.hourlyCounts)
        #expect(snapshot.unusedCounts == snapshot.counts)
    }

    @Test
    func monthSnapshotComputesSeparateSevenDayDatasets() async throws {
        let tracker = try await makeSeededTracker()
        let request = UsageDashboardRequest(
            days: 30,
            sparklineDays: 30,
            referenceDate: isoDateTime("2026-04-22T12:00:00Z")
        )

        _ = try #require(await tracker.dashboardSnapshot(for: request))

        let executions = await tracker.queryExecutionCountsForTesting()
        #expect(executions["usageCounts"] == 3)
        #expect(executions["hourlyCounts"] == 2)
    }

    @Test
    func snapshotValuesMatchIndividualQueries() async throws {
        let tracker = try await makeSeededTracker()
        let anchor = isoDateTime("2026-04-22T12:00:00Z")
        let request = UsageDashboardRequest(days: 7, sparklineDays: 7, referenceDate: anchor)

        let snapshot = try #require(await tracker.dashboardSnapshot(for: request))

        let timeZone = await tracker.usageTimeZone()
        let previousReference = UsageWindowMath.previousWindowReference(
            days: 7,
            relativeTo: anchor,
            in: timeZone
        )
        #expect(snapshot.totalCount == (await tracker.totalSwitches(days: 7, relativeTo: anchor)))
        #expect(snapshot.previousPeriodTotal == (await tracker.previousPeriodTotal(days: 7, relativeTo: anchor)))
        #expect(snapshot.counts == (await tracker.usageCounts(days: 7, relativeTo: anchor)))
        #expect(snapshot.previousCounts == (await tracker.usageCounts(days: 7, relativeTo: previousReference)))
        #expect(snapshot.hourlyCounts == (await tracker.hourlyCounts(days: 7, relativeTo: anchor)))
        #expect(snapshot.streakDays == (await tracker.streakDays(relativeTo: anchor)))
        #expect(snapshot.timeZone.identifier == timeZone.identifier)
    }

    @Test
    func alreadyCancelledTaskStartsNoQueries() async throws {
        let tracker = try await makeSeededTracker()
        let request = UsageDashboardRequest(
            days: 7,
            sparklineDays: 7,
            referenceDate: isoDateTime("2026-04-22T12:00:00Z")
        )

        let result = await Task { () -> UsageDashboardSnapshot? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await tracker.dashboardSnapshot(for: request)
        }.value

        #expect(result == nil)
        let executions = await tracker.queryExecutionCountsForTesting()
        #expect(executions.isEmpty)
    }

    @Test
    func midPhaseCancellationStopsSchedulingFurtherQueries() async throws {
        let tracker = try await makeSeededTracker()
        await tracker.setDashboardPhaseHookForTesting { phase in
            if phase == "dailyCounts" {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let request = UsageDashboardRequest(
            days: 7,
            sparklineDays: 7,
            referenceDate: isoDateTime("2026-04-22T12:00:00Z")
        )

        let result = await Task {
            await tracker.dashboardSnapshot(for: request)
        }.value

        #expect(result == nil)
        let executions = await tracker.queryExecutionCountsForTesting()
        #expect(executions["totalSwitches"] == 1)
        #expect(executions["previousPeriodTotal"] == 1)
        #expect(executions["usageCounts"] == 2)
        #expect(executions["dailyCounts"] == nil)
        #expect(executions["hourlyCounts"] == nil)
        #expect(executions["streakDays"] == nil)
    }

    @Test
    func snapshotStaysCoherentAcrossConcurrentWrites() async throws {
        let tracker = UsageTracker(
            databasePath: ":memory:",
            timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }
        )
        let shortcut = UUID()
        let anchor = isoDateTime("2026-04-22T12:00:00Z")
        let request = UsageDashboardRequest(days: 7, sparklineDays: 7, referenceDate: anchor)

        for iteration in 0..<20 {
            async let write: Void = tracker.recordUsage(
                shortcutId: shortcut,
                on: isoDateTime("2026-04-22T09:15:00Z")
            )
            async let snapshotResult = tracker.dashboardSnapshot(for: request)

            let snapshot = await snapshotResult
            await write

            // Every write lands in both tables inside one transaction, and
            // all seeded usage sits inside the 7-day window, so a coherent
            // snapshot must agree between the hourly-derived total and the
            // daily-derived per-shortcut counts. A torn snapshot would let a
            // write slip between the two reads and break the equality.
            if let snapshot {
                #expect(
                    snapshot.totalCount == snapshot.counts.values.reduce(0, +),
                    "iteration \(iteration): totalCount=\(snapshot.totalCount) counts=\(snapshot.counts)"
                )
            }
        }
    }

    @Test @MainActor
    func viewModelWeekRefreshIssuesNoDuplicateQueries() async {
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
        let recorder = RecordingUsageTracker(shortcutId: shortcutId)
        let viewModel = InsightsViewModel(usageTracker: recorder, shortcutStore: store)

        await viewModel.refresh(for: .week)

        let calls = await recorder.callCounts()
        #expect(calls["usageCounts"] == 2)
        #expect(calls["hourlyCounts"] == 1)
        #expect(calls["totalSwitches"] == 1)
        #expect(calls["previousPeriodTotal"] == 1)
        #expect(calls["dailyCounts"] == 1)
        #expect(calls["streakDays"] == 1)
    }

    @Test @MainActor
    func viewModelMonthRefreshStillQueriesFixedSevenDayDatasets() async {
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
        let recorder = RecordingUsageTracker(shortcutId: shortcutId)
        let viewModel = InsightsViewModel(usageTracker: recorder, shortcutStore: store)

        await viewModel.refresh(for: .month)

        let calls = await recorder.callCounts()
        #expect(calls["usageCounts"] == 3)
        #expect(calls["hourlyCounts"] == 2)
    }

    private func makeSeededTracker() async throws -> UsageTracker {
        let tracker = UsageTracker(
            databasePath: ":memory:",
            timeZoneProvider: { TimeZone(secondsFromGMT: 0)! }
        )
        let first = UUID()
        let second = UUID()
        await tracker.recordUsage(shortcutId: first, on: isoDateTime("2026-04-22T09:15:00Z"))
        await tracker.recordUsage(shortcutId: first, on: isoDateTime("2026-04-20T22:40:00Z"))
        await tracker.recordUsage(shortcutId: second, on: isoDateTime("2026-04-13T08:05:00Z"))
        return tracker
    }
}

private actor RecordingUsageTracker: UsageTracking {
    func deleteUsage(shortcutId: UUID) {}
    let shortcutId: UUID
    private var counts: [String: Int] = [:]

    init(shortcutId: UUID) {
        self.shortcutId = shortcutId
    }

    func callCounts() -> [String: Int] {
        counts
    }

    private func record(_ name: String) {
        counts[name, default: 0] += 1
    }

    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] {
        record("usageCounts")
        return [shortcutId: days]
    }

    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] {
        record("dailyCounts")
        return [:]
    }

    func totalSwitches(days: Int, relativeTo now: Date) async -> Int {
        record("totalSwitches")
        return days
    }

    func hourlyCounts(days: Int, relativeTo now: Date) async -> [HourlyUsageBucket] {
        record("hourlyCounts")
        return []
    }

    func previousPeriodTotal(days: Int, relativeTo now: Date) async -> Int {
        record("previousPeriodTotal")
        return 0
    }

    func streakDays(relativeTo now: Date) async -> Int {
        record("streakDays")
        return 0
    }

    func usageTimeZone() async -> TimeZone {
        .current
    }
}

private func isoDateTime(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: value)!
}
