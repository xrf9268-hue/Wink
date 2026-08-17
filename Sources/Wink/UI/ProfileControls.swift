import SwiftUI

enum ProfileBarSelection {
    static func profileID(
        activeProfileID: UUID?,
        focusProfileID: UUID?,
        manualProfileIDDuringFocus: UUID?,
        focusRestorePending: Bool
    ) -> UUID? {
        focusProfileID == nil && !focusRestorePending
            ? activeProfileID
            : manualProfileIDDuringFocus
    }

    static func profileName(
        profiles: [ShortcutProfile],
        selectedProfileID: UUID?
    ) -> String {
        guard let selectedProfileID else { return "" }
        return profiles.first { $0.id == selectedProfileID }?.name ?? ""
    }
}

/// Profile selector plus the recovery banners, shown above the shortcut list.
///
/// Terminology is fixed and must not drift: a **Profile** is one of the user's
/// shortcut sets on *this* Mac, and only one is live at a time; a **Recipe**
/// (`.winkrecipe`) is a file for sharing bindings with other people or other
/// Macs, and importing one imports into the active profile.
struct ProfileBar: View {
    @Environment(\.winkPalette) private var palette

    @Bindable var profileState: ShortcutProfileState
    /// The shortcuts currently armed, needed only to rewrite the compat file
    /// when the user keeps their profile over an outside edit.
    var activeShortcuts: [AppShortcut]

