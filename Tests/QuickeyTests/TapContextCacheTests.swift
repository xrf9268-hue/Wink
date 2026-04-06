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
    #expect(cache.entry(for: "com.apple.Safari", now: 100)?.restoreContext.previousBundleIdentifier == "com.apple.Terminal")
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

    #expect(cache.entry(for: "com.apple.Safari", now: 101) == nil)
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

    let retainedEntry = cache.entry(for: "com.apple.Safari", now: 101)
    #expect(retainedEntry?.restoreContext.previousBundleIdentifier == "com.apple.Terminal")
    #expect(retainedEntry?.fastLaneEligible == false)
    #expect(retainedEntry?.lastInvalidationReason == .frontmostChanged)
    #expect(cache.lastInvalidationReason(for: "com.apple.Safari") == .frontmostChanged)
}

@Test @MainActor
func threeFastLaneMissesEnterTemporaryCompatibilityWindow() {
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

    cache.markFastLaneMiss(
        for: "com.apple.Safari",
        now: 100,
        threshold: 3,
        window: 600,
        quarantine: 300
    )
    cache.markFastLaneMiss(
        for: "com.apple.Safari",
        now: 120,
        threshold: 3,
        window: 600,
        quarantine: 300
    )
    cache.markFastLaneMiss(
        for: "com.apple.Safari",
        now: 140,
        threshold: 3,
        window: 600,
        quarantine: 300
    )

    let quarantinedEntry = cache.entry(for: "com.apple.Safari", now: 141)
    #expect(quarantinedEntry?.temporaryCompatibilityUntil == 440)
    #expect(quarantinedEntry?.fastLaneEligible == false)

    let recoveredEntry = cache.entry(for: "com.apple.Safari", now: 441)
    #expect(recoveredEntry?.temporaryCompatibilityUntil == nil)
    #expect(recoveredEntry?.fastLaneEligible == true)
    #expect(recoveredEntry?.fastLaneMissCount == 0)
    #expect(recoveredEntry?.fastLaneMissWindowStart == nil)
}
