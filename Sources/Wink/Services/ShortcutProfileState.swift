import Foundation
import Observation

/// Drafts a whole-configuration replacement would otherwise carry into the
/// wrong profile. Returned so the caller can tell the user what went — the
/// requirement is not that nothing is discarded, but that nothing is discarded
/// *silently*.
struct DiscardedProfileSwitchDrafts: Equatable, Sendable {
    var cancelledRecorder = false
    var discardedComposerDraft = false
    var discardedImportPreview = false

    var isEmpty: Bool {
        !cancelledRecorder && !discardedComposerDraft && !discardedImportPreview
    }
}

/// Observable profile list, active selection, and recovery state, plus the
/// user-facing actions that mutate them.
///
/// Switching itself is deliberately thin: the store validates and commits the
/// active pointer, and `ShortcutManager.applyLoadedShortcuts` performs the one
/// synchronous main-actor apply that an ordinary save already performs. This
/// type owns sequencing and messaging, never capture state.
@MainActor
@Observable
final class ShortcutProfileState {
    enum Recovery: Equatable, Sendable {
        case none
        case storageUnavailable
        /// Nothing may be written until the user chooses to recover.
        case manifestUnreadable(preservedCopyPath: String?)
        /// The profile list is fine but the active one cannot be determined
        /// without guessing. The user must pick; nothing is auto-selected.
        case activeProfileAmbiguous(preservedCopyPath: String?)
        case activeProfileUnreadable(profileID: UUID, preservedCopyPath: String?)
        /// The store is healthy and an empty Default profile exists, but the
        /// legacy shortcuts file could not be read during first-run migration.
        /// Non-blocking: Wink is usable, but the user must be told rather than
        /// shown an apparently ordinary empty install.
        case legacyMigrationFailed(preservedCopyPath: String?)
    }

    private(set) var profiles: [ShortcutProfile] = []
    private(set) var activeProfileID: UUID?
    private(set) var unreadableProfileIDs: Set<UUID> = []
    private(set) var orphanProfileIDs: Set<UUID> = []
    private(set) var duplicateShortcutIDs: Set<UUID> = []
    private(set) var recovery: Recovery = .none
    private(set) var pendingForeignMirror: ShortcutProfileStore.ForeignMirror?

    var errorMessage: String?
    var statusMessage: String?

    private let store: ShortcutProfileStore
    private let shortcutManager: ShortcutManager
    private let usageTracker: (any UsageTracking)?
    private let prepareForSwitch: @MainActor () -> DiscardedProfileSwitchDrafts
    private let hasUnsavedEditorWork: @MainActor () -> Bool
    private let onProfileApplied: @MainActor () -> Void

    init(
        store: ShortcutProfileStore,
        shortcutManager: ShortcutManager,
        usageTracker: (any UsageTracking)? = nil,
        prepareForSwitch: @escaping @MainActor () -> DiscardedProfileSwitchDrafts = { DiscardedProfileSwitchDrafts() },
        hasUnsavedEditorWork: @escaping @MainActor () -> Bool = { false },
        onProfileApplied: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.shortcutManager = shortcutManager
        self.usageTracker = usageTracker
        self.prepareForSwitch = prepareForSwitch
        self.hasUnsavedEditorWork = hasUnsavedEditorWork
        self.onProfileApplied = onProfileApplied
    }

    // MARK: - Derived state

    var activeProfile: ShortcutProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    /// False while the profile list is quarantined: every mutation is blocked
    /// until the user explicitly recovers, so nothing can overwrite a file
    /// whose contents were never understood.
    var isMutable: Bool {
        if case .manifestUnreadable = recovery { return false }
        if case .storageUnavailable = recovery { return false }
        return true
    }

    var canCreateProfile: Bool {
        isMutable && profiles.count < ShortcutProfileManifest.maximumProfileCount
    }

    var canDeleteProfiles: Bool {
        isMutable && profiles.count > 1
    }

    /// Duplication needs something to duplicate. `activeProfileAmbiguous` and
    /// `activeProfileUnreadable` leave the manager usable — the user is meant
    /// to be able to pick a profile out of them — but with no active profile,
    /// so the command has no source and would silently produce an EMPTY
    /// profile under a name promising a copy.
    var canDuplicateActiveProfile: Bool {
        canCreateProfile && activeProfileID != nil
    }

