import Foundation
import SwiftUI

struct InsightsUnusedNudge: View {
    let appNames: [String]
    var onReview: () -> Void = {}

    var body: some View {
        if !appNames.isEmpty {
            WinkBanner(
                kind: .info,
                title: String(localized: "Unused shortcuts this week", bundle: WinkResourceBundle.bundle),
                message: Self.message(for: appNames),
                icon: WinkIcon.sparkles.systemName
            ) {
                WinkButton(String(localized: "Review", bundle: WinkResourceBundle.bundle), action: onReview)
            }
        }
    }

    static func message(for appNames: [String]) -> String {
        let count = appNames.count
        let preview = appNames.prefix(3).joined(separator: ", ")

        if count == 1, let only = appNames.first {
            return String(localized: "\(only) has not been activated in the past 7 days.", bundle: WinkResourceBundle.bundle)
        }

        if count <= 3 {
            return String(localized: "\(preview) have not been activated in the past 7 days.", bundle: WinkResourceBundle.bundle)
        }

        return String(
            localized: "\(preview), and \(count - 3) more have not been activated in the past 7 days.",
            bundle: WinkResourceBundle.bundle
        )
    }
}
