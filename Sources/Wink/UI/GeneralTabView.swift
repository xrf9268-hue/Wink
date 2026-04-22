import AppKit
import SwiftUI

private enum GeneralTabLinks {
    static let releases = URL(string: "https://github.com/xrf9268-hue/Wink/releases")!
    static let support = URL(string: "https://github.com/xrf9268-hue/Wink/issues")!
    static let privacy = URL(string: "https://github.com/xrf9268-hue/Wink/blob/main/docs/privacy.md")!
}

struct GeneralTabView: View {
    @Environment(\.winkPalette) private var palette

    var preferences: AppPreferences
    @Bindable var editor: ShortcutEditorState

    var body: some View {
        let importPreviewActive = editor.pendingRecipeImport != nil
        let updatePresentation = preferences.updatePresentation

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsTabHeader(
                    title: "General",
                    subtitle: "Startup, keyboard behavior, and updates."
                )

                Form {
                    Section("Startup") {
                        SettingsToggleRow(
                            title: "Launch at Login",
                            subtitle: "Open Wink in the menu bar when you sign in.",
                            isOn: Binding(
                                get: { preferences.launchAtLoginPresentation.toggleIsOn },
                                set: { preferences.setLaunchAtLogin($0) }
                            )
                        )
                        .disabled(!preferences.launchAtLoginPresentation.toggleIsEnabled)

                        if let message = preferences.launchAtLoginPresentation.message {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message)
                                    .font(WinkType.labelSmall)
                                    .foregroundStyle(
                                        preferences.launchAtLoginPresentation.messageStyle == .error
                                            ? palette.red
                                            : palette.textSecondary
                                    )

                                if preferences.launchAtLoginPresentation.showsOpenSettingsButton {
                                    WinkButton("Open Login Items Settings") {
                                        preferences.openLoginItemsSettings()
                                    }
                                }
                            }
                            .padding(.leading, 4)
                        }

                    }

                    Section("Keyboard") {
                        SettingsToggleRow(
                            title: "Enable All Shortcuts",
                            subtitle: "Master switch for global shortcut routing.",
                            isOn: Binding(
                                get: { editor.allEnabled },
                                set: { editor.setAllEnabled($0) }
                            )
                        )
                        .disabled(importPreviewActive)

                        SettingsToggleRow(
                            title: "Hyper Key",
                            subtitleView: {
                                HStack(spacing: 6) {
                                    Text("Hold")
                                    WinkKeycap("Caps Lock", size: .small)
                                    Text("to act as")
                                    WinkKeycap("⌃⌥⇧⌘", size: .small)
                                    Text(".")
                                }
                            },
                            isOn: Binding(
                                get: { preferences.hyperKeyEnabled },
                                set: { preferences.setHyperKeyEnabled($0) }
                            )
                        )

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 16) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("When target is frontmost")
                                        .font(WinkType.bodyMedium)
                                        .foregroundStyle(palette.textPrimary)
                                    Text("How Wink reacts when the target app is already active.")
                                        .font(WinkType.labelSmall)
                                        .foregroundStyle(palette.textSecondary)
                                }

                                Spacer(minLength: 12)

                                Picker("", selection: Binding(
                                    get: { preferences.frontmostTargetBehavior },
                                    set: { preferences.frontmostTargetBehavior = $0 }
                                )) {
                                    ForEach(FrontmostTargetBehavior.allCases, id: \.self) { behavior in
                                        Text(behavior.title).tag(behavior)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 210)
                                .labelsHidden()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(Color.clear)

                WinkCard(
                    title: {
                        Text("Permissions")
                    },
                    accessory: {
                        Text("Required for global shortcuts")
                            .font(WinkType.labelSmall)
                            .foregroundStyle(palette.textTertiary)
                    }
                ) {
                    VStack(spacing: 0) {
                        PermissionSummaryRow(
                            label: "Accessibility",
                            detail: "Routes global shortcuts.",
                            state: preferences.shortcutCaptureStatus.accessibilityGranted
                                ? .granted
                                : .needed
                        )
                        Divider().overlay(palette.hairline)
                        PermissionSummaryRow(
                            label: "Input Monitoring",
                            detail: preferences.shortcutCaptureStatus.inputMonitoringRequired
                                ? "Needed for Hyper-routed shortcuts."
                                : "Only required when a saved shortcut uses Hyper routing.",
                            state: inputMonitoringPresentationState(for: preferences.shortcutCaptureStatus)
                        )
                    }
                }

                WinkCard {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            WinkAppIcon(size: 40)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    WinkWordmark(size: 13, color: palette.textPrimary)
                                    Text(updatePresentation.currentVersion)
                                        .font(WinkType.bodyMedium)
                                        .foregroundStyle(palette.textSecondary)
                                }

                                Text(updateBehaviorDescription(updatePresentation))
                                    .font(WinkType.labelSmall)
                                    .foregroundStyle(palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 8)

                            WinkButton("Check for Updates…") {
                                preferences.checkForUpdates()
                            }
                            .disabled(!updatePresentation.checkForUpdatesEnabled)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                        Divider().overlay(palette.hairline)

                        SettingsToggleRow(
                            title: "Automatic Updates",
                            subtitle: "Reflects the current Sparkle feed defaults for automatic checks and downloads.",
                            isOn: .constant(
                                updatePresentation.automaticChecksEnabledByDefault
                                    && updatePresentation.automaticDownloadsEnabledByDefault
                            )
                        )
                        .disabled(true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }

                HStack(spacing: 8) {
                    Link("Release Notes", destination: GeneralTabLinks.releases)
                    Text("·")
                        .foregroundStyle(palette.textTertiary)
                    Link("Privacy", destination: GeneralTabLinks.privacy)
                    Text("·")
                        .foregroundStyle(palette.textTertiary)
                    Link("Support", destination: GeneralTabLinks.support)
                }
                .font(WinkType.labelSmall)
                .foregroundStyle(palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .background(palette.windowBg)
    }

    private func inputMonitoringPresentationState(for status: ShortcutCaptureStatus) -> PermissionSummaryState {
        if status.inputMonitoringRequired {
            return status.inputMonitoringGranted ? .granted : .needed
        }

        return status.inputMonitoringGranted ? .granted : .optional
    }

    private func updateBehaviorDescription(_ presentation: UpdatePresentation) -> String {
        guard presentation.isConfigured else {
            return "Automatic updates become available after this build is configured with a signed Sparkle appcast feed."
        }

        if presentation.automaticChecksEnabledByDefault && presentation.automaticDownloadsEnabledByDefault {
            return "Automatic update checks and downloads are enabled."
        }

        if presentation.automaticChecksEnabledByDefault {
            return "Wink checks for updates automatically and asks before downloading."
        }

        return "Automatic update checks are disabled by default."
    }
}

