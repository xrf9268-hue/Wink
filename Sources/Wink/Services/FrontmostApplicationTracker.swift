import AppKit

@MainActor
final class FrontmostApplicationTracker {
    struct Client: Sendable {
        let currentFrontmostBundleIdentifier: @MainActor () -> String?
    }

    private let client: Client

    init(client: Client = .live) {
        self.client = client
    }

    func currentFrontmostBundleIdentifier() -> String? {
        client.currentFrontmostBundleIdentifier()
    }
}

extension FrontmostApplicationTracker.Client {
    static let live = FrontmostApplicationTracker.Client(
        currentFrontmostBundleIdentifier: {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    )
}
