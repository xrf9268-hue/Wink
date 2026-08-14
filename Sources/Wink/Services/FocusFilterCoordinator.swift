import CoreFoundation
import Foundation
import Observation
import WinkFocusShared

private let focusFilterDarwinCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let coordinator = Unmanaged<FocusFilterCoordinator>
        .fromOpaque(observer)
        .takeUnretainedValue()
    Task { @MainActor in
        coordinator.reconcile(reason: "darwin-notification")
    }
}

/// Main-app owner of the durable Focus overlay. The App Intents extension can
/// run while Wink is absent; this coordinator treats the shared file as source
/// of truth, with the Darwin notification only as a wake-up hint. Startup
/// always reconciles the file before capture begins.
@MainActor
final class FocusFilterCoordinator {
    struct DiagnosticClient: Sendable {
        let log: @Sendable (String) -> Void

        static let live = DiagnosticClient(log: DiagnosticLog.log)
    }

    private enum RetryKey: Equatable {
        case focusProfile(UUID)
        case restoreProfile(UUID)
        case sharedState
    }

    private enum ReconcileOutcome {
        case focusApplied(UUID)
        case focusDeferred
        case focusApplyFailed(UUID)
        case focusBlocked
        case focusStale
        case restored
        case restoreDeferred
        case restoreApplyFailed(UUID)
        case restoreStale
        case inactive
    }

    private let store: FocusFilterSharedStore
    private let profileState: ShortcutProfileState
    private let preferences: AppPreferences
    private let retryDelays: [Duration]
    private let diagnosticClient: DiagnosticClient
    private var started = false
    private var retryTask: Task<Void, Never>?
    private var retryKey: RetryKey?
    private var retryAttempt = 0
    private var catalogRetryTask: Task<Void, Never>?
    private var catalogRetryAttempt = 0

    var hasScheduledRetry: Bool {
        retryTask != nil
    }

    var hasScheduledCatalogRetry: Bool {
        catalogRetryTask != nil
    }

    init(
        store: FocusFilterSharedStore = FocusFilterSharedStore(),
        profileState: ShortcutProfileState,
        preferences: AppPreferences,
        retryDelays: [Duration] = [
            .milliseconds(250),
            .seconds(1),
            .seconds(3),
            .seconds(8),
            .seconds(15),
        ],
        diagnosticClient: DiagnosticClient = .live
    ) {
        self.store = store
        self.profileState = profileState
        self.preferences = preferences
        self.retryDelays = retryDelays
        self.diagnosticClient = diagnosticClient
    }