    /// The seam #438's Focus Filter automation must consult before applying an
    /// automatic switch. A manual switch may discard the user's drafts because
    /// the user asked for it; an automatic one must defer.
    var canApplyExternalSwitch: Bool {
        // The legacy-migration notice is informational, so it must not block
        // automation the way an unresolved active-profile state does.
        let blockedByRecovery: Bool
        switch recovery {
        case .none, .legacyMigrationFailed: blockedByRecovery = false
        case .storageUnavailable, .manifestUnreadable, .activeProfileAmbiguous, .activeProfileUnreadable:
            blockedByRecovery = true
        }
        return isMutable && !blockedByRecovery && !hasUnsavedEditorWork()
    }

    // MARK: - Startup

    /// Loads the profile store and returns the shortcuts the runtime should
    /// arm. Every failing state returns an **empty** array: an unreadable
    /// configuration must never fall through to a different profile's
    /// bindings.
    func loadAtStartup() -> [AppShortcut] {
        switch store.load() {
        case let .ready(loaded):
            apply(loaded)
            // A crash between a delete and its usage cleanup leaves the ids in
            // the manifest; this is where they get retried.
            drainPendingUsageDeletions()
            return loaded.activeShortcuts

        case .storageUnavailable:
            reset(recovery: .storageUnavailable)
            return []

        case let .manifestUnreadable(preservedCopyPath):
            reset(recovery: .manifestUnreadable(preservedCopyPath: preservedCopyPath))
            return []

        case let .activeProfileAmbiguous(profiles, preservedCopyPath):
            reset(recovery: .activeProfileAmbiguous(preservedCopyPath: preservedCopyPath))
            self.profiles = profiles
            return []

        case let .activeProfileUnreadable(profiles, activeProfileID, preservedCopyPath, importableMirror):
            reset(
                recovery: .activeProfileUnreadable(
                    profileID: activeProfileID,
                    preservedCopyPath: preservedCopyPath
                )
            )
            self.profiles = profiles
            self.unreadableProfileIDs = [activeProfileID]
            // An interrupted first-run migration leaves an intact legacy file
            // with nothing pointing at it; offering it through the same
            // import banner turns a dead end into a choice.
            self.pendingForeignMirror = importableMirror
            return []
        }
    }

    /// Deletes the usage rows a completed profile deletion still owes, then
    /// clears the journal. Safe to call at any time — the journal is empty in
    /// the ordinary case — so startup drains anything a crash stranded.
    func drainPendingUsageDeletions() {
        // Re-checked against the profiles that exist NOW, not trusted from the
        // journal: a restored manifest can owe a deletion for an id a live
        // profile still holds, and that history is not recoverable once gone.
        let deletable = store.drainableUsageDeletions().deletable
        guard let usageTracker, !deletable.isEmpty else { return }
        Task { [weak self] in
            // Only the ids whose rows are confirmed gone leave the journal. A
            // failed delete keeps its entry so the next launch retries it —
            // clearing it would strand the rows with no record that they were
            // ever owed a deletion.
            var deleted: [UUID] = []
            for id in deletable where await usageTracker.deleteUsage(shortcutId: id) {
                deleted.append(id)
            }
            guard !deleted.isEmpty else { return }
            await MainActor.run { self?.store.clearPendingUsageDeletions(deleted) }
        }
    }

    private func apply(_ loaded: ShortcutProfileStore.LoadedProfiles) {
        profiles = loaded.profiles
        activeProfileID = loaded.activeProfileID
        unreadableProfileIDs = loaded.unreadableProfileIDs
        orphanProfileIDs = loaded.orphanProfileIDs
        duplicateShortcutIDs = loaded.duplicateShortcutIDs
        pendingForeignMirror = loaded.foreignMirror
        // A migration that could not read the legacy file leaves a healthy but
        // EMPTY configuration. Reporting .none here would present the user's
        // vanished shortcuts as an ordinary fresh install.
        if let failure = loaded.legacyMigrationFailure {
            recovery = .legacyMigrationFailed(preservedCopyPath: failure.preservedCopyPath)
        } else {
            recovery = .none
        }
    }

    private func reset(recovery: Recovery) {
        profiles = []
        activeProfileID = nil
        unreadableProfileIDs = []
        orphanProfileIDs = []
        duplicateShortcutIDs = []
        pendingForeignMirror = nil
        self.recovery = recovery
    }

    // MARK: - Switching

