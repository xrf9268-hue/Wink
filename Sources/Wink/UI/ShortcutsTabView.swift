import SwiftUI

struct ShortcutsTabView: View {
    @Bindable var editor: ShortcutEditorState
    var preferences: AppPreferences
    var appListProvider: AppListProvider
    private let appBundleLocator = AppBundleLocator()

    @State private var showingAppPicker = false

    var body: some View {
        let importPreviewActive = editor.pendingRecipeImport != nil

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
                        .disabled(importPreviewActive)

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
                        .disabled(importPreviewActive || (editor.recordedShortcut == nil && !editor.isRecordingShortcut))

                        Spacer()

                        Button("Add") {
                            editor.addShortcut()
                        }
                        .disabled(importPreviewActive || editor.selectedBundleIdentifier.isEmpty || editor.recordedShortcut == nil)
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

            if let recipeFeedback = editor.recipeFeedback {
                Text(recipeFeedback.message)
                    .font(.caption)
                    .foregroundStyle(recipeFeedback.isError ? .red : .secondary)
            }

            if let pendingRecipeImport = editor.pendingRecipeImport {
                importPreviewCard(pendingRecipeImport)
            }

            // Shortcuts list card
            CardView("Shortcuts") {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Spacer()

                        Button("Export...") {
                            editor.exportRecipes()
                        }
                        .disabled(importPreviewActive)
                        .controlSize(.small)

                        Button("Import...") {
                            Task {
                                await editor.importRecipes(using: appListProvider)
                            }
                        }
                        .disabled(importPreviewActive)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)

                    if editor.shortcuts.isEmpty {
                        Text("No shortcuts configured")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    } else {
                        List {
                            ForEach(Array(editor.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                                shortcutRow(shortcut, index: index)
                                    .moveDisabled(importPreviewActive)
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                            }
                            .onMove(perform: editor.moveShortcut)
                        }
                        .listStyle(.plain)
                        .frame(minHeight: 140)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ shortcut: AppShortcut, index: Int) -> some View {
        let targetInstalled = appBundleLocator.applicationURL(for: shortcut.bundleIdentifier) != nil
        let importPreviewActive = editor.pendingRecipeImport != nil

        HStack(spacing: 10) {
            AppIconView(bundleIdentifier: shortcut.bundleIdentifier, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(shortcut.appName)
                    .font(.system(size: 13, weight: .medium))
                Text(shortcut.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !targetInstalled {
                    Label("App not currently installed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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
            .disabled(importPreviewActive)

            Button {
                editor.removeShortcut(id: shortcut.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(importPreviewActive)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .alternatingRowBackground(index: index)
        .opacity(shortcut.isEnabled ? (targetInstalled ? 1.0 : 0.7) : 0.5)
    }

    @ViewBuilder
    private func importPreviewCard(_ plan: WinkRecipeImportPlanner.ImportPlan) -> some View {
        CardView("Import Preview") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    statView(title: "Ready", count: plan.readyEntries.count, tint: .green)
                    statView(title: "Conflicts", count: plan.conflictEntries.count, tint: .orange)
                    statView(title: "Unresolved", count: plan.unresolvedEntries.count, tint: .secondary)
                }

                if !plan.conflictEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Conflicts")
                            .font(.system(size: 12, weight: .semibold))

                        ForEach(plan.conflictEntries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.imported.resolvedAppName) · \(entry.imported.displayText)")
                                    .font(.caption)
                                if let conflictingShortcut = entry.conflictingShortcut {
                                    Text("Conflicts with \(conflictingShortcut.appName) · \(conflictingShortcut.displayText)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !plan.unresolvedEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unresolved apps without conflicts will still be imported using their recipe app name and Bundle ID.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(plan.unresolvedEntries) { entry in
                            Text("\(entry.imported.sourceAppName) (\(entry.imported.sourceBundleIdentifier))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Cancel") {
                        editor.discardPendingRecipeImport()
                    }
                    .controlSize(.small)

                    Spacer()

                    Button("Skip Conflicts") {
                        editor.applyPendingImport(strategy: .skipConflicts)
                    }
                    .controlSize(.small)

                    Button("Replace Existing") {
                        editor.applyPendingImport(strategy: .replaceExisting)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func statView(title: String, count: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}
