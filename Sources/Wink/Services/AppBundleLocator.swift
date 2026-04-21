import AppKit

struct AppBundleLocator {
    private let applicationURLClient: (String) -> URL?

    init(
        applicationURLClient: @escaping (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    ) {
        self.applicationURLClient = applicationURLClient
    }

    func applicationURL(for bundleIdentifier: String) -> URL? {
        applicationURLClient(bundleIdentifier)
    }
}
