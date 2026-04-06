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
        var fastLaneMissCount: Int
        var fastLaneMissWindowStart: CFAbsoluteTime?
        var temporaryCompatibilityUntil: CFAbsoluteTime?
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
            fastLaneMissCount: 0,
            fastLaneMissWindowStart: nil,
            temporaryCompatibilityUntil: nil,
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
        entry.fastLaneEligible = entry.temporaryCompatibilityUntil == nil
        entry.lastInvalidationReason = nil
        entries[targetBundleIdentifier] = entry
        invalidationReasons.removeValue(forKey: targetBundleIdentifier)
        return entry
    }

    func markFastLaneMiss(
        for targetBundleIdentifier: String,
        now: CFAbsoluteTime,
        threshold: Int,
        window: TimeInterval,
        quarantine: TimeInterval
    ) {
        guard var entry = entries[targetBundleIdentifier] else { return }

        if let temporaryCompatibilityUntil = entry.temporaryCompatibilityUntil,
           now >= temporaryCompatibilityUntil {
            entry.temporaryCompatibilityUntil = nil
            entry.fastLaneEligible = true
            entry.fastLaneMissCount = 0
            entry.fastLaneMissWindowStart = nil
        }

        if let windowStart = entry.fastLaneMissWindowStart,
           now - windowStart <= window {
            entry.fastLaneMissCount += 1
        } else {
            entry.fastLaneMissWindowStart = now
            entry.fastLaneMissCount = 1
        }

        if entry.fastLaneMissCount >= threshold {
            entry.fastLaneEligible = false
            entry.temporaryCompatibilityUntil = now + quarantine
        }

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

    func entry(for targetBundleIdentifier: String, now: CFAbsoluteTime) -> Entry? {
        guard var entry = entries[targetBundleIdentifier] else { return nil }

        if let temporaryCompatibilityUntil = entry.temporaryCompatibilityUntil,
           now >= temporaryCompatibilityUntil {
            entry.temporaryCompatibilityUntil = nil
            entry.fastLaneEligible = true
            entry.fastLaneMissCount = 0
            entry.fastLaneMissWindowStart = nil
            entries[targetBundleIdentifier] = entry
        }

        return entry
    }

    func lastInvalidationReason(for targetBundleIdentifier: String) -> CacheInvalidationReason? {
        invalidationReasons[targetBundleIdentifier]
    }
}
