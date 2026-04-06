import AppKit
import Testing
@testable import Quickey

@Test @MainActor
func coordinatorPreviousBundleWinsWhenCacheMirrorDrifts() {
    let coordinator = ToggleSessionCoordinator(now: { 100 })
    let cache = TapContextCache()

    coordinator.beginActivation(for: "com.apple.Safari", previousBundle: "com.apple.Terminal")

    let staleContext = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Finder",
        previousPID: 42,
        previousBundleURL: URL(fileURLWithPath: "/Applications/Finder.app"),
        capturedAt: 100,
        generation: 1
    )

    let entry = cache.upsert(
        targetBundleIdentifier: "com.apple.Safari",
        coordinatorPreviousBundle: coordinator.durablePreviousBundle(for: "com.apple.Safari"),
        restoreContext: staleContext
    )

    #expect(entry.restoreContext.previousBundleIdentifier == "com.apple.Terminal")
    #expect(cache.entry(for: "com.apple.Safari")?.restoreContext.previousBundleIdentifier == "com.apple.Terminal")
}

@Test @MainActor
func cacheInvalidatesWhenPreviousAppTerminates() {
    let coordinator = ToggleSessionCoordinator(now: { 100 })
    let cache = TapContextCache()

    coordinator.beginActivation(for: "com.apple.Safari", previousBundle: "com.apple.Terminal")

    let restoreContext = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 42,
        previousBundleURL: URL(fileURLWithPath: "/Applications/Terminal.app"),
        capturedAt: 100,
        generation: 1
    )

    cache.upsert(
        targetBundleIdentifier: "com.apple.Safari",
        coordinatorPreviousBundle: coordinator.durablePreviousBundle(for: "com.apple.Safari"),
        restoreContext: restoreContext
    )

    cache.invalidate("com.apple.Safari", reason: .previousAppTerminated)

    #expect(cache.entry(for: "com.apple.Safari") == nil)
    #expect(cache.lastInvalidationReason(for: "com.apple.Safari") == .previousAppTerminated)
}

@Test @MainActor
func frontmostChangePreservesRestoreContextButDisablesFastLane() {
    let cache = TapContextCache()
    let restoreContext = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 42,
        previousBundleURL: URL(fileURLWithPath: "/Applications/Terminal.app"),
        capturedAt: 100,
        generation: 1
    )

    cache.upsert(
        targetBundleIdentifier: "com.apple.Safari",
        coordinatorPreviousBundle: "com.apple.Terminal",
        restoreContext: restoreContext
    )

    cache.invalidate("com.apple.Safari", reason: .frontmostChanged)

    let retainedEntry = cache.entry(for: "com.apple.Safari")
    #expect(retainedEntry?.restoreContext.previousBundleIdentifier == "com.apple.Terminal")
    #expect(retainedEntry?.fastLaneEligible == false)
    #expect(retainedEntry?.lastInvalidationReason == .frontmostChanged)
    #expect(cache.lastInvalidationReason(for: "com.apple.Safari") == .frontmostChanged)
}

@Test @MainActor
func successfulUpsertRecoversFastLaneAfterMiss() {
    let cache = TapContextCache()
    let restoreContext = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 42,
        previousBundleURL: URL(fileURLWithPath: "/Applications/Terminal.app"),
        capturedAt: 100,
        generation: 1
    )

    cache.upsert(
        targetBundleIdentifier: "com.apple.Safari",
        coordinatorPreviousBundle: "com.apple.Terminal",
        restoreContext: restoreContext
    )

    let entryBefore = cache.entry(for: "com.apple.Safari")
    #expect(entryBefore?.fastLaneEligible == true)

    cache.markFastLaneMiss(for: "com.apple.Safari")
    #expect(cache.entry(for: "com.apple.Safari")?.fastLaneEligible == false)

    // A successful activation cycle (upsert) is the recovery signal:
    // it must re-enable fast-lane eligibility for a previously-missed bundle.
    let recoveredContext = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 99,
        previousBundleURL: URL(fileURLWithPath: "/Applications/Terminal.app"),
        capturedAt: 200,
        generation: 2
    )
    let recoveredEntry = cache.upsert(
        targetBundleIdentifier: "com.apple.Safari",
        coordinatorPreviousBundle: "com.apple.Terminal",
        restoreContext: recoveredContext
    )

    #expect(recoveredEntry.fastLaneEligible == true)
    #expect(cache.entry(for: "com.apple.Safari")?.fastLaneEligible == true)
}

@Test @MainActor
func sessionResetRestoresFastLaneEligibility() {
    let cache = TapContextCache()
    let restoreContext = RestoreContext(
        targetBundleIdentifier: "com.apple.Safari",
        previousBundleIdentifier: "com.apple.Terminal",
        previousPID: 42,
        previousBundleURL: URL(fileURLWithPath: "/Applications/Terminal.app"),
        capturedAt: 100,
        generation: 1
    )

    cache.upsert(
        targetBundleIdentifier: "com.apple.Safari",
        coordinatorPreviousBundle: "com.apple.Terminal",
        restoreContext: restoreContext
    )

    cache.markFastLaneMiss(for: "com.apple.Safari")
    #expect(cache.entry(for: "com.apple.Safari")?.fastLaneEligible == false)

    // Session reset clears the entry entirely — next upsert starts fresh with fastLaneEligible=true
    cache.invalidate("com.apple.Safari", reason: .sessionReset)
    #expect(cache.entry(for: "com.apple.Safari") == nil)

    let freshEntry = cache.upsert(
        targetBundleIdentifier: "com.apple.Safari",
        coordinatorPreviousBundle: "com.apple.Terminal",
        restoreContext: restoreContext
    )
    #expect(freshEntry.fastLaneEligible == true)
}
