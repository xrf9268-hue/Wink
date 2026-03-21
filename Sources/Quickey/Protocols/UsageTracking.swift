import Foundation

protocol UsageTracking: Sendable {
    func usageCounts(days: Int) async -> [UUID: Int]
    func dailyCounts(days: Int) async -> [String: [(date: String, count: Int)]]
    func totalSwitches(days: Int) async -> Int
}