private struct PermissionSummaryRow: View {
    @Environment(\.winkPalette) private var palette

    let label: String
    let detail: String
    let state: PermissionSummaryState

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(state.backgroundColor(in: palette))
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: state.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(state.foregroundColor(in: palette))
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(WinkType.bodyMedium)
                    .foregroundStyle(palette.textPrimary)
                Text(detail)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer(minLength: 8)

            Text(state.label)
                .font(WinkType.captionStrong)
                .foregroundStyle(state.foregroundColor(in: palette))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private enum PermissionSummaryState {
    case granted
    case needed
    case optional

    var label: String {
        switch self {
        case .granted: return "Granted"
        case .needed: return "Needed"
        case .optional: return "Optional"
        }
    }

    var systemImage: String {
        switch self {
        case .granted: return "checkmark"
        case .needed: return "exclamationmark"
        case .optional: return "minus"
        }
    }

    func backgroundColor(in palette: WinkPalette.Tokens) -> Color {
        switch self {
        case .granted: return palette.greenSoft
        case .needed: return palette.amberBgSoft
        case .optional: return palette.controlBgRest
        }
    }

    func foregroundColor(in palette: WinkPalette.Tokens) -> Color {
        switch self {
        case .granted: return palette.green
        case .needed: return palette.amber
        case .optional: return palette.textSecondary
        }
    }
}

private struct SettingsToggleRow<SubtitleView: View>: View {
    @Environment(\.winkPalette) private var palette

    let title: String
    @ViewBuilder let subtitleView: () -> SubtitleView
    let isOn: Binding<Bool>

    init(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) where SubtitleView == Text {
        self.title = title
        self.subtitleView = {
            Text(subtitle)
        }
        self.isOn = isOn
    }

    init(
        title: String,
        @ViewBuilder subtitleView: @escaping () -> SubtitleView,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.subtitleView = subtitleView
        self.isOn = isOn
    }

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(WinkType.bodyMedium)
                    .foregroundStyle(palette.textPrimary)
                subtitleView()
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .toggleStyle(.switch)
    }
}
