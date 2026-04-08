import AppKit

@MainActor
final class FrontmostApplicationTracker {
    struct Client: Sendable {
        let currentFrontmostBundleIdentifier: @MainActor () -> String?
    }

    private(set) var lastNonTargetBundleIdentifier: String?
    private let client: Client

    init(client: Client = .live) {
        self.client = client
    }

    func currentFrontmostBundleIdentifier() -> String? {
        client.currentFrontmostBundleIdentifier()
    }

    func noteCurrentFrontmostApp(excluding targetBundleIdentifier: String) {
        guard let current = currentFrontmostBundleIdentifier(), current != targetBundleIdentifier else {
            return
        }
        lastNonTargetBundleIdentifier = current
    }

    func resetPreviousAppTracking() {
        lastNonTargetBundleIdentifier = nil
    }
}

extension FrontmostApplicationTracker.Client {
    static let live = FrontmostApplicationTracker.Client(
        currentFrontmostBundleIdentifier: {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    )
}
