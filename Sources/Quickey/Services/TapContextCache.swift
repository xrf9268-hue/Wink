import Foundation

enum CacheInvalidationReason: String, Sendable, Equatable {
    case sessionReset
    case previousAppTerminated
    case frontmostChanged
    case sourceOfTruthMismatch
}

@MainActor
final class TapContextCache {
    struct Entry {
        var restoreContext: RestoreContext
        var fastLaneEligible: Bool
        var lastInvalidationReason: CacheInvalidationReason?
    }

    private var entries: [String: Entry] = [:]
    private var invalidationReasons: [String: CacheInvalidationReason] = [:]

    @discardableResult
    func upsert(
        targetBundleIdentifier: String,
        coordinatorPreviousBundle: String?,
        restoreContext: RestoreContext
    ) -> Entry {
        let normalizedPrevious = normalizedPreviousBundle(
            targetBundleIdentifier: targetBundleIdentifier,
            previousBundleIdentifier: coordinatorPreviousBundle
        )
        var entry = entries[targetBundleIdentifier] ?? Entry(
            restoreContext: restoreContext,
            fastLaneEligible: true,
            lastInvalidationReason: nil
        )
        entry.restoreContext = RestoreContext(
            targetBundleIdentifier: restoreContext.targetBundleIdentifier,
            previousBundleIdentifier: normalizedPrevious,
            previousPID: restoreContext.previousPID,
            previousBundleURL: restoreContext.previousBundleURL,
            capturedAt: restoreContext.capturedAt,
            generation: restoreContext.generation
        )
        // upsert is invoked only on a successful stable activation
        // (see AppSwitcher.promotePendingActivationIfCurrent), so a fresh
        // success is the recovery signal that re-enables fast-lane eligibility
        // for a bundle previously demoted by markFastLaneMiss.
        entry.fastLaneEligible = true
        entry.lastInvalidationReason = nil
        entries[targetBundleIdentifier] = entry
        invalidationReasons.removeValue(forKey: targetBundleIdentifier)
        return entry
    }

    func markFastLaneMiss(for targetBundleIdentifier: String) {
        guard var entry = entries[targetBundleIdentifier] else { return }
        entry.fastLaneEligible = false
        entries[targetBundleIdentifier] = entry
    }

    func invalidate(_ targetBundleIdentifier: String, reason: CacheInvalidationReason) {
        invalidationReasons[targetBundleIdentifier] = reason

        switch reason {
        case .frontmostChanged:
            guard var entry = entries[targetBundleIdentifier] else { return }
            entry.fastLaneEligible = false
            entry.lastInvalidationReason = reason
            entries[targetBundleIdentifier] = entry
        case .sessionReset, .previousAppTerminated, .sourceOfTruthMismatch:
            entries.removeValue(forKey: targetBundleIdentifier)
        }
    }

    func entry(for targetBundleIdentifier: String) -> Entry? {
        entries[targetBundleIdentifier]
    }

    func lastInvalidationReason(for targetBundleIdentifier: String) -> CacheInvalidationReason? {
        invalidationReasons[targetBundleIdentifier]
    }
}
