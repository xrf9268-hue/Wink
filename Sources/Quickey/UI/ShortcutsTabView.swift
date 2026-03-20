import SwiftUI

struct ShortcutsTabView: View {
    @Bindable var editor: ShortcutEditorState
    var preferences: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Circle()
                    .fill(preferences.accessibilityGranted ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(preferences.accessibilityGranted ? "Accessibility granted" : "Accessibility required for global shortcuts")
                    .foregroundStyle(.secondary)
                Button("Refresh") {
                    preferences.refreshPermissions()
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Button("Choose App") {
                    editor.chooseApplication()
                }
                if !editor.selectedBundleIdentifier.isEmpty {
                    Button("Reveal App") {
                        editor.revealApplication()
                    }
                }
                Text(editor.selectedAppName.isEmpty ? "No app selected" : editor.selectedAppName)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Bundle Identifier", text: $editor.selectedBundleIdentifier)

                HStack(spacing: 12) {
                    ShortcutRecorderView(
                        recordedShortcut: $editor.recordedShortcut,
                        isRecording: $editor.isRecordingShortcut
                    )
                    .frame(width: 240, height: 28)

                    if let recordedShortcut = editor.recordedShortcut {
                        HStack(spacing: 4) {
                            Text(recordedShortcut.displayText)
                                .font(.system(.body, design: .monospaced))
                            if recordedShortcut.isHyper {
                                Text("Hyper")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.purple.opacity(0.2))
                                    .foregroundStyle(.purple)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    } else if editor.isRecordingShortcut {
                        Text("Listening…")
                            .foregroundStyle(.secondary)
                    }

                    Button("Clear") {
                        editor.clearRecordedShortcut()
                    }
                    .disabled(editor.recordedShortcut == nil && !editor.isRecordingShortcut)
                }
            }

            if let conflictMessage = editor.conflictMessage {
                Text(conflictMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Add Shortcut") {
                editor.addShortcut()
            }
            .disabled(editor.selectedBundleIdentifier.isEmpty || editor.recordedShortcut == nil)

            List {
                ForEach(editor.shortcuts) { shortcut in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(shortcut.appName)
                            Text(shortcut.bundleIdentifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(editor.usageCounts[shortcut.id, default: 0])× past 7 days")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            Text(shortcut.displayText)
                                .font(.system(.body, design: .monospaced))
                            if shortcut.isHyper {
                                Text("Hyper")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.purple.opacity(0.2))
                                    .foregroundStyle(.purple)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        Button(role: .destructive) {
                            editor.removeShortcut(id: shortcut.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}
