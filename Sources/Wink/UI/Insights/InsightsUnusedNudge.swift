import SwiftUI

struct InsightsUnusedNudge: View {
    let appNames: [String]
    var onReview: () -> Void = {}

    var body: some View {
        if !appNames.isEmpty {
            WinkBanner(
                kind: .info,
                title: "Unused shortcuts this week",
                message: Self.message(for: appNames),
                icon: WinkIcon.sparkles.systemName
            ) {
                WinkButton("Review", action: onReview)
            }
        }
    }

    static func message(for appNames: [String]) -> String {
        let count = appNames.count
        let preview = appNames.prefix(3).joined(separator: ", ")

        if count == 1, let only = appNames.first {
            return "\(only) has not been activated in the past 7 days."
        }

        if count <= 3 {
            return "\(preview) have not been activated in the past 7 days."
        }

        return "\(preview), and \(count - 3) more have not been activated in the past 7 days."
    }
}