    func switchToProfile(_ profileID: UUID) {
        guard profileID != activeProfileID || recovery != .none else { return }
        guard isMutable else {
            errorMessage = recoveryBlockedMessage
            return
        }

        // Everything that can refuse the switch runs FIRST, and writes nothing:
        // validation, then the commit-time re-check inside `commitActivation`.
        // `prepareForSwitch()` cancels the recorder, the composer draft, and
        // any pending import, so it must not run for a switch that can still
        // be refused — the rule is not "validate early", it is "discard only
        // once nothing can abort".
        let payload: ShortcutProfileStore.ValidatedProfilePayload
        do {
            payload = try store.loadProfileForActivation(profileID)
        } catch {
            errorMessage = userFacingMessage(for: error)
            return
        }

        do {
            try store.commitActivation(profileID, payload: payload)
        } catch {
            // Nothing written, nothing applied, and nothing discarded.
            errorMessage = userFacingMessage(for: error)
            return
        }

        // Past the last abort point: the pointer is durable, so the switch is
        // going to happen and the drafts can be cleared. Between the commit and
        // the apply the runtime is still on the outgoing set, which is the same
        // persist-then-mutate ordering an ordinary save already uses.
        let discarded = prepareForSwitch()
        activeProfileID = profileID
        unreadableProfileIDs.remove(profileID)
        recovery = .none
        // The same synchronous main-actor apply an ordinary save performs, so
        // no observable state mixes the outgoing store with the incoming index.
        shortcutManager.applyLoadedShortcuts(payload.shortcuts, source: .profileSwitch)
        onProfileApplied()
        errorMessage = nil
        statusMessage = switchedMessage(discarded: discarded)
    }

    // MARK: - CRUD

