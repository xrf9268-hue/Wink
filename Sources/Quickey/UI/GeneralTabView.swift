import SwiftUI

struct GeneralTabView: View {
    var preferences: AppPreferences
    var editor: ShortcutEditorState

    var body: some View {
        let updatePresentation = preferences.updatePresentation

        VStack(alignment: .leading, spacing: 12) {
            // Startup card
            CardView("Startup") {
                let presentation = preferences.launchAtLoginPresentation

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { preferences.launchAtLoginPresentation.toggleIsOn },
                        set: { preferences.setLaunchAtLogin($0) }
                    ))
                    .disabled(!presentation.toggleIsEnabled)

                    if let message = presentation.message {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(
                                    presentation.messageStyle == .error ? Color.red : Color.secondary
                                )

                            if presentation.showsOpenSettingsButton {
                                Button("Open Login Items Settings") {
                                    preferences.openLoginItemsSettings()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.leading, 20)
                    }
                }
                .padding(14)
            }

            // Keyboard card
            CardView("Keyboard") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable All Shortcuts", isOn: Binding(
                        get: { editor.allEnabled },
                        set: { editor.setAllEnabled($0) }
                    ))

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Toggle("Enable Hyper Key", isOn: Binding(
                                get: { preferences.hyperKeyEnabled },
                                set: { preferences.setHyperKeyEnabled($0) }
                            ))
                            Text("Caps Lock → ⌃⌥⇧⌘")
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.secondary)
                        }
                        Text("按住 Caps Lock 再按其他键，等同于 ⌃⌥⇧⌘ 组合。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                }
                .padding(14)
            }

            // Updates card
            CardView("Updates") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Keep Quickey up to date")
                                .font(.system(size: 13, weight: .medium))
                            Text("Version \(updatePresentation.currentVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Check for Updates…") {
                            preferences.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!updatePresentation.checkForUpdatesEnabled)
                    }

                    Text(updateBehaviorDescription(updatePresentation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }

            Spacer()

            // About card
            CardView {
                HStack {
                    Spacer()
                    Text("Quickey")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("v\(updatePresentation.currentVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(10)
            }
        }
    }

    private func updateBehaviorDescription(_ presentation: UpdatePresentation) -> String {
        let checkBehavior = presentation.automaticChecksEnabledByDefault
            ? "Quickey checks for updates automatically"
            : "Automatic update checks are disabled by default"
        let downloadBehavior = presentation.automaticDownloadsEnabledByDefault
            ? "and downloads them in the background when available."
            : "and asks before downloading updates."

        return "\(checkBehavior) \(downloadBehavior)"
    }
}
