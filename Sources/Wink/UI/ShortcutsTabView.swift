import SwiftUI

struct ShortcutsTabView: View {
    @Bindable var editor: ShortcutEditorState
    var preferences: AppPreferences
    var appListProvider: AppListProvider

    @State private var showingAppPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionStatusBanner(
                status: preferences.shortcutCaptureStatus,
                onRefresh: { preferences.refreshPermissions() }
            )

            // New Shortcut card
            CardView("New Shortcut") {
                VStack(alignment: .leading, spacing: 10) {
                    // App chooser row
                    HStack(spacing: 10) {
                        Button {
                            showingAppPicker = true
                        } label: {
                            HStack(spacing: 4) {
                                Text("Choose App")
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                        }
                        .popover(isPresented: $showingAppPicker, arrowEdge: .bottom) {
                            AppPickerPopover(
                                appListProvider: appListProvider,
                                onSelect: { entry in
                                    editor.selectedAppName = entry.name
                                    editor.selectedBundleIdentifier = entry.bundleIdentifier
                                },
                                onBrowse: { editor.chooseApplication() }
                            )
                        }

                        if !editor.selectedAppName.isEmpty {
                            HStack(spacing: 6) {
                                AppIconView(bundleIdentifier: editor.selectedBundleIdentifier, size: 20)
                                Text(editor.selectedAppName)
                                    .font(.system(size: 13, weight: .medium))
                            }
                        } else {
                            Text("No app selected")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    // Recorder + Clear + Add
                    HStack(spacing: 10) {
                        ShortcutRecorderView(
                            recordedShortcut: $editor.recordedShortcut,
                            isRecording: $editor.isRecordingShortcut
                        )
                        .frame(height: 28)

                        if let recordedShortcut = editor.recordedShortcut {
                            ShortcutLabel(displayText: recordedShortcut.displayText, isHyper: recordedShortcut.isHyper)
                        } else if editor.isRecordingShortcut {
                            Text("Listening…")
                                .foregroundStyle(.secondary)
                        }

                        Button("Clear") {
                            editor.clearRecordedShortcut()
                        }
                        .disabled(editor.recordedShortcut == nil && !editor.isRecordingShortcut)

                        Spacer()

                        Button("Add") {
                            editor.addShortcut()
                        }
                        .disabled(editor.selectedBundleIdentifier.isEmpty || editor.recordedShortcut == nil)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(14)
            }

            if let conflictMessage = editor.conflictMessage {
                Text(conflictMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Shortcuts list card
            CardView("Shortcuts") {
                if editor.shortcuts.isEmpty {
                    Text("No shortcuts configured")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(editor.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                                shortcutRow(shortcut, index: index)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ shortcut: AppShortcut, index: Int) -> some View {
        HStack(spacing: 10) {
            AppIconView(bundleIdentifier: shortcut.bundleIdentifier, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(shortcut.appName)
                    .font(.system(size: 13, weight: .medium))
                Text(shortcut.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(editor.usageCounts[shortcut.id, default: 0])× past 7 days")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            ShortcutLabel(displayText: shortcut.displayText, isHyper: shortcut.isHyper)

            Toggle("", isOn: Binding(
                get: { shortcut.isEnabled },
                set: { _ in editor.toggleShortcutEnabled(id: shortcut.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            Button {
                editor.removeShortcut(id: shortcut.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .alternatingRowBackground(index: index)
        .opacity(shortcut.isEnabled ? 1.0 : 0.5)
    }
}
