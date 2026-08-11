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

    /// The seam #438's Focus Filter automation must consult before applying an
    /// automatic switch. A manual switch may discard the user's drafts because
    /// the user asked for it; an automatic one must defer.
    var canApplyExternalSwitch: Bool {
        isMutable && recovery == .none && !hasUnsavedEditorWork()
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

    private func apply(_ loaded: ShortcutProfileStore.LoadedProfiles) {
        profiles = loaded.profiles
        activeProfileID = loaded.activeProfileID
        unreadableProfileIDs = loaded.unreadableProfileIDs
        orphanProfileIDs = loaded.orphanProfileIDs
        duplicateShortcutIDs = loaded.duplicateShortcutIDs
        pendingForeignMirror = loaded.foreignMirror
        recovery = .none
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

        let discarded = prepareForSwitch()

        do {
            let shortcuts = try store.activateProfile(profileID)
            activeProfileID = profileID
            unreadableProfileIDs.remove(profileID)
            recovery = .none
            // The pointer is already committed; this is the same synchronous
            // main-actor apply an ordinary save performs, so no observable
            // state mixes the outgoing store with the incoming index.
            shortcutManager.applyLoadedShortcuts(shortcuts, source: .profileSwitch)
            onProfileApplied()
            errorMessage = nil
            statusMessage = switchedMessage(discarded: discarded)
        } catch {
            // A refused switch writes nothing and applies nothing — but the
            // drafts are already gone, so say so rather than leaving the user
            // wondering where their recording went.
            errorMessage = userFacingMessage(for: error)
            if !discarded.isEmpty {
                statusMessage = discardedMessage(discarded)
            }
        }
    }

    // MARK: - CRUD

    func createProfile(named rawName: String, duplicatingActiveProfile: Bool) {
        guard canCreateProfile else {
            errorMessage = isMutable ? profileLimitMessage : recoveryBlockedMessage
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

        let switchesActive = profileID == activeProfileID
        let discarded = switchesActive ? prepareForSwitch() : DiscardedProfileSwitchDrafts()

        do {
            let outcome = try store.deleteProfile(profileID)
            profiles = outcome.profiles
            unreadableProfileIDs.remove(profileID)

            if let newActiveProfileID = outcome.newActiveProfileID,
               let newActiveShortcuts = outcome.newActiveShortcuts {
                activeProfileID = newActiveProfileID
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

            // Only IDs this profile exclusively owned: a shortcut that still
            // exists in another profile keeps its history.
            if let usageTracker, !outcome.exclusivelyOwnedShortcutIDs.isEmpty {
                let ids = outcome.exclusivelyOwnedShortcutIDs
                Task {
                    for id in ids {
                        await usageTracker.deleteUsage(shortcutId: id)
                    }
                }
            }

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

    func discardPendingForeignMirror(activeShortcuts: [AppShortcut]) {
        guard pendingForeignMirror != nil else { return }
        store.discardForeignMirror(activeShortcuts: activeShortcuts)
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
