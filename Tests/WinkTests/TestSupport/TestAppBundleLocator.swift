import Foundation
@testable import Wink

struct TestAppBundleLocator {
    let entries: [String: URL]

    var locator: AppBundleLocator {
        AppBundleLocator { bundleIdentifier in
            entries[bundleIdentifier]
        }
    }
}
