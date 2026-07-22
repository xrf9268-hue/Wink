import AppKit
import Foundation
import SwiftUI

private enum GeneralTabLinks {
    static let releases = URL(string: "https://github.com/xrf9268-hue/Wink/releases")!
    static let support = URL(string: "https://github.com/xrf9268-hue/Wink/issues")!
    static let privacy = URL(string: "https://github.com/xrf9268-hue/Wink/blob/main/docs/privacy.md")!
}

struct GeneralTabView: View {
    @Environment(\.winkPalette) private var palette
    @AppStorage(AppPreferences.menuBarIconVisibleDefaultsKey)
    private var menuBarIconVisible = true

    var preferences: AppPreferences
    @Bindable var editor: ShortcutEditorState

    var body: some View {
        let importPreviewActive = editor.pendingRecipeImport != nil
        let updatePresentation = preferences.updatePresentation

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                SettingsTabHeader(
                    title: String(localized: "General", bundle: WinkResourceBundle.bundle),
                    subtitle: String(localized: "Startup, keyboard behavior, and updates.", bundle: WinkResourceBundle.bundle)
                )

                startupCard

                keyboardCard(importPreviewActive: importPreviewActive)

                searchPaletteCard(importPreviewActive: importPreviewActive)

                WinkCard(
                    title: {
                        Text("Permissions", bundle: WinkResourceBundle.bundle)
                    },
                    accessory: {
                        Text("Required for global shortcuts", bundle: WinkResourceBundle.bundle)
                            .font(WinkType.labelSmall)
                            .foregroundStyle(palette.textTertiary)
                    }
                ) {
                    VStack(spacing: 0) {
                        PermissionSummaryRow(
                            label: String(localized: "Accessibility", bundle: WinkResourceBundle.bundle),
                            detail: String(localized: "Routes global shortcuts.", bundle: WinkResourceBundle.bundle),
                            state: preferences.shortcutCaptureStatus.accessibilityGranted
                                ? .granted
                                : .needed
                        )
                        Divider().overlay(palette.hairline)
                        PermissionSummaryRow(
                            label: String(localized: "Input Monitoring", bundle: WinkResourceBundle.bundle),
                            detail: preferences.shortcutCaptureStatus.inputMonitoringRequired
                                ? String(localized: "Needed for the current shortcut configuration.", bundle: WinkResourceBundle.bundle)
                                : String(localized: "Not required for the current shortcut configuration.", bundle: WinkResourceBundle.bundle),
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

                            WinkButton(String(localized: "Check for Updates…", bundle: WinkResourceBundle.bundle)) {
                                preferences.checkForUpdates()
                            }
                            .disabled(!updatePresentation.checkForUpdatesEnabled)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                        Divider().overlay(palette.hairline)

                        SettingsToggleRow(
                            title: String(localized: "Automatic Updates", bundle: WinkResourceBundle.bundle),
                            subtitle: String(localized: "Download and install new versions in the background.", bundle: WinkResourceBundle.bundle),
                            isOn: Binding(
                                get: { preferences.automaticUpdatesEnabled },
                                set: { preferences.setAutomaticUpdatesEnabled($0) }
                            )
                        )
                        .disabled(!updatePresentation.isConfigured)
                    }
                }

                HStack(spacing: 8) {
                    Link(destination: GeneralTabLinks.releases) {
                        Text("Release Notes", bundle: WinkResourceBundle.bundle)
                    }
                    Text("·")
                        .foregroundStyle(palette.textTertiary)
                    Link(destination: GeneralTabLinks.privacy) {
                        Text("Privacy", bundle: WinkResourceBundle.bundle)
                    }
                    Text("·")
                        .foregroundStyle(palette.textTertiary)
                    Link(destination: GeneralTabLinks.support) {
                        Text("Support", bundle: WinkResourceBundle.bundle)
                    }
                }
                .font(WinkType.labelSmall)
                .foregroundStyle(palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(palette.windowBg)
    }

    private var startupCard: some View {
        WinkCard {
            VStack(alignment: .leading, spacing: 0) {
                SettingsToggleRow(
                    title: String(localized: "Launch at Login", bundle: WinkResourceBundle.bundle),
                    subtitle: String(localized: "Opens Wink in the menu bar when you sign in.", bundle: WinkResourceBundle.bundle),
                    isOn: Binding(
                        get: { preferences.launchAtLoginPresentation.toggleIsOn },
                        set: { preferences.setLaunchAtLogin($0) }
                    )
                )
                .disabled(!preferences.launchAtLoginPresentation.toggleIsEnabled)

                Divider().overlay(palette.hairline)

                SettingsToggleRow(
                    title: String(localized: "Show Menu Bar Icon", bundle: WinkResourceBundle.bundle),
                    subtitle: String(localized: "Hide the icon if you prefer a minimal menu bar.", bundle: WinkResourceBundle.bundle),
                    isOn: $menuBarIconVisible
                )

                if let message = preferences.launchAtLoginPresentation.message {
                    Divider().overlay(palette.hairline)
                    WinkBanner(
                        kind: preferences.launchAtLoginPresentation.messageStyle == .error ? .error : .info,
                        title: message
                    ) {
                        if preferences.launchAtLoginPresentation.showsOpenSettingsButton {
                            WinkButton(String(localized: "Open Login Items Settings", bundle: WinkResourceBundle.bundle)) {
                                preferences.openLoginItemsSettings()
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func keyboardCard(importPreviewActive: Bool) -> some View {
        WinkCard {
            VStack(alignment: .leading, spacing: 0) {
                SettingsToggleRow(
                    title: String(localized: "Enable All Shortcuts", bundle: WinkResourceBundle.bundle),
                    subtitle: String(localized: "Master switch for global shortcut routing.", bundle: WinkResourceBundle.bundle),
                    isOn: Binding(
                        get: { editor.allEnabled },
                        set: { editor.setAllEnabled($0) }
                    )
                )
                .disabled(importPreviewActive)

                Divider().overlay(palette.hairline)

                SettingsToggleRow(
                    title: String(localized: "Hyper Key", bundle: WinkResourceBundle.bundle),
                    subtitleView: {
                        HStack(spacing: 6) {
                            Text("Hold", bundle: WinkResourceBundle.bundle)
                            WinkKeycap("Caps Lock", size: .small)
                            Text("to act as", bundle: WinkResourceBundle.bundle)
                            WinkKeycap("⌃⌥⇧⌘", size: .small)
                            Text(". Tap alone to keep its original behavior.", bundle: WinkResourceBundle.bundle)
                        }
                    },
                    isOn: Binding(
                        get: { preferences.hyperKeyEnabled },
                        set: { preferences.setHyperKeyEnabled($0) }
                    )
                )

                Divider().overlay(palette.hairline)

                SettingsRow(
                    title: String(localized: "When target is frontmost", bundle: WinkResourceBundle.bundle),
                    subtitle: String(localized: "How Wink reacts when the target app is already active.", bundle: WinkResourceBundle.bundle)
                ) {
                    WinkSegmented(
                        options: FrontmostTargetBehavior.allCases.map { behavior in
                            (label: behavior.title, value: behavior)
                        },
                        selection: Binding(
                            get: { preferences.frontmostTargetBehavior },
                            set: { preferences.frontmostTargetBehavior = $0 }
                        ),
                        accessibilityLabel: String(localized: "When target is frontmost", bundle: WinkResourceBundle.bundle)
                    )
                    .frame(width: 224)
                }

                Divider().overlay(palette.hairline)

                SettingsToggleRow(
                    title: String(localized: "Hyper cheat sheet", bundle: WinkResourceBundle.bundle),
                    subtitle: hyperCheatSheetSubtitle,
                    isOn: Binding(
                        get: { preferences.hyperCheatSheetEnabled },
                        set: { preferences.setHyperCheatSheetEnabled($0) }
                    )
                )

                Divider().overlay(palette.hairline)

                SettingsToggleRow(
                    title: String(localized: "Suggest shortcuts from app usage", bundle: WinkResourceBundle.bundle),
                    subtitle: String(
                        localized: "Count app switches locally to suggest shortcuts in Insights. Turning this off also deletes the collected counts.",
                        bundle: WinkResourceBundle.bundle
                    ),
                    isOn: Binding(
                        get: { preferences.suggestShortcutsFromUsage },
                        set: { preferences.setSuggestShortcutsFromUsage($0) }
                    )
                )

                Divider().overlay(palette.hairline)

                SettingsToggleRow(
                    title: String(localized: "Pause in exception apps", bundle: WinkResourceBundle.bundle),
                    subtitle: String(
                        localized: "Hand shortcuts back to the system while a listed app (VM, remote desktop) is frontmost.",
                        bundle: WinkResourceBundle.bundle
                    ),
                    isOn: Binding(
                        get: { preferences.frontmostExceptionsEnabled },
                        set: { preferences.setFrontmostExceptionsEnabled($0) }
                    )
                )

                if preferences.frontmostExceptionsEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(preferences.frontmostExceptionRules, id: \.self) { bundleIdentifier in
                            HStack(spacing: 8) {
                                AppIconView(bundleIdentifier: bundleIdentifier, size: 18)
                                Text(bundleIdentifier)
                                    .font(WinkType.labelSmall.monospaced())
                                    .foregroundStyle(palette.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Button {
                                    preferences.removeFrontmostExceptionRule(bundleIdentifier: bundleIdentifier)
                                } label: {
                                    WinkIcon.close.image(size: 9)
                                        .foregroundStyle(palette.textTertiary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(String(localized: "Remove \(bundleIdentifier)", bundle: WinkResourceBundle.bundle))
                            }
                        }

                        WinkButton(String(localized: "Add App…", bundle: WinkResourceBundle.bundle)) {
                            addExceptionApp()
                        }
                        .padding(.top, 2)
                    }
                    .padding(.leading, 2)
                }
            }
        }
    }

    /// The #356 search-to-switch palette's own settings surface: off by
    /// default (no shortcut recorded), one dedicated recorder here rather
    /// than a row in the per-app Shortcuts list — it targets no app, so it
    /// doesn't belong in the app picker. The Permissions card immediately
    /// below already surfaces degraded-capture state for every shortcut,
    /// this one included, so no separate banner is needed here. Disabled
    /// during an active import preview, same as `keyboardCard`'s controls —
    /// recording a chord mid-preview would silently invalidate an already
    /// "ready" plan entry by the time the user applies it.
    private func searchPaletteCard(importPreviewActive: Bool) -> some View {
        WinkCard(
            title: {
                Text("Search Palette", bundle: WinkResourceBundle.bundle)
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Text("Type an app name and press Return to switch to it.", bundle: WinkResourceBundle.bundle)
                        .font(WinkType.labelSmall)
                        .foregroundStyle(palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    searchPaletteAccessory
                        .frame(width: 200, alignment: .trailing)
                        .disabled(importPreviewActive)
                }

                if let message = editor.searchPaletteConflictMessage {
                    Text(message)
                        .font(WinkType.labelSmall)
                        .foregroundStyle(palette.red)
                }

                if let message = editor.searchPaletteSaveErrorMessage {
                    Text(message)
                        .font(WinkType.labelSmall)
                        .foregroundStyle(palette.red)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var searchPaletteAccessory: some View {
        if let shortcut = editor.searchPaletteShortcut {
            HStack(spacing: 8) {
                if shortcut.isHyper {
                    WinkHyperBadge()
                }

                Text(shortcut.displayText)
                    .font(WinkType.monoBadge)
                    .tracking(0.5)
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.controlBgRest)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(palette.controlBorder, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                WinkSwitch(isOn: Binding(
                    get: { shortcut.isEnabled },
                    set: { editor.setSearchPaletteEnabled($0) }
                ), size: .small)

                Button {
                    editor.removeSearchPaletteShortcut()
                } label: {
                    WinkIcon.close.image(size: 9)
                        .foregroundStyle(palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Delete Shortcut", bundle: WinkResourceBundle.bundle))
            }
        } else if editor.isRecordingSearchPaletteShortcut {
            ShortcutRecorderView(
                recordedShortcut: Binding(
                    get: { editor.recordedSearchPaletteShortcut },
                    set: { newValue in
                        editor.recordedSearchPaletteShortcut = newValue
                        if let newValue {
                            editor.commitSearchPaletteShortcut(newValue)
                        }
                    }
                ),
                isRecording: $editor.isRecordingSearchPaletteShortcut
            )
            .frame(height: 28)
        } else {
            ShortcutRecorderIdleField(recordedShortcut: nil) {
                editor.isRecordingSearchPaletteShortcut = true
            }
        }
    }

    private var hyperCheatSheetSubtitle: String {
        // Each branch is one full self-contained catalog entry (not a
        // concatenation of localized fragments) so translators see a
        // complete, naturally-ordered sentence.
        guard preferences.hyperCheatSheetEnabled else {
            return String(localized: "Hold Caps Lock without a second key to see all shortcuts.", bundle: WinkResourceBundle.bundle)
        }
        if !preferences.hyperKeyEnabled {
            return String(
                localized: "Hold Caps Lock without a second key to see all shortcuts. Needs Hyper Key enabled.",
                bundle: WinkResourceBundle.bundle
            )
        }
        if !preferences.shortcutCaptureStatus.eventTapActive {
            return String(
                localized: "Hold Caps Lock without a second key to see all shortcuts. Needs at least one enabled Hyper shortcut.",
                bundle: WinkResourceBundle.bundle
            )
        }
        return String(localized: "Hold Caps Lock without a second key to see all shortcuts.", bundle: WinkResourceBundle.bundle)
    }

    private func addExceptionApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { return }
        preferences.addFrontmostExceptionRule(bundleIdentifier: bundleIdentifier)
    }

    private func inputMonitoringPresentationState(for status: ShortcutCaptureStatus) -> PermissionSummaryState {
        if status.inputMonitoringRequired {
            return status.inputMonitoringGranted ? .granted : .needed
        }

        return status.inputMonitoringGranted ? .granted : .optional
    }

    private func updateBehaviorDescription(_ presentation: UpdatePresentation) -> String {
        guard presentation.isConfigured else {
            return String(
                localized: "Automatic updates become available after this build is configured with a signed Sparkle appcast feed.",
                bundle: WinkResourceBundle.bundle
            )
        }

        // Live session state outranks the static behavior description.
        switch preferences.updatePhase {
        case .checking:
            return String(localized: "Checking for updates…", bundle: WinkResourceBundle.bundle)
        case .available(let version):
            return String(
                localized: "Version \(version) is available. Use Check for Updates… to review and install.",
                bundle: WinkResourceBundle.bundle
            )
        case .downloading(let version, let received, let expected):
            let percent = expected > 0 ? " (\(Int(Double(received) / Double(expected) * 100))%)" : ""
            return String(localized: "Downloading version \(version)…\(percent)", bundle: WinkResourceBundle.bundle)
        case .extracting:
            return String(localized: "Preparing the downloaded update…", bundle: WinkResourceBundle.bundle)
        case .ready(let version):
            return String(
                localized: "Version \(version) is downloaded and installs when Wink quits. Use Check for Updates… to install now.",
                bundle: WinkResourceBundle.bundle
            )
        case .installing:
            return String(localized: "Installing the update — Wink will relaunch shortly.", bundle: WinkResourceBundle.bundle)
        case .error(let message):
            return String(localized: "The last automatic update check failed: \(message)", bundle: WinkResourceBundle.bundle)
        case .idle, .upToDate:
            break
        }

        let behavior: String
        if presentation.automaticChecksEnabled && presentation.automaticDownloadsEnabled {
            behavior = String(localized: "Automatic update checks and downloads are enabled.", bundle: WinkResourceBundle.bundle)
        } else if presentation.automaticChecksEnabled {
            behavior = String(
                localized: "Wink checks for updates automatically and asks before downloading.",
                bundle: WinkResourceBundle.bundle
            )
        } else {
            behavior = String(
                localized: "Automatic update checks are off. Use Check for Updates… to check manually.",
                bundle: WinkResourceBundle.bundle
            )
        }

        guard let lastChecked = preferences.lastUpdateCheckDate else {
            return behavior
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        let when = relative.localizedString(for: lastChecked, relativeTo: Date())
        // `behavior` is already fully localized text; composing it as a %@
        // argument (not raw Swift concatenation) keeps the whole sentence
        // routed through the catalog.
        return String(localized: "\(behavior) Last checked \(when).", bundle: WinkResourceBundle.bundle)
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
        case .granted: return String(localized: "Granted", bundle: WinkResourceBundle.bundle)
        case .needed: return String(localized: "Needed", bundle: WinkResourceBundle.bundle)
        case .optional: return String(localized: "Optional", bundle: WinkResourceBundle.bundle)
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
        SettingsRow(
            title: title,
            subtitleView: subtitleView,
            trailing: {
                WinkSwitch(isOn: isOn, size: .medium)
            }
        )
    }
}

private struct SettingsRow<SubtitleView: View, Trailing: View>: View {
    @Environment(\.winkPalette) private var palette

    let title: String
    @ViewBuilder let subtitleView: () -> SubtitleView
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) where SubtitleView == Text {
        self.title = title
        self.subtitleView = {
            Text(subtitle)
        }
        self.trailing = trailing
    }

    init(
        title: String,
        @ViewBuilder subtitleView: @escaping () -> SubtitleView,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitleView = subtitleView
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(WinkType.bodyMedium)
                    .foregroundStyle(palette.textPrimary)
                subtitleView()
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
