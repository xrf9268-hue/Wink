import AppKit

@MainActor
final class FrontmostApplicationTracker {
    struct Client: Sendable {
        let currentFrontmostBundleIdentifier: @MainActor () -> String?
        let currentFrontmostApplication: @MainActor () -> NSRunningApplication?

        init(
            currentFrontmostBundleIdentifier: @escaping @MainActor () -> String?,
            currentFrontmostApplication: @escaping @MainActor () -> NSRunningApplication? = { nil }
        ) {
            self.currentFrontmostBundleIdentifier = currentFrontmostBundleIdentifier
            self.currentFrontmostApplication = currentFrontmostApplication
        }
    }

    private let client: Client

    init(client: Client = .live) {
        self.client = client
    }

    func currentFrontmostBundleIdentifier() -> String? {
        client.currentFrontmostBundleIdentifier()
    }

    /// Call-time snapshot of the frontmost application (not a cached
    /// notification value) — frontmost-app pseudo-targets resolve against
    /// what is frontmost at the keypress, not at the last workspace event.
    func currentFrontmostApplication() -> NSRunningApplication? {
        client.currentFrontmostApplication()
    }
}

extension FrontmostApplicationTracker.Client {
    static let live = FrontmostApplicationTracker.Client(
        currentFrontmostBundleIdentifier: {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        currentFrontmostApplication: {
            NSWorkspace.shared.frontmostApplication
        }
    )
}