    @State private var showingManager = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Every blocking recovery state hides the selector; the
            // legacy-migration notice does not, because Wink is fully usable
            // and the user still needs to be able to switch profiles.
            if profileState.isMutable {
                selector
            }
            focusOverlayBanner
            recoveryBanner
            foreignMirrorBanner
            messageBanner
        }
        .sheet(isPresented: $showingManager) {
            ProfileManagerSheet(profileState: profileState)
        }
    }

    // MARK: - Selector

    @ViewBuilder
    private var selector: some View {
        HStack(spacing: 10) {
            Text("Profile", bundle: WinkResourceBundle.bundle)
                .font(WinkType.sectionLabel)
                .foregroundStyle(palette.textSecondary)

            // Wink chrome, not a stock Picker: this sits one card above the
            // target-app field, which is the same control at the same size,
            // and an NSPopUpButton matches neither its shape nor its height.
            WinkMenuField(
                selectedProfileName.isEmpty ? placeholderTitle : selectedProfileName,
                isPlaceholder: selectedProfileName.isEmpty
            ) {
                ForEach(profileState.profiles) { profile in
                    // A Toggle, not a Button: it is what puts the mark in the
                    // menu's native check column, so every row's text stays on
                    // the same left edge whether or not it is the active one.
                    // Turning the active row *off* is not a state a profile
                    // list has — there is always exactly one — so an off
                    // transition is deliberately dropped.
                    Toggle(isOn: Binding(
                        get: { profile.id == profileSelection.wrappedValue },
                        set: { isOn in
                            guard isOn else { return }
                            profileState.switchToProfile(profile.id)
                        }
                    )) {
                        Text(profileRowLabel(profile))
                    }
                    // Matches the manager list and the menu bar, which already
                    // refuse these rows. `switchToProfile` rejects them
                    // regardless — a menu row is not a reliable place to
                    // enforce a rule — but offering a row that cannot be
                    // chosen is its own defect.
                    .disabled(profileState.unreadableProfileIDs.contains(profile.id))
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
            .accessibilityLabel(Text("Profile", bundle: WinkResourceBundle.bundle))
            .accessibilityValue(Text(selectedProfileName))

            WinkButton(
                String(localized: "Manage…", bundle: WinkResourceBundle.bundle),
                size: .medium,
                systemImage: "slider.horizontal.3"
            ) {
                showingManager = true
            }
            .accessibilityHint(Text("Create, rename, duplicate, or delete profiles.", bundle: WinkResourceBundle.bundle))

            Spacer(minLength: 0)
        }
    }

    private var profileSelection: Binding<UUID?> {
        Binding(
            get: {
                ProfileBarSelection.profileID(
                    activeProfileID: profileState.activeProfileID,
                    focusProfileID: profileState.focusProfileID,
                    manualProfileIDDuringFocus: profileState.manualProfileIDDuringFocus,
                    focusRestorePending: profileState.focusRestorePending
                )
            },
            set: { newValue in
                guard let newValue else { return }
                profileState.switchToProfile(newValue)
            }
        )
    }

    private var selectedProfileName: String {
        ProfileBarSelection.profileName(
            profiles: profileState.profiles,
            selectedProfileID: profileSelection.wrappedValue
        )
    }

    /// A nil selection is reachable (`manualProfileIDDuringFocus` is optional),
    /// and the old Picker rendered it as an empty well. Say what the control
    /// is for instead — the string already exists for the recovery menu.
    private var placeholderTitle: String {
        String(localized: "Choose a profile", bundle: WinkResourceBundle.bundle)
    }

    @ViewBuilder
    private var focusOverlayBanner: some View {
        if let focusProfile = profileState.focusProfile,
           profileState.isFocusProfileApplied {
            WinkBanner(
                kind: .info,
                title: String(
                    localized: "Focus is using “\(focusProfile.name)”",
                    bundle: WinkResourceBundle.bundle
                ),
                message: String(
                    localized: "Choose another Profile above to change what Wink restores when Focus ends. The Focus profile stays active until then.",
                    bundle: WinkResourceBundle.bundle
                )
            )
        } else if profileState.focusProfile != nil {
            WinkBanner(
                kind: .info,
                title: String(
                    localized: "A Focus profile change is waiting for the current shortcut edit to finish.",
                    bundle: WinkResourceBundle.bundle
                )
            )
        } else if profileState.focusRestorePending,
                  let manualProfile = profileState.manualProfileDuringFocus {
            WinkBanner(
                kind: .info,
                title: String(localized: "Restoring the pre-Focus profile", bundle: WinkResourceBundle.bundle),
                message: String(
                    localized: "Wink will restore “\(manualProfile.name)” as soon as the current shortcut edit is finished.",
                    bundle: WinkResourceBundle.bundle
                )
            )
        }
    }

    private func profileRowLabel(_ profile: ShortcutProfile) -> String {
        profileState.unreadableProfileIDs.contains(profile.id)
            ? String(localized: "\(profile.name) (can't be read)", bundle: WinkResourceBundle.bundle)
            : profile.name
    }

    // MARK: - Banners

    @ViewBuilder
    private var recoveryBanner: some View {
        switch profileState.recovery {
        case .none:
            EmptyView()

        case .storageUnavailable:
            WinkBanner(
                kind: .error,
                title: String(localized: "Wink cannot reach its storage folder", bundle: WinkResourceBundle.bundle),
                message: String(
                    localized: "Shortcuts are not loaded and changes cannot be saved. Check that your home folder is available, then relaunch Wink.",
                    bundle: WinkResourceBundle.bundle
                )
            )

        case let .manifestUnreadable(preservedCopyPath):
            WinkBanner(
                kind: .error,
                title: String(localized: "Wink could not read your profile list", bundle: WinkResourceBundle.bundle),
                message: preservedMessage(
                    String(
                        localized: "No shortcuts are active and nothing can be changed until you recover.",
                        bundle: WinkResourceBundle.bundle
                    ),
                    preservedCopyPath: preservedCopyPath
                )
            ) {
                WinkButton(String(localized: "Recover", bundle: WinkResourceBundle.bundle), variant: .primary) {
                    profileState.recoverFromUnreadableManifest()
                }
            }

        case let .activeProfileAmbiguous(preservedCopyPath):
            WinkBanner(
                kind: .warn,
                title: String(localized: "Wink could not tell which profile was active", bundle: WinkResourceBundle.bundle),
                message: preservedMessage(
                    String(
                        localized: "No shortcuts are active. Choose the profile you want so Wink does not pick one for you.",
                        bundle: WinkResourceBundle.bundle
                    ),
                    preservedCopyPath: preservedCopyPath
                )
            ) {
                profilePickerMenu
            }

        case let .legacyMigrationFailed(preservedCopyPath):
            WinkBanner(
                kind: .warn,
                title: String(
                    localized: "Wink could not read your previous shortcuts file",
                    bundle: WinkResourceBundle.bundle
                ),
                message: preservedMessage(
                    String(
                        localized: "Wink started with an empty profile. Your old file was not changed, so it can still be repaired or imported.",
                        bundle: WinkResourceBundle.bundle
                    ),
                    preservedCopyPath: preservedCopyPath
                )
            ) {
                WinkButton(String(localized: "Dismiss", bundle: WinkResourceBundle.bundle)) {
                    profileState.dismissLegacyMigrationNotice()
                }
            }

        case let .activeProfileUnreadable(profileID, preservedCopyPath):
            WinkBanner(
                kind: .error,
                title: String(
                    localized: "“\(profileName(for: profileID))” could not be read",
                    bundle: WinkResourceBundle.bundle
                ),
                message: preservedMessage(
                    String(
                        localized: "No shortcuts are active. Wink did not switch to another profile on its own — choose one below.",
                        bundle: WinkResourceBundle.bundle
                    ),
                    preservedCopyPath: preservedCopyPath
                )
            ) {
                profilePickerMenu
            }
        }
    }

    @ViewBuilder
    private var profilePickerMenu: some View {
        // Sits inside a recovery banner alongside Recover/Dismiss buttons, so
        // it wears button chrome rather than field chrome.
        WinkMenuButton(placeholderTitle) {
            ForEach(profileState.profiles) { profile in
                Button(profileRowLabel(profile)) {
                    profileState.switchToProfile(profile.id)
                }
                .disabled(profileState.unreadableProfileIDs.contains(profile.id))
            }
        }
        .accessibilityLabel(Text("Choose a profile", bundle: WinkResourceBundle.bundle))
    }

    @ViewBuilder
    private var foreignMirrorBanner: some View {
        if let mirror = profileState.pendingForeignMirror {
            WinkBanner(
                kind: .warn,
                title: String(localized: "shortcuts.json was changed outside Wink", bundle: WinkResourceBundle.bundle),
                message: mirror.shortcuts == nil
                    ? String(
                        localized: "The file no longer matches what Wink last wrote, and its contents could not be read. Wink has changed nothing.",
                        bundle: WinkResourceBundle.bundle
                    )
                    : String(
                        localized: "This usually means an older version of Wink edited it. It can also happen after an unexpected shutdown. Wink has changed nothing yet.",
                        bundle: WinkResourceBundle.bundle
                    )
            ) {
                HStack(spacing: 8) {
                    if mirror.shortcuts != nil {
                        WinkButton(
                            String(
                                localized: "Import into “\(profileName(for: mirror.profileID))”",
                                bundle: WinkResourceBundle.bundle
                            ),
                            variant: .primary
                        ) {
                            profileState.adoptPendingForeignMirror()
                        }
                    }
                    if profileState.canDiscardForeignMirror {
                        WinkButton(String(localized: "Keep this profile", bundle: WinkResourceBundle.bundle)) {
                            profileState.discardPendingForeignMirror(activeShortcuts: activeShortcuts)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var messageBanner: some View {
        if let errorMessage = profileState.errorMessage {
            WinkBanner(kind: .error, title: errorMessage)
        } else if let statusMessage = profileState.statusMessage {
            WinkBanner(kind: .info, title: statusMessage)
        }
    }

    private func profileName(for profileID: UUID) -> String {
        profileState.profiles.first { $0.id == profileID }?.name
            ?? String(localized: "Unknown profile", bundle: WinkResourceBundle.bundle)
    }

    private func preservedMessage(_ base: String, preservedCopyPath: String?) -> String {
        guard let preservedCopyPath else { return base }
        return base + "\n" + String(
            localized: "A copy of the unreadable file was saved to \(preservedCopyPath).",
            bundle: WinkResourceBundle.bundle
        )
    }
}

/// Create / rename / duplicate / delete. Deliberately small: v1 profiles are
/// named shortcut sets, nothing more.
struct ProfileManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.winkPalette) private var palette

    @Bindable var profileState: ShortcutProfileState

    @State private var selection: UUID?
    @State private var renamingProfileID: UUID?
    @State private var nameDraft = ""
    @State private var pendingDeletion: ShortcutProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manage Profiles", bundle: WinkResourceBundle.bundle)
                .font(WinkType.cardTitle)
                .foregroundStyle(palette.textPrimary)

            List(profileState.profiles, selection: $selection) { profile in
                row(for: profile)
                    .tag(profile.id)
            }
            .frame(minHeight: 180)

            if let errorMessage = profileState.errorMessage {
                WinkBanner(kind: .error, title: errorMessage)
            }

            HStack(spacing: 8) {
                WinkMenuButton(
                    String(localized: "Add Profile", bundle: WinkResourceBundle.bundle)
                ) {
                    Button {
                        profileState.createProfile(
                            named: profileState.suggestedDuplicateName(),
                            duplicatingActiveProfile: true
                        )
                    } label: {
                        Text("Duplicate current profile", bundle: WinkResourceBundle.bundle)
                    }
                    .disabled(!profileState.canDuplicateActiveProfile)
                    Button {
                        profileState.createProfile(
                            named: profileState.suggestedNewProfileName(),
                            duplicatingActiveProfile: false
                        )
                    } label: {
                        Text("New empty profile", bundle: WinkResourceBundle.bundle)
                    }
                }
                .disabled(!profileState.canCreateProfile)
                .accessibilityLabel(Text("Add Profile", bundle: WinkResourceBundle.bundle))

                WinkButton(String(localized: "Rename", bundle: WinkResourceBundle.bundle)) {
                    guard let selection,
                          let profile = profileState.profiles.first(where: { $0.id == selection }) else { return }
                    // A leftover error from an earlier create/delete/switch
                    // would render inside the fresh sheet and call an
                    // untouched name invalid before the user typed anything.
                    profileState.errorMessage = nil
                    renamingProfileID = profile.id
                    nameDraft = profile.name
                }
                .disabled(selection == nil || !profileState.isMutable)

                WinkButton(String(localized: "Delete", bundle: WinkResourceBundle.bundle), variant: .danger) {
                    guard let selection,
                          let profile = profileState.profiles.first(where: { $0.id == selection }) else { return }
                    pendingDeletion = profile
                }
                .disabled(
                    selection == nil
                        || selection.map(profileState.canDeleteProfile) != true
                )

                Spacer(minLength: 0)

                WinkButton(String(localized: "Done", bundle: WinkResourceBundle.bundle), variant: .primary) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Text("Recipes import into the active profile. Profiles stay on this Mac; recipes are how you share bindings.", bundle: WinkResourceBundle.bundle)
                .font(WinkType.labelSmall)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { selection = profileState.activeProfileID }
        .sheet(item: $renamingProfileID.map(ProfileIdentifier.init)) { identifier in
            renameSheet(profileID: identifier.id)
        }
        .confirmationDialog(
            Text(
                "Delete “\(pendingDeletion?.name ?? "")”?",
                bundle: WinkResourceBundle.bundle
            ),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                if let pendingDeletion {
                    profileState.deleteProfile(pendingDeletion.id)
                    selection = profileState.activeProfileID
                }
                pendingDeletion = nil
            } label: {
                Text("Delete Profile", bundle: WinkResourceBundle.bundle)
            }
            Button(role: .cancel) { pendingDeletion = nil } label: {
                Text("Cancel", bundle: WinkResourceBundle.bundle)
            }
        } message: {
            Text(
                "Its shortcuts are removed, along with the usage history of shortcuts that exist only in it. Shortcuts that also live in another profile keep their history.",
                bundle: WinkResourceBundle.bundle
            )
        }
    }

    @ViewBuilder
    private func row(for profile: ShortcutProfile) -> some View {
        HStack(spacing: 8) {
            Text(profile.name)
                .font(WinkType.bodyText)
                .foregroundStyle(palette.textPrimary)

            if profileState.unreadableProfileIDs.contains(profile.id) {
                // Text, never colour alone.
                Text("can't be read", bundle: WinkResourceBundle.bundle)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.red)
            }

            Spacer(minLength: 8)

            if profile.id == profileState.activeProfileID {
                Text(
                    profile.id == profileState.focusProfileID ? "Focus Filter" : "active",
                    bundle: WinkResourceBundle.bundle
                )
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.accent)
            } else if profile.id == profileState.manualProfileIDDuringFocus {
                Text("restore after Focus", bundle: WinkResourceBundle.bundle)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func renameSheet(profileID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Profile", bundle: WinkResourceBundle.bundle)
                .font(WinkType.cardTitle)
                .foregroundStyle(palette.textPrimary)

            TextField(
                String(localized: "Profile name", bundle: WinkResourceBundle.bundle),
                text: $nameDraft
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(Text("Profile name", bundle: WinkResourceBundle.bundle))

            // The sheet stays open on a rejected name, so the rejection has
            // to be visible HERE: the manager's message area sits behind
            // this modal, and an invisible error reads as "Rename did
            // nothing".
            if let errorMessage = profileState.errorMessage {
                WinkBanner(kind: .error, title: errorMessage)
            }

            HStack {
                Spacer(minLength: 0)
                WinkButton(String(localized: "Cancel", bundle: WinkResourceBundle.bundle)) {
                    renamingProfileID = nil
                }
                .keyboardShortcut(.cancelAction)

                WinkButton(String(localized: "Rename", bundle: WinkResourceBundle.bundle), variant: .primary) {
                    if profileState.renameProfile(profileID, to: nameDraft) {
                        renamingProfileID = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}

/// `UUID` is not `Identifiable`, and `.sheet(item:)` needs one.
private struct ProfileIdentifier: Identifiable, Hashable, Sendable {
    let id: UUID
}

private extension Binding where Value == UUID? {
    func map<Wrapped: Identifiable & Hashable & Sendable>(
        _ transform: @escaping @Sendable (UUID) -> Wrapped
    ) -> Binding<Wrapped?> {
        Binding<Wrapped?>(
            get: { wrappedValue.map(transform) },
            set: { newValue in
                if newValue == nil { wrappedValue = nil }
            }
        )
    }
}
