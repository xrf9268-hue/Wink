import Foundation

private final class WinkResourceBundleFinder {}

enum WinkResourceBundle {
    static let bundle: Bundle = {
        let bundleName = "Wink_Wink.bundle"
        let finderBundle = Bundle(for: WinkResourceBundleFinder.self)
        let searchRoots: [URL] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            finderBundle.resourceURL,
            finderBundle.bundleURL,
        ].compactMap { $0 }

        for root in searchRoots {
            let candidate = root.appendingPathComponent(bundleName)
            if FileManager.default.fileExists(atPath: candidate.path),
               let bundle = Bundle(url: candidate) {
                return bundle
            }
        }

        return .module
    }()
}