    func start() {
        guard !started else {
            reconcile(reason: "repeated-start")
            return
        }
        started = true

        profileState.onManualProfileSelectionDuringFocus = { [weak self] profileID in
            self?.saveManualProfileSelection(profileID) ?? .failed
        }
        profileState.onRecoveryChoiceAppliedDuringFocus = { [weak self] in
            self?.reconcile(reason: "recovery-choice", completingRecoveryChoice: true)
        }
        profileState.onProfilesChanged = { [weak self] profiles in
            guard let self else {
                return String(
                    localized: "Wink could not save Focus Filter state. The current profile was left unchanged.",
                    bundle: WinkResourceBundle.bundle
                )
            }
            let error = self.publishCatalog(profiles)
            if error == nil {
                // A repaired profile can make a previously stale or failed
                // Focus selection applicable again. Reconcile after the
                // publisher returns so catalog repair is an explicit retry
                // trigger even after the bounded timer sequence is exhausted.
                Task { @MainActor [weak self] in
                    guard let self, self.started else { return }
                    self.reconcile(reason: "profiles-changed")
                }
            }
            return error
        }
        profileState.onPrepareProfileDeletion = { [weak self] profileID, profiles in
            self?.prepareProfileDeletion(profileID, remainingProfiles: profiles)
                ?? .failed(
                    String(
                        localized: "Wink could not save Focus Filter state. The current profile was left unchanged.",
                        bundle: WinkResourceBundle.bundle
                    )
                )
        }
        profileState.reportProfileCatalogPublicationError(
            publishCatalog(profileState.profiles)
        )

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            focusFilterDarwinCallback,
            WinkFocusSharedContract.notificationName as CFString,
            nil,
            .deliverImmediately
        )
        observeExternalSwitchReadiness()
        reconcile(reason: "startup")
    }

    func stop() {
        guard started else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(WinkFocusSharedContract.notificationName as CFString),
            nil
        )
        profileState.onManualProfileSelectionDuringFocus = nil
        profileState.onRecoveryChoiceAppliedDuringFocus = nil
        profileState.onProfilesChanged = nil
        profileState.onPrepareProfileDeletion = nil
        cancelRetry()
        cancelCatalogRetry()
        started = false
    }

    func reconcile(reason: String, completingRecoveryChoice: Bool = false) {
        // Normal Focus transitions are rare, but compare-and-apply can lose a
        // race to the extension. Retry fresh snapshots synchronously so no
        // main-actor shortcut delivery can observe an obsolete profile in
        // between. Sustained churn falls back to the bounded retry ladder.
        for _ in 0..<8 {
            let sharedState: FocusFilterSharedState
            do {
                sharedState = try store.loadState()
            } catch {
                handleSharedStateFailure(error, reason: reason)
                return
            }

            switch retryKey {
            case let .focusProfile(retryingID)
                where sharedState.profileID != retryingID:
                cancelRetry()
            case let .restoreProfile(retryingID)
                where sharedState.profileID != nil
                    || sharedState.manualProfileID != retryingID:
                cancelRetry()
            default:
                break
            }

            // Capture the exact current manual base before applying the first
            // Focus overlay. The setter itself is a locked read-modify-write;
            // if the extension changed Focus meanwhile, the next loop applies
            // that newer durable state instead of this stale snapshot.
            if sharedState.profileID != nil,
               sharedState.manualProfileID == nil,
               let activeProfileID = profileState.activeProfileID {
                do {
                    _ = try store.setManualProfileID(activeProfileID)
                    continue
                } catch {
                    handleSharedStateFailure(error, reason: reason)
                    return
                }
            }

            do {
                let outcome = try profileState.withDeferredProfileCatalogPublication {
                    try store.updateStateIfCurrent(sharedState) { lockedState in
                        reconcileLockedState(
                            &lockedState,
                            reason: reason,
                            completingRecoveryChoice: completingRecoveryChoice
                        )
                    }
                }
                guard let outcome else { continue }
                handle(outcome, reason: reason)
                return
            } catch {
                handleSharedStateFailure(error, reason: reason)
                return
            }
        }

        diagnosticClient.log("FOCUS_FILTER reconcile=contended reason=\(reason)")
        scheduleRetry(for: .sharedState, reason: "contention")
    }

    private func reconcileLockedState(
        _ sharedState: inout FocusFilterSharedState,
        reason: String,
        completingRecoveryChoice: Bool
    ) -> ReconcileOutcome {
        // Pause is independent of profile application. Because it is applied
        // under the same shared-state lock, an extension transition cannot
        // leave an old pause value visible after this reconciliation returns.
        preferences.setFocusPauseActive(sharedState.pauseShortcuts)

        if let focusProfileID = sharedState.profileID {
            return applyFocusProfile(
                focusProfileID,
                manualProfileID: sharedState.manualProfileID,
                reason: reason,
                completingRecoveryChoice: completingRecoveryChoice
            )
        }
        if let manualProfileID = sharedState.manualProfileID {
            let outcome = restoreManualProfile(
                manualProfileID,
                pauseRemainsActive: sharedState.pauseShortcuts,
                reason: reason
            )
            if case .restored = outcome {
                sharedState.manualProfileID = nil
            }
            return outcome
        }

        profileState.clearFocusOverlay()
        profileState.clearFocusFilterReporting()
        diagnosticClient.log(
            "FOCUS_FILTER reconcile=inactive reason=\(reason) pause=\(sharedState.pauseShortcuts)"
        )
        return .inactive
    }

    private func applyFocusProfile(
        _ focusProfileID: UUID,
        manualProfileID: UUID?,
        reason: String,
        completingRecoveryChoice: Bool
    ) -> ReconcileOutcome {
        guard profileState.profiles.contains(where: { $0.id == focusProfileID }) else {
            profileState.setFocusOverlay(
                profileID: focusProfileID,
                manualProfileID: manualProfileID
            )
            profileState.reportFocusFilterError(
                String(
                    localized: "The active Focus Filter refers to a profile that no longer exists. Wink kept the current profile instead of choosing another one.",
                    bundle: WinkResourceBundle.bundle
                )
            )
            diagnosticClient.log(
                "FOCUS_FILTER reconcile=stale-profile reason=\(reason) profileId=\(focusProfileID.uuidString)"
            )
            return .focusStale
        }

        guard let manualProfileID else {
            profileState.setFocusOverlay(profileID: focusProfileID, manualProfileID: nil)
            profileState.reportFocusFilterError(
                String(
                    localized: "Wink could not apply the Focus Filter because there is no resolved profile to restore later.",
                    bundle: WinkResourceBundle.bundle
                )
            )
            return .focusBlocked
        }

        profileState.setFocusOverlay(
            profileID: focusProfileID,
            manualProfileID: manualProfileID
        )
        let needsSwitch = profileState.activeProfileID != focusProfileID
        guard !needsSwitch || completingRecoveryChoice || profileState.canApplyExternalSwitch else {
            profileState.reportFocusFilterStatus(
                String(
                    localized: "A Focus profile change is waiting for the current shortcut edit to finish.",
                    bundle: WinkResourceBundle.bundle
                )
            )
            diagnosticClient.log(
                "FOCUS_FILTER reconcile=deferred reason=\(reason) profileId=\(focusProfileID.uuidString)"
            )
            return .focusDeferred
        }

        let applied = !needsSwitch || (
            completingRecoveryChoice
                ? profileState.reapplyFocusProfileAfterRecoveryChoice(focusProfileID)
                : profileState.applyExternalProfile(focusProfileID)
        )
        guard applied else {
            diagnosticClient.log(
                "FOCUS_FILTER reconcile=apply-failed reason=\(reason) profileId=\(focusProfileID.uuidString)"
            )
            return .focusApplyFailed(focusProfileID)
        }

        let profileName = profileState.focusProfile?.name ?? ""
        profileState.reportFocusFilterStatus(
            String(
                localized: "Focus is using the profile “\(profileName)”. Manual profile changes will be restored when Focus ends.",
                bundle: WinkResourceBundle.bundle
            )
        )
        diagnosticClient.log(
            "FOCUS_FILTER reconcile=applied reason=\(reason) profileId=\(focusProfileID.uuidString)"
        )
        return .focusApplied(focusProfileID)
    }

    private func restoreManualProfile(
        _ manualProfileID: UUID,
        pauseRemainsActive: Bool,
        reason: String,
        manualSelection: Bool = false
    ) -> ReconcileOutcome {
        profileState.setFocusOverlay(
            profileID: nil,
            manualProfileID: manualProfileID,
            restorePending: true
        )
        guard profileState.profiles.contains(where: { $0.id == manualProfileID }) else {
            profileState.reportFocusFilterError(
                String(
                    localized: "The profile saved for restoration after Focus no longer exists. Wink kept the current profile instead of choosing another one.",
                    bundle: WinkResourceBundle.bundle
                )
            )
            diagnosticClient.log(
                "FOCUS_FILTER restore=stale-base reason=\(reason) profileId=\(manualProfileID.uuidString)"
            )
            return .restoreStale
        }
        let needsRestore = profileState.activeProfileID != manualProfileID
        guard !needsRestore || manualSelection || profileState.canApplyExternalSwitch else {
            profileState.reportFocusFilterStatus(
                String(
                    localized: "Restoring the profile from before Focus is waiting for the current shortcut edit to finish.",
                    bundle: WinkResourceBundle.bundle
                )
            )
            return .restoreDeferred
        }
        let restored = !needsRestore || (
            manualSelection
                ? profileState.applyManualProfileAfterFocusEnds(manualProfileID)
                : profileState.applyExternalProfile(manualProfileID)
        )
        guard restored else {
            return .restoreApplyFailed(manualProfileID)
        }
        guard profileState.makeActiveProfilePointerDurable(manualProfileID) else {
            return .restoreApplyFailed(manualProfileID)
        }

        // The caller clears `manualProfileID` in the same locked transaction
        // after this synchronous runtime restore succeeds.
        profileState.clearFocusOverlay()
        let profileName = profileState.activeProfile?.name ?? ""
        let profileSwitchStatus = profileState.profileSwitchStatus(for: manualProfileID)
        let restoredStatus = pauseRemainsActive
            ? String(
                localized: "Restored “\(profileName)”. This Focus still pauses shortcuts.",
                bundle: WinkResourceBundle.bundle
            )
            : String(
                localized: "Focus ended and Wink restored “\(profileName)”.",
                bundle: WinkResourceBundle.bundle
            )
        profileState.reportCompletedFocusFilterStatus(
            restoredStatus,
            profileSwitchStatus: profileSwitchStatus
        )
        diagnosticClient.log(
            "FOCUS_FILTER restore=applied reason=\(reason) profileId=\(manualProfileID.uuidString)"
        )
        return .restored
    }

    private func handle(_ outcome: ReconcileOutcome, reason: String) {
        switch outcome {
        case let .focusApplyFailed(profileID):
            scheduleRetry(for: .focusProfile(profileID), reason: "profile-apply")
        case let .restoreApplyFailed(profileID):
            scheduleRetry(for: .restoreProfile(profileID), reason: "profile-restore")
        case let .focusApplied(profileID):
            cancelRetry()
            diagnosticClient.log(
                "FOCUS_FILTER retry=resolved reason=\(reason) profileId=\(profileID.uuidString)"
            )
        case .focusDeferred,
             .focusBlocked,
             .focusStale,
             .restored,
             .restoreDeferred,
             .restoreStale,
             .inactive:
            cancelRetry()
        }
    }

    private func handleSharedStateFailure(_ error: Error, reason: String) {
        profileState.reportFocusFilterError(message(for: error))
        diagnosticClient.log("FOCUS_FILTER reconcile=failed reason=\(reason) error=\(error)")
        scheduleRetry(for: .sharedState, reason: "shared-state")
    }

    private func scheduleRetry(for key: RetryKey, reason: String) {
        if retryKey != key {
            cancelRetry()
            retryKey = key
        }
        guard retryTask == nil else { return }
        guard retryAttempt < retryDelays.count else {
            diagnosticClient.log(
                "FOCUS_FILTER retry=exhausted reason=\(reason) attempts=\(retryAttempt)"
            )
            return
        }

        let delay = retryDelays[retryAttempt]
        retryAttempt += 1
        diagnosticClient.log(
            "FOCUS_FILTER retry=scheduled reason=\(reason) attempt=\(retryAttempt)"
        )
        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  self.started,
                  self.retryKey == key else { return }
            self.retryTask = nil
            self.reconcile(reason: "automatic-retry-\(reason)")
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryKey = nil
        retryAttempt = 0
    }

    private func saveManualProfileSelection(
        _ profileID: UUID
    ) -> ManualProfileSelectionDuringFocusResult {
        do {
            let transaction = try profileState.withDeferredProfileCatalogPublication {
                try store.updateManualProfileIDAndApply(profileID) { state in
                    preferences.setFocusPauseActive(state.pauseShortcuts)
                    if let focusProfileID = state.profileID {
                        let outcome = applyFocusProfile(
                            focusProfileID,
                            manualProfileID: profileID,
                            reason: "manual-selection-focus-recheck",
                            completingRecoveryChoice: false
                        )
                        return (ManualProfileSelectionDuringFocusResult.focusOverlayActive, outcome)
                    }

                    let outcome = restoreManualProfile(
                        profileID,
                        pauseRemainsActive: state.pauseShortcuts,
                        reason: "manual-during-restore",
                        manualSelection: true
                    )
                    if case .restored = outcome {
                        state.manualProfileID = nil
                        return (ManualProfileSelectionDuringFocusResult.manualProfileApplied, outcome)
                    }
                    return (ManualProfileSelectionDuringFocusResult.failed, outcome)
                }
            }
            diagnosticClient.log(
                "FOCUS_FILTER base=updated profileId=\(profileID.uuidString)"
            )
            handle(transaction.1, reason: "manual-selection")
            return transaction.0
        } catch {
            handleSharedStateFailure(error, reason: "manual-selection")
            return .failed
        }
    }

    private func publishCatalog(_ profiles: [ShortcutProfile]) -> String? {
        let readableProfiles = profiles.filter {
            !profileState.unreadableProfileIDs.contains($0.id)
        }
        let catalog = FocusProfileCatalog(
            profiles: readableProfiles.map { FocusProfileRecord(id: $0.id, name: $0.name) }
        )
        do {
            try store.replaceCatalog(catalog)
            cancelCatalogRetry()
            diagnosticClient.log(
                "FOCUS_FILTER catalog=updated count=\(readableProfiles.count) excludedUnreadable=\(profiles.count - readableProfiles.count)"
            )
            return nil
        } catch {
            diagnosticClient.log("FOCUS_FILTER catalog=failed error=\(error)")
            scheduleCatalogRetry(reason: "catalog-publication")
            return message(for: error)
        }
    }

    private func scheduleCatalogRetry(reason: String) {
        guard catalogRetryTask == nil else { return }
        guard catalogRetryAttempt < retryDelays.count else {
            diagnosticClient.log(
                "FOCUS_FILTER catalog-retry=exhausted reason=\(reason) attempts=\(catalogRetryAttempt)"
            )
            return
        }

        let delay = retryDelays[catalogRetryAttempt]
        catalogRetryAttempt += 1
        diagnosticClient.log(
            "FOCUS_FILTER catalog-retry=scheduled reason=\(reason) attempt=\(catalogRetryAttempt)"
        )
        catalogRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, self.started else { return }
            self.catalogRetryTask = nil
            let error = self.publishCatalog(self.profileState.profiles)
            self.profileState.reportProfileCatalogPublicationError(error)
            if error == nil {
                self.reconcile(reason: "catalog-retry")
            }
        }
    }

    private func cancelCatalogRetry() {
        catalogRetryTask?.cancel()
        catalogRetryTask = nil
        catalogRetryAttempt = 0
    }

    private func prepareProfileDeletion(
        _ profileID: UUID,
        remainingProfiles: [ShortcutProfile]
    ) -> ProfileDeletionPreparationResult {
        let readableProfiles = remainingProfiles.filter {
            !profileState.unreadableProfileIDs.contains($0.id)
        }
        let catalog = FocusProfileCatalog(
            profiles: readableProfiles.map { FocusProfileRecord(id: $0.id, name: $0.name) }
        )
        do {
            switch try store.replaceCatalogForDeletion(catalog, deleting: profileID) {
            case .updated:
                diagnosticClient.log(
                    "FOCUS_FILTER catalog=delete-invalidated profileId=\(profileID.uuidString)"
                )
                return .ready
            case .profileInUse:
                diagnosticClient.log(
                    "FOCUS_FILTER catalog=delete-blocked profileId=\(profileID.uuidString)"
                )
                return .profileInUse
            }
        } catch {
            diagnosticClient.log(
                "FOCUS_FILTER catalog=delete-failed profileId=\(profileID.uuidString) error=\(error)"
            )
            // The atomic catalog replacement happens before its durability
            // barrier. If that barrier fails, canonical deletion is aborted
            // even though the readable catalog may already omit this profile.
            // Restore the still-current canonical list now; a failed repair
            // automatically enters the independent catalog retry lane.
            let restorationError = publishCatalog(profileState.profiles)
            profileState.reportProfileCatalogPublicationError(restorationError)
            diagnosticClient.log(
                "FOCUS_FILTER catalog=delete-rollback profileId=\(profileID.uuidString) restored=\(restorationError == nil)"
            )
            return .failed(message(for: error))
        }
    }

    private func observeExternalSwitchReadiness() {
        withObservationTracking {
            _ = profileState.canApplyExternalSwitch
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.reconcile(reason: "editor-readiness")
                self.observeExternalSwitchReadiness()
            }
        }
    }

    private func message(for error: Error) -> String {
        switch error {
        case FocusFilterSharedStoreError.containerUnavailable:
            String(
                localized: "Wink cannot access its Focus Filter shared container. The app and extension must be signed with the same App Group entitlement.",
                bundle: WinkResourceBundle.bundle
            )
        case FocusFilterSharedStoreError.unreadableState,
             FocusFilterSharedStoreError.unsupportedSchema:
            String(
                localized: "Wink could not read the saved Focus Filter state, so it left the current profile and pause reasons unchanged.",
                bundle: WinkResourceBundle.bundle
            )
        case FocusFilterSharedStoreError.unreadableCatalog:
            String(
                localized: "Wink could not read the Focus Filter profile catalog.",
                bundle: WinkResourceBundle.bundle
            )
        case FocusFilterSharedStoreError.profileNotFound:
            String(
                localized: "The Focus Filter refers to a profile that no longer exists.",
                bundle: WinkResourceBundle.bundle
            )
        default:
            String(
                localized: "Wink could not save Focus Filter state. The current profile was left unchanged.",
                bundle: WinkResourceBundle.bundle
            )
        }
    }
}
