import Testing
@testable import Wink

@Test @MainActor
func currentFrontmostBundleIdentifierReadsInjectedClient() {
    let tracker = FrontmostApplicationTracker(client: .init(
        currentFrontmostBundleIdentifier: { "com.apple.Terminal" }
    ))

    #expect(tracker.currentFrontmostBundleIdentifier() == "com.apple.Terminal")
}
