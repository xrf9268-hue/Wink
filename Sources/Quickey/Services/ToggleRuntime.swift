import Foundation

enum ToggleExecutionMode: Sendable, Equatable {
    case legacyOnly
    case shadowMode
    case pipelineEnabled
}

struct ToggleRuntimeConfiguration: Sendable, Equatable {
    var executionMode: ToggleExecutionMode = .legacyOnly
    var fastConfirmationWindow: TimeInterval = 0.075
    var contextPreparationConcurrencyLimit: Int = 2
    var fastLaneMissThreshold: Int = 3
    var fastLaneMissWindow: TimeInterval = 600
    var temporaryCompatibilityWindow: TimeInterval = 300
}

enum ToggleRuntimeDecision: Equatable {
    case useLegacy
    case shadow(ShadowDecision)
    case execute(PipelineDecision)
}

struct ShadowDecision: Equatable {
    let selectedLane: String
    let wouldUseHideTarget: Bool
    let previousBundleIdentifier: String?
}

enum PipelineDecision: Equatable {
    case fastLane(RestoreContext)
    case compatibilityLane(RestoreContext)
}

@MainActor
final class ToggleRuntime {
    let configuration: ToggleRuntimeConfiguration
    let tapContextCache: TapContextCache

    init(
        configuration: ToggleRuntimeConfiguration = .init(),
        tapContextCache: TapContextCache = TapContextCache()
    ) {
        self.configuration = configuration
        self.tapContextCache = tapContextCache
    }

    func decision(
        targetBundleIdentifier: String,
        previousBundleIdentifier: String?,
        classification: ApplicationClassification,
        attemptStartedAt: CFAbsoluteTime
    ) -> ToggleRuntimeDecision {
        switch configuration.executionMode {
        case .legacyOnly:
            return .useLegacy

        case .shadowMode:
            let normalizedPrevious = normalizedPreviousBundle(
                targetBundleIdentifier: targetBundleIdentifier,
                previousBundleIdentifier: previousBundleIdentifier
            )
            let cacheEntry = tapContextCache.entry(for: targetBundleIdentifier, now: attemptStartedAt)
            let fastLaneEligible = cacheEntry?.fastLaneEligible ?? true
            let wouldUseFastLane = fastLaneEligible
                && normalizedPrevious != nil
                && classification == .regularWindowed

            return .shadow(ShadowDecision(
                selectedLane: wouldUseFastLane ? "fast" : "compatibility",
                wouldUseHideTarget: !wouldUseFastLane,
                previousBundleIdentifier: normalizedPrevious
            ))

        case .pipelineEnabled:
            let normalizedPrevious = normalizedPreviousBundle(
                targetBundleIdentifier: targetBundleIdentifier,
                previousBundleIdentifier: previousBundleIdentifier
            )
            let cacheEntry = tapContextCache.entry(for: targetBundleIdentifier, now: attemptStartedAt)
            let fastLaneEligible = cacheEntry?.fastLaneEligible ?? true

            let hintsMatch = normalizedPrevious != nil
                && cacheEntry?.restoreContext.previousBundleIdentifier == normalizedPrevious
            let context = RestoreContext(
                targetBundleIdentifier: targetBundleIdentifier,
                previousBundleIdentifier: normalizedPrevious,
                previousPID: hintsMatch ? cacheEntry?.restoreContext.previousPID : nil,
                previousBundleURL: hintsMatch ? cacheEntry?.restoreContext.previousBundleURL : nil,
                capturedAt: attemptStartedAt,
                generation: cacheEntry?.restoreContext.generation ?? 0
            )

            if fastLaneEligible,
               normalizedPrevious != nil,
               classification == .regularWindowed {
                return .execute(.fastLane(context))
            } else {
                return .execute(.compatibilityLane(context))
            }
        }
    }
}

@MainActor
func normalizedPreviousBundle(
    targetBundleIdentifier: String,
    previousBundleIdentifier: String?
) -> String? {
    guard previousBundleIdentifier != targetBundleIdentifier else {
        return nil
    }
    return previousBundleIdentifier
}