    func createProfile(named rawName: String, duplicatingActiveProfile: Bool) {
        guard canCreateProfile else {
            errorMessage = isMutable ? profileLimitMessage : recoveryBlockedMessage
            return
        }

        // Belt and braces with the disabled command: falling back to an empty
        // profile here would report success for something the user did not ask
        // for, and an empty binding set is not a near miss of a copy.
        guard !duplicatingActiveProfile || activeProfileID != nil else {
            errorMessage = noActiveProfileToDuplicateMessage
            return
        }

        do {
            let created = try store.createProfile(
                named: rawName,
                duplicating: duplicatingActiveProfile ? activeProfileID : nil
            )
            profiles = store.manifest?.profiles ?? profiles
            errorMessage = nil
            statusMessage = String(
                localized: "Created the profile “\(created.name)”.",
                bundle: WinkResourceBundle.bundle
            )
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    /// A free name for a brand-new empty profile. "New Profile" is only the
    /// base: submitting it unconditionally means the second use always fails
    /// duplicate-name validation for a reason the user did nothing to cause.
    func suggestedNewProfileName() -> String {
        let base = String(localized: "New Profile", bundle: WinkResourceBundle.bundle)
        guard ShortcutProfileNameRules.violation(for: base, in: profiles) != nil else { return base }
        return ShortcutProfileNameRules.duplicateName(
            basedOn: base,
            in: profiles,
            fallbackSuffix: activeProfileID ?? UUID()
        )
    }

    /// The name a Duplicate action should pre-fill.
    func suggestedDuplicateName() -> String {
        guard let activeProfile else {
            return String(localized: "New Profile", bundle: WinkResourceBundle.bundle)
        }
        return ShortcutProfileNameRules.duplicateName(
            basedOn: activeProfile.name,
            in: profiles,
            fallbackSuffix: activeProfile.id
        )
    }

    func renameProfile(_ profileID: UUID, to rawName: String) {
        guard isMutable else {
            errorMessage = recoveryBlockedMessage
            return
        }
        do {
            _ = try store.renameProfile(profileID, to: rawName)
            profiles = store.manifest?.profiles ?? profiles
            errorMessage = nil
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func deleteProfile(_ profileID: UUID) {
        guard canDeleteProfiles else {
            errorMessage = isMutable ? lastProfileMessage : recoveryBlockedMessage
            return
        }

        // `activeProfileID` is nil in the unreadable-active recovery state, but
        // the store follows the DURABLE pointer — so deleting the profile it
        // names does switch, and the drafts and HUDs have to be cleared for it
        // exactly as for an ordinary switch.
        let deletesPointedProfile: Bool
        if case let .activeProfileUnreadable(recoveringProfileID, _) = recovery {
            deletesPointedProfile = recoveringProfileID == profileID
        } else {
            deletesPointedProfile = false
        }
        let switchesActive = profileID == activeProfileID || deletesPointedProfile

        // Planned BEFORE anything is discarded, exactly as a switch is. An
        // active-profile delete whose successor cannot be read throws, and
        // running `prepareForSwitch()` first would take the recorder, the
        // composer draft, and any pending import with it for nothing.
        let plan: ShortcutProfileStore.DeletionPlan
        do {
            plan = try store.planDeletion(of: profileID)
        } catch {
            errorMessage = userFacingMessage(for: error)
            return
        }

        var discarded = DiscardedProfileSwitchDrafts()

        do {
            // Same rule as a switch: `deleteProfile` can still refuse — the
            // successor may have changed under the plan, or the manifest write
            // may fail — so nothing is discarded until it has returned.
            let outcome = try store.deleteProfile(plan)
            if switchesActive {
                discarded = prepareForSwitch()
            }
            profiles = outcome.profiles
            // Only when the profile is actually gone. On the unrecoverable
            // path the manifest still lists it and its file survives, so
            // marking it readable would hide the one piece of state that
            // tells the user what is wrong with it.
            if outcome.unrecoverableSwitchReason == nil {
                unreadableProfileIDs.remove(profileID)
                // The outside-edit banner addresses a profile by id, so once
                // that profile is gone its "Import into <name>" action can only
                // fail with profileNotFound, and the name it renders has no
                // profile to come from. Dropping the offer loses nothing: the
                // edited bytes are still in shortcuts.json, and the next write
                // preserves them beside it rather than overwriting silently.
                if pendingForeignMirror?.profileID == profileID {
                    pendingForeignMirror = nil
                }
            }

            if let newActiveProfileID = outcome.newActiveProfileID,
               let newActiveShortcuts = outcome.newActiveShortcuts {
                activeProfileID = newActiveProfileID
                // Deleting the pointed-but-unreadable profile resolves the
                // very state the banner describes. Leaving it up would keep
                // telling the user no shortcuts are active while a successor
                // is loaded and armed.
                //
                // Not on the unrecoverable path, though: there the delete
                // failed and the profile is still there and still unreadable,
                // so clearing the banner — and with it a resumable import —
                // would remove the only guidance the user has.
                if case .activeProfileUnreadable = recovery, outcome.unrecoverableSwitchReason == nil {
                    recovery = .none
                    pendingForeignMirror = nil
                }
                unreadableProfileIDs.remove(newActiveProfileID)
                shortcutManager.applyLoadedShortcuts(newActiveShortcuts, source: .profileSwitch)
                onProfileApplied()
            }

            if outcome.unrecoverableSwitchReason != nil {
                // The delete failed, but the switch it had already committed
                // could not be undone. Memory now matches the durable pointer,
                // which is the only state that cannot surprise the user later.
                errorMessage = String(
                    localized: "The profile could not be deleted, and Wink could not undo the switch it had already made. You are now on “\(activeProfile?.name ?? "")”.",
                    bundle: WinkResourceBundle.bundle
                )
                statusMessage = discarded.isEmpty ? nil : discardedMessage(discarded)
                return
            }

            drainPendingUsageDeletions()

            errorMessage = nil
            statusMessage = discarded.isEmpty ? nil : discardedMessage(discarded)
        } catch {
            errorMessage = userFacingMessage(for: error)
            // The drafts were cleared before the store was asked, so a failure
            // here must still say what went — otherwise the UI reports that
            // nothing changed while the user's recording is gone.
            if !discarded.isEmpty {
                statusMessage = discardedMessage(discarded)
            }
        }
    }

    // MARK: - Recovery actions

    /// Clears the non-blocking legacy-migration notice. The preserved file is
    /// left exactly where it is — dismissing the banner acknowledges it, it
    /// does not discard anything.
    func dismissLegacyMigrationNotice() {
        guard case .legacyMigrationFailed = recovery else { return }
        recovery = .none
    }

    func recoverFromUnreadableManifest() {
        do {
            let recovered = try store.recoverManifest()
            apply(recovered)
            shortcutManager.applyLoadedShortcuts(recovered.activeShortcuts, source: .profileSwitch)
            onProfileApplied()
            errorMessage = nil
            statusMessage = String(
                localized: "Started a new profile list. Your unreadable file was kept alongside it.",
                bundle: WinkResourceBundle.bundle
            )
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func adoptPendingForeignMirror() {
        guard let mirror = pendingForeignMirror else { return }
        do {
            if let adopted = try store.adoptForeignMirror(mirror) {
                // The store re-commits the pointer when this import is what
                // repaired an unloadable active profile, so clearing the
                // recovery state here is what turns the banner off and puts
                // the profile back in the picker.
                activeProfileID = mirror.profileID
                unreadableProfileIDs.remove(mirror.profileID)
                if case .activeProfileUnreadable = recovery {
                    recovery = .none
                    profiles = store.manifest?.profiles ?? profiles
                }
                shortcutManager.applyLoadedShortcuts(adopted, source: .profileSwitch)
                onProfileApplied()
            }
            pendingForeignMirror = nil
            errorMessage = nil
            statusMessage = String(
                localized: "Imported the changes made outside Wink.",
                bundle: WinkResourceBundle.bundle
            )
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    /// True only when there is an active profile whose bindings could replace
    /// the file. During the interrupted-migration recovery there is not, so
    /// the UI must not offer this — the import is the user's only way back.
    var canDiscardForeignMirror: Bool {
        activeProfileID != nil
    }

    func discardPendingForeignMirror(activeShortcuts: [AppShortcut]) {
        guard pendingForeignMirror != nil else { return }
        guard store.discardForeignMirror(activeShortcuts: activeShortcuts) else {
            // Nothing was written, so the mirror stays on offer. Clearing it
            // here would remove the only recovery available while the profile
            // is still unusable.
            errorMessage = String(
                localized: "There is no active profile to keep yet. Import the file first, or choose a profile.",
                bundle: WinkResourceBundle.bundle
            )
            return
        }
        pendingForeignMirror = nil
        errorMessage = nil
    }

    // MARK: - Messages

    private var recoveryBlockedMessage: String {
        String(
            localized: "Wink could not read your profile list, so nothing can be changed until you recover it.",
            bundle: WinkResourceBundle.bundle
        )
    }

    private var noActiveProfileToDuplicateMessage: String {
        String(
            localized: "Choose a profile before duplicating it.",
            bundle: WinkResourceBundle.bundle
        )
    }

    private var profileLimitMessage: String {
        String(
            localized: "You can have at most \(ShortcutProfileManifest.maximumProfileCount) profiles.",
            bundle: WinkResourceBundle.bundle
        )
    }

    private var lastProfileMessage: String {
        String(
            localized: "Wink always keeps at least one profile.",
            bundle: WinkResourceBundle.bundle
        )
    }

    private func switchedMessage(discarded: DiscardedProfileSwitchDrafts) -> String? {
        discarded.isEmpty ? nil : discardedMessage(discarded)
    }

    private func discardedMessage(_ discarded: DiscardedProfileSwitchDrafts) -> String {
        if discarded.discardedImportPreview {
            return String(
                localized: "Switching profiles discarded the recipe import preview, which was prepared for the previous profile.",
                bundle: WinkResourceBundle.bundle
            )
        }
        if discarded.cancelledRecorder {
            return String(
                localized: "Switching profiles stopped the shortcut recording in progress.",
                bundle: WinkResourceBundle.bundle
            )
        }
        return String(
            localized: "Switching profiles discarded the shortcut you were about to add.",
            bundle: WinkResourceBundle.bundle
        )
    }

    private func userFacingMessage(for error: Error) -> String {
        guard let storeError = error as? ShortcutProfileStore.StoreError else {
            return error.localizedDescription
        }

        switch storeError {
        case .storageUnavailable:
            return String(
                localized: "Wink cannot reach its storage folder, so profiles cannot be changed.",
                bundle: WinkResourceBundle.bundle
            )
        case .writeFailed:
            return String(
                localized: "Wink could not save the change to disk, so nothing was changed.",
                bundle: WinkResourceBundle.bundle
            )
        case .profileNotFound:
            return String(
                localized: "That profile no longer exists.",
                bundle: WinkResourceBundle.bundle
            )
        case .profileUnreadable:
            return String(
                localized: "That profile’s shortcuts could not be read, so Wink did not switch to it. A copy of the unreadable file was kept.",
                bundle: WinkResourceBundle.bundle
            )
        case .profileChangedDuringOperation:
            return String(
                localized: "That profile changed while Wink was switching to it, so nothing was applied. Try again.",
                bundle: WinkResourceBundle.bundle
            )
        case let .nameRejected(violation):
            switch violation {
            case .empty:
                return String(localized: "Enter a profile name.", bundle: WinkResourceBundle.bundle)
            case let .tooLong(limit):
                return String(
                    localized: "Profile names can be at most \(limit) characters.",
                    bundle: WinkResourceBundle.bundle
                )
            case .duplicate:
                return String(
                    localized: "Another profile already uses that name.",
                    bundle: WinkResourceBundle.bundle
                )
            }
        case .profileLimitReached:
            return profileLimitMessage
        case .cannotDeleteLastProfile:
            return lastProfileMessage
        case .manifestQuarantined:
            return recoveryBlockedMessage
        }
    }
}
