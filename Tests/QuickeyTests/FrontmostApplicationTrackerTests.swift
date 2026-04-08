import Testing
@testable import Quickey

@Test @MainActor
func noteCurrentFrontmostAppSkipsTargetBundleIdentifier() {
    let tracker = FrontmostApplicationTracker(client: .init(
        currentFrontmostBundleIdentifier: { "com.apple.Terminal" }
    ))

    tracker.noteCurrentFrontmostApp(excluding: "com.apple.Terminal")

    #expect(tracker.lastNonTargetBundleIdentifier == nil)
}

@Test @MainActor
func noteCurrentFrontmostAppRecordsNonTargetBundleIdentifier() {
    let tracker = FrontmostApplicationTracker(client: .init(
        currentFrontmostBundleIdentifier: { "com.apple.Terminal" }
    ))

    tracker.noteCurrentFrontmostApp(excluding: "com.apple.Safari")
    #expect(tracker.lastNonTargetBundleIdentifier == "com.apple.Terminal")
}

@Test @MainActor
func resetPreviousBundleAllowsFreshActivationToCaptureNewFrontmostApp() {
    let frontmostState = MutableFrontmostState(bundleIdentifier: "com.apple.Terminal")
    let tracker = FrontmostApplicationTracker(client: .init(
        currentFrontmostBundleIdentifier: { frontmostState.bundleIdentifier }
    ))

    tracker.noteCurrentFrontmostApp(excluding: "com.apple.Safari")

    frontmostState.bundleIdentifier = "com.openai.codex"
    tracker.resetPreviousAppTracking()
    tracker.noteCurrentFrontmostApp(excluding: "com.apple.Safari")

    #expect(tracker.lastNonTargetBundleIdentifier == "com.openai.codex")
}

private final class MutableFrontmostState: @unchecked Sendable {
    var bundleIdentifier: String

    init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }
}
