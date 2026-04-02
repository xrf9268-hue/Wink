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
        let targetIsHidden: () -> Bool
        let targetIsActive: () -> Bool
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
            let frontmostIsTarget = currentFrontmost == nil || currentFrontmost == targetBundleIdentifier

            // Clear confirmation: target is no longer frontmost
            if !frontmostIsTarget {
                return ConfirmationResult(
                    confirmed: true,
                    usedEscalatedObservation: false,
                    frontmostBundleAfterRestore: currentFrontmost
                )
            }

            // Only fetch hidden/active when frontmost is ambiguous (avoids redundant IPC on happy path)
            let targetHidden = client.targetIsHidden()
            let targetActive = client.targetIsActive()
            if isContradictory(frontmostIsTarget: true, targetHidden: targetHidden, targetActive: targetActive) {
                return escalateToObservation()
            }
        }

        // 4. Timeout: not confirmed
        return ConfirmationResult(
            confirmed: false,
            usedEscalatedObservation: false,
            frontmostBundleAfterRestore: client.frontmostBundleIdentifier()
        )
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
        return ConfirmationResult(
            confirmed: !snapshot.targetIsObservedFrontmost,
            usedEscalatedObservation: true,
            frontmostBundleAfterRestore: snapshot.observedFrontmostBundleIdentifier
        )
    }

    private func isContradictory(
        frontmostIsTarget: Bool,
        targetHidden: Bool,
        targetActive: Bool
    ) -> Bool {
        // Target reports hidden but is still frontmost
        if frontmostIsTarget && targetHidden { return true }
        // Target is not frontmost but still reports active and not hidden
        if !frontmostIsTarget && targetActive && !targetHidden { return true }
        return false
    }
}
