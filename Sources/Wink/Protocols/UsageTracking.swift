import Foundation

protocol UsageTracking: Sendable {
    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int]
    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]]
    func totalSwitches(days: Int, relativeTo now: Date) async -> Int
}

extension UsageTracking {
    func usageCounts(days: Int) async -> [UUID: Int] {
        await usageCounts(days: days, relativeTo: Date())
    }

    func dailyCounts(days: Int) async -> [String: [(date: String, count: Int)]] {
        await dailyCounts(days: days, relativeTo: Date())
    }

    func totalSwitches(days: Int) async -> Int {
        await totalSwitches(days: days, relativeTo: Date())
    }
}
