import AppKit

@MainActor
final class ObservationBroker {
    struct ConfirmationResult: Equatable, Sendable {
        let confirmed: Bool
        let usedEscalatedObservation: Bool
        let frontmostBundleAfterRestore: String?
    }

    struct Client {
        let frontmostBundleIdentifier: () -> String?
        let targetClassification: () -> ApplicationClassification
        let escalatedSnapshot: () -> ActivationObservationSnapshot
        let now: () -> CFAbsoluteTime
        let pollOnce: (TimeInterval) -> Void
    }

    private let client: Client
    private let confirmationWindow: TimeInterval
    private let pollInterval: TimeInterval

    init(client: Client, confirmationWindow: TimeInterval = 0.075, pollInterval: TimeInterval = 0.01) {
        self.client = client
        self.confirmationWindow = confirmationWindow
        self.pollInterval = pollInterval
    }

    // MARK: - Fast lane confirmation

    func confirmFastRestore(
        targetBundleIdentifier: String,
        previousBundleIdentifier: String?
    ) -> ConfirmationResult {
        // 1. Immediate cheap check
        let initialFrontmost = client.frontmostBundleIdentifier()
        if initialFrontmost != nil, initialFrontmost != targetBundleIdentifier {
            return ConfirmationResult(
                confirmed: true,
                usedEscalatedObservation: false,
                frontmostBundleAfterRestore: initialFrontmost
            )
        }

        // 2. Non-regular classifications skip cheap confirmation → escalate immediately
        let classification = client.targetClassification()
        switch classification {
        case .systemUtility, .nonStandardWindowed, .windowlessOrAccessory:
            return escalateToObservation()
        case .regularWindowed:
            break
        }

        // 3. Bounded polling within confirmation window (max 75ms)
        let deadline = client.now() + confirmationWindow

        while client.now() < deadline {
            client.pollOnce(pollInterval)

            let currentFrontmost = client.frontmostBundleIdentifier()

            // Clear confirmation: target is no longer frontmost
            if currentFrontmost != nil, currentFrontmost != targetBundleIdentifier {
                return ConfirmationResult(
                    confirmed: true,
                    usedEscalatedObservation: false,
                    frontmostBundleAfterRestore: currentFrontmost
                )
            }
        }

        // 4. Timeout: escalate to full observation
        return escalateToObservation()
    }

    // MARK: - Compatibility lane confirmation

    func confirmCompatibilityRestore(
        targetBundleIdentifier: String,
        previousBundleIdentifier: String?
    ) -> ConfirmationResult {
        escalateToObservation()
    }

    // MARK: - Private

    private func escalateToObservation() -> ConfirmationResult {
        let snapshot = client.escalatedSnapshot()
        // Without a resolved frontmost we have no positive evidence the restore
        // succeeded — NSWorkspace can transiently return nil. Treat as
        // unconfirmed so callers fall through to the compatibility lane and
        // miss quarantine remains effective. Otherwise rely on the existing
        // composite predicate that ALSO checks targetIsActive / targetIsHidden /
        // window evidence, not just the frontmost bundle id.
        let confirmed: Bool
        if snapshot.observedFrontmostBundleIdentifier == nil {
            confirmed = false
        } else {
            confirmed = !snapshot.isStableActivation
        }
        return ConfirmationResult(
            confirmed: confirmed,
            usedEscalatedObservation: true,
            frontmostBundleAfterRestore: snapshot.observedFrontmostBundleIdentifier
        )
    }
}
