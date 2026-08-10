import SwiftUI

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
            if profileState.recovery == .none {
                selector
            }
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

            Picker(
                String(localized: "Profile", bundle: WinkResourceBundle.bundle),
                selection: profileSelection
            ) {
                ForEach(profileState.profiles) { profile in
                    Text(profileRowLabel(profile)).tag(Optional(profile.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220, alignment: .leading)
            .accessibilityLabel(Text("Profile", bundle: WinkResourceBundle.bundle))
            .accessibilityValue(Text(profileState.activeProfile?.name ?? ""))

            WinkButton(
                String(localized: "Manage…", bundle: WinkResourceBundle.bundle),
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
            get: { profileState.activeProfileID },
            set: { newValue in
                guard let newValue else { return }
                profileState.switchToProfile(newValue)
            }
        )
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
        Menu {
            ForEach(profileState.profiles) { profile in
                Button(profileRowLabel(profile)) {
                    profileState.switchToProfile(profile.id)
                }
                .disabled(profileState.unreadableProfileIDs.contains(profile.id))
            }
        } label: {
            Text("Choose a profile", bundle: WinkResourceBundle.bundle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
                        localized: "This usually means an older version of Wink edited it. Wink has changed nothing yet.",
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
                    WinkButton(String(localized: "Keep this profile", bundle: WinkResourceBundle.bundle)) {
                        profileState.discardPendingForeignMirror(activeShortcuts: activeShortcuts)
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
                Menu {
                    Button {
                        profileState.createProfile(
                            named: profileState.suggestedDuplicateName(),
                            duplicatingActiveProfile: true
                        )
                    } label: {
                        Text("Duplicate current profile", bundle: WinkResourceBundle.bundle)
                    }
                    Button {
                        profileState.createProfile(
                            named: String(localized: "New Profile", bundle: WinkResourceBundle.bundle),
                            duplicatingActiveProfile: false
                        )
                    } label: {
                        Text("New empty profile", bundle: WinkResourceBundle.bundle)
                    }
                } label: {
                    Text("Add Profile", bundle: WinkResourceBundle.bundle)
                }
                .disabled(!profileState.canCreateProfile)
                .fixedSize()
                .accessibilityLabel(Text("Add Profile", bundle: WinkResourceBundle.bundle))

                WinkButton(String(localized: "Rename", bundle: WinkResourceBundle.bundle)) {
                    guard let selection,
                          let profile = profileState.profiles.first(where: { $0.id == selection }) else { return }
                    renamingProfileID = profile.id
                    nameDraft = profile.name
                }
                .disabled(selection == nil || !profileState.isMutable)

                WinkButton(String(localized: "Delete", bundle: WinkResourceBundle.bundle), variant: .danger) {
                    guard let selection,
                          let profile = profileState.profiles.first(where: { $0.id == selection }) else { return }
                    pendingDeletion = profile
                }
                .disabled(selection == nil || !profileState.canDeleteProfiles)

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
                Text("active", bundle: WinkResourceBundle.bundle)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.accent)
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

            HStack {
                Spacer(minLength: 0)
                WinkButton(String(localized: "Cancel", bundle: WinkResourceBundle.bundle)) {
                    renamingProfileID = nil
                }
                .keyboardShortcut(.cancelAction)

                WinkButton(String(localized: "Rename", bundle: WinkResourceBundle.bundle), variant: .primary) {
                    profileState.renameProfile(profileID, to: nameDraft)
                    if profileState.errorMessage == nil {
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
private struct ProfileIdentifier: Identifiable, Hashable {
    let id: UUID
}

private extension Binding where Value == UUID? {
    func map<Wrapped: Identifiable & Hashable>(
        _ transform: @escaping (UUID) -> Wrapped
    ) -> Binding<Wrapped?> {
        Binding<Wrapped?>(
            get: { wrappedValue.map(transform) },
            set: { newValue in
                if newValue == nil { wrappedValue = nil }
            }
        )
    }
}
