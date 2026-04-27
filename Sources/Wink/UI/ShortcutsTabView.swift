import AppKit
import Combine
import SwiftUI

private enum ShortcutRowMetrics {
    static let spacing: CGFloat = 12
    static let gripColumnWidth: CGFloat = 12
    static let iconSize: CGFloat = 30
    static let textSpacing: CGFloat = 2
    static let verticalPadding: CGFloat = 10
    static let standardRowHeight: CGFloat = 50
    static let unavailableRowHeight: CGFloat = 68
    static let minimumListHeight: CGFloat = 150
    static let hyperBadgeColumnWidth: CGFloat = 58
    static let shortcutColumnWidth: CGFloat = 112
    static let switchColumnWidth: CGFloat = 36
    static let actionButtonSize: CGFloat = 22
    static let accessorySpacing: CGFloat = 8

    static var accessoryGroupWidth: CGFloat {
        hyperBadgeColumnWidth + shortcutColumnWidth + switchColumnWidth + actionButtonSize + accessorySpacing * 3
    }
}

private enum ShortcutImportPreviewMetrics {
    static let detailsMaxHeight: CGFloat = 128
}

struct ShortcutRowAccessibilityOptions: Equatable {
    let differentiateWithoutColor: Bool
    let reduceMotion: Bool

    static let standard = ShortcutRowAccessibilityOptions(
        differentiateWithoutColor: false,
        reduceMotion: false
    )

    @MainActor
    static var current: ShortcutRowAccessibilityOptions {
        let workspace = NSWorkspace.shared
        return ShortcutRowAccessibilityOptions(
            differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion
        )
    }
}

struct ShortcutsListRowPresentation {
    let title: String
    let usageText: String
    let lastUsedText: String
    let metadataText: String
    let contentOpacity: Double
    let showsRunningIndicator: Bool
    let runningStatusText: String?
    let unavailableStatusText: String?
    let unavailableHelpText: String?

    // `RelativeDateTimeFormatter` is non-Sendable; create a fresh instance per call
    // rather than caching in a static property (Swift 6 strict concurrency).
    private static func makeRelativeFormatter() -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }

    init(
        shortcut: AppShortcut,
        usageCount: Int,
        runtimeStatus: ShortcutRuntimeStatus,
        accessibilityOptions: ShortcutRowAccessibilityOptions = .standard,
        lastUsed: Date? = nil,
        now: Date = Date()
    ) {
        title = shortcut.appName
        let usageSummary = "\(usageCount)× past 7 days"
        usageText = usageSummary

        if let lastUsed {
            let relative = Self.makeRelativeFormatter().localizedString(for: lastUsed, relativeTo: now)
            lastUsedText = "Last used \(relative)"
        } else {
            lastUsedText = "Last used —"
        }

        // `usageCount` only covers the past 7 days, but `lastUsed` reflects all stored
        // hourly history. A shortcut triggered more than a week ago therefore has
        // count == 0 while still carrying a real last-used bucket, so only fall back
        // to "Not used yet" when we truly have no history to report.
        if usageCount > 0 {
            metadataText = "\(usageSummary) · \(lastUsedText)"
        } else if lastUsed != nil {
            metadataText = lastUsedText
        } else {
            metadataText = "Not used yet"
        }

        contentOpacity = shortcut.isEnabled ? 1.0 : 0.65
        showsRunningIndicator = runtimeStatus.isRunning
        runningStatusText = runtimeStatus.isRunning && accessibilityOptions.differentiateWithoutColor
            ? "Running"
            : nil
        unavailableStatusText = runtimeStatus.isUnavailable ? "App unavailable" : nil
        unavailableHelpText = runtimeStatus.isUnavailable
            ? "Couldn't find this app. Rebind it to restore the shortcut."
            : nil
    }

    var subtitle: String {
        usageText
    }
}

enum ShortcutBannerPresentation: Equatable {
    case info(title: String, message: String)
    case success(title: String, message: String)
    case warning(title: String, message: String, showsAction: Bool)

    init(status: ShortcutCaptureStatus) {
        if !status.accessibilityGranted {
            self = .warning(
                title: "Accessibility permission needed",
                message: "Wink needs Accessibility access to route global shortcuts.",
                showsAction: true
            )
            return
        }

        if status.inputMonitoringRequired && !status.inputMonitoringGranted && !status.hyperShortcutsReady {
            self = .warning(
                title: "Input Monitoring needed",
                message: "Hyper shortcuts need Input Monitoring before Wink can capture them.",
                showsAction: true
            )
            return
        }

        if status.shortcutsPaused {
            self = .info(
                title: "Shortcuts paused",
                message: status.bannerDetail
            )
            return
        }

        if let warning = status.standardRegistrationWarning {
            self = .warning(
                title: "Shortcut capture needs attention",
                message: warning,
                showsAction: false
            )
            return
        }

        let title: String
        if status.standardShortcutsReady && status.hyperShortcutsReady {
            title = "Shortcut capture ready"
        } else {
            title = "Standard shortcuts ready"
        }

        let message = [status.bannerDetail, status.systemSettingsGuidance]
            .compactMap { $0 }
            .joined(separator: " ")

        self = .success(title: title, message: message)
    }
}

struct ShortcutsTabView: View {
    @Environment(\.winkPalette) private var palette

    @Bindable var editor: ShortcutEditorState
    var preferences: AppPreferences
    var appListProvider: AppListProvider
    var shortcutStatusProvider: ShortcutStatusProvider

    @State private var showingAppPicker = false
    @State private var filterText = ""
    @State private var accessibilityOptions = ShortcutRowAccessibilityOptions.standard

    private var filteredShortcuts: [AppShortcut] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return editor.shortcuts
        }

        return editor.shortcuts.filter { shortcut in
            shortcut.appName.localizedCaseInsensitiveContains(query)
                || shortcut.displayText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let importPreviewActive = editor.pendingRecipeImport != nil

        VStack(alignment: .leading, spacing: 14) {
            SettingsTabHeader(
                title: "Shortcuts",
                subtitle: "Bind a keystroke to launch, toggle, or hide an app."
            ) {
                WinkButton("Refresh", systemImage: WinkIcon.refresh.systemName) {
                    preferences.requestShortcutPermissions()
                }
            }

            permissionBanner

            WinkCard(
                title: {
                    Text("New Shortcut")
                }
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            SettingsFieldLabel("Target app")
                            Button {
                                showingAppPicker = true
                            } label: {
                                HStack(spacing: 8) {
                                    if editor.selectedBundleIdentifier.isEmpty {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(palette.controlBgRest)
                                            .frame(width: 20, height: 20)
                                            .overlay {
                                                WinkIcon.app.image(size: 11)
                                                    .foregroundStyle(palette.textTertiary)
                                            }

                                        Text("Choose an app…")
                                            .font(WinkType.bodyText)
                                            .foregroundStyle(palette.textTertiary)
                                    } else {
                                        AppIconView(bundleIdentifier: editor.selectedBundleIdentifier, size: 20)
                                        Text(editor.selectedAppName)
                                            .font(WinkType.bodyText)
                                            .foregroundStyle(palette.textPrimary)
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 8)

                                    WinkIcon.chevronDown.image(size: 11)
                                        .foregroundStyle(palette.textSecondary)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 28)
                                .background(palette.controlBg)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(palette.controlBorder, lineWidth: 0.5)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showingAppPicker, arrowEdge: .bottom) {
                                AppPickerPopover(
                                    appListProvider: appListProvider,
                                    onSelect: { entry in
                                        editor.selectedAppName = entry.name
                                        editor.selectedBundleIdentifier = entry.bundleIdentifier
                                    },
                                    onBrowse: {
                                        editor.chooseApplication()
                                    }
                                )
                            }
                            .disabled(importPreviewActive)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 5) {
                            SettingsFieldLabel("Shortcut", trailing: "Click to record")

                            if editor.isRecordingShortcut {
                                ShortcutRecorderView(
                                    recordedShortcut: $editor.recordedShortcut,
                                    isRecording: $editor.isRecordingShortcut
                                )
                                .frame(height: 28)
                            } else {
                                ShortcutRecorderIdleField(recordedShortcut: editor.recordedShortcut) {
                                    editor.isRecordingShortcut = true
                                }
                                .disabled(importPreviewActive)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider().overlay(palette.hairline)

                    HStack(alignment: .center, spacing: 10) {
                        HStack(spacing: 6) {
                            Text("Tip: hold")
                            WinkKeycap("Caps Lock", size: .small)
                            Text("for a Hyper shortcut.")
                        }
                        .font(WinkType.labelSmall)
                        .foregroundStyle(palette.textTertiary)

                        Spacer(minLength: 8)

                        WinkButton("Clear") {
                            editor.clearRecordedShortcut()
                        }
                        .disabled(importPreviewActive || (editor.recordedShortcut == nil && !editor.isRecordingShortcut))

                        WinkButton("Add Shortcut", variant: .primary) {
                            editor.addShortcut()
                        }
                        .disabled(importPreviewActive || editor.selectedBundleIdentifier.isEmpty || editor.recordedShortcut == nil)
                    }
                }
                .padding(14)
            }

            if let conflictMessage = editor.conflictMessage {
                Text(conflictMessage)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.red)
            }

            if let recipeFeedback = editor.recipeFeedback {
                Text(recipeFeedback.message)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(recipeFeedback.isError ? palette.red : palette.textSecondary)
            }

            if let pendingRecipeImport = editor.pendingRecipeImport {
                importPreviewCard(pendingRecipeImport)
            }

            shortcutsCard(importPreviewActive: importPreviewActive)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.windowBg)
        .onAppear {
            accessibilityOptions = .current
            shortcutStatusProvider.track(editor.shortcuts)
        }
        .onChange(of: editor.shortcuts) { _, newShortcuts in
            shortcutStatusProvider.track(newShortcuts)
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            )
        ) { _ in
            accessibilityOptions = .current
        }
    }

    @ViewBuilder
    private var permissionBanner: some View {
        switch ShortcutBannerPresentation(status: preferences.shortcutCaptureStatus) {
        case let .info(title, message):
            WinkBanner(kind: .info, title: title, message: message)
        case let .success(title, message):
            WinkBanner(kind: .success, title: title, message: message)
        case let .warning(title, message, showsAction):
            WinkBanner(kind: .warn, title: title, message: message) {
                if showsAction {
                    WinkButton(permissionActionTitle, variant: .primary) {
                        preferences.requestShortcutPermissions()
                    }
                } else {
                    WinkButton("Refresh") {
                        preferences.refreshPermissions()
                    }
                }
            }
        }
    }

    private var permissionActionTitle: String {
        let status = preferences.shortcutCaptureStatus
        if !status.accessibilityGranted {
            return "Request Accessibility"
        }
        if status.inputMonitoringRequired && !status.inputMonitoringGranted && !status.hyperShortcutsReady {
            return "Request Input Monitoring"
        }
        return "Request Access"
    }

    @ViewBuilder
    private func shortcutsCard(importPreviewActive: Bool) -> some View {
        let canReorder = filterText.isEmpty && !importPreviewActive

        WinkCard(
            title: {
                Text("Your Shortcuts · \(editor.shortcuts.count)")
            },
            accessory: {
                HStack(spacing: 6) {
                    WinkTextField(
                        placeholder: "Filter…",
                        text: $filterText,
                        leading: {
                            WinkIcon.search.image(size: 11)
                                .foregroundStyle(palette.textTertiary)
                        }
                    )
                    .frame(width: 140)

                    Menu {
                        Button("Import…") {
                            Task {
                                await editor.importRecipes(using: appListProvider)
                            }
                        }
                        Button("Export…") {
                            editor.exportRecipes()
                        }
                        .disabled(editor.shortcuts.isEmpty)
                    } label: {
                        WinkIcon.more.image(size: 12)
                            .foregroundStyle(palette.textSecondary)
                            .frame(width: 28, height: 24)
                            .background(palette.controlBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(palette.controlBorder, lineWidth: 0.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Import or export shortcuts")
                    .disabled(importPreviewActive)
                }
            }
        ) {
            if filteredShortcuts.isEmpty {
                Text(filterText.isEmpty ? "No shortcuts configured" : "No shortcuts match your filter")
                    .font(WinkType.bodyText)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredShortcuts.enumerated()), id: \.element.id) { index, shortcut in
                                reorderableRow(shortcut, index: index, canReorder: canReorder)
                                if index < filteredShortcuts.count - 1 {
                                    Divider().overlay(palette.hairline)
                                        .padding(.leading, 58)
                                }
                            }
                        }
                        .frame(width: proxy.size.width, alignment: .leading)
                        .frame(minHeight: proxy.size.height, alignment: .top)
                    }
                    .scrollIndicators(.automatic, axes: .vertical)
                }
                .frame(
                    minHeight: ShortcutRowMetrics.minimumListHeight,
                    maxHeight: .infinity,
                    alignment: .top
                )
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .layoutPriority(1)
    }

    // Drag-to-reorder lives on the row via `.draggable` + `.dropDestination`. We gate
    // it on `canReorder` so filtering or an active import preview cannot produce a
    // silently-wrong reorder against the full shortcut list.
    @ViewBuilder
    private func reorderableRow(_ shortcut: AppShortcut, index: Int, canReorder: Bool) -> some View {
        if canReorder {
            shortcutRow(shortcut, index: index)
                .draggable(shortcut.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let idString = items.first,
                          let draggedID = UUID(uuidString: idString) else {
                        return false
                    }
                    editor.reorderShortcut(draggedID: draggedID, onto: shortcut.id)
                    return true
                }
        } else {
            shortcutRow(shortcut, index: index)
        }
    }

    @ViewBuilder
    private func shortcutRow(_ shortcut: AppShortcut, index: Int) -> some View {
        let importPreviewActive = editor.pendingRecipeImport != nil
        let runtimeStatus = shortcutStatusProvider.status(for: shortcut)

        ShortcutsListRow(
            shortcut: shortcut,
            usageCount: editor.usageCounts[shortcut.id, default: 0],
            lastUsed: editor.lastUsed[shortcut.id],
            runtimeStatus: runtimeStatus,
            accessibilityOptions: accessibilityOptions,
            importPreviewActive: importPreviewActive,
            index: index,
            onToggleEnabled: {
                editor.toggleShortcutEnabled(id: shortcut.id)
            },
            onRemove: {
                editor.removeShortcut(id: shortcut.id)
            }
        )
    }

    @ViewBuilder
    private func importPreviewCard(_ plan: WinkRecipeImportPlanner.ImportPlan) -> some View {
        WinkCard(
            title: {
                Text("Import Preview")
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    statView(title: "Ready", count: plan.readyEntries.count, tint: palette.green)
                    statView(title: "Conflicts", count: plan.conflictEntries.count, tint: palette.amber)
                    statView(title: "Unresolved", count: plan.unresolvedEntries.count, tint: palette.textSecondary)
                }

                importPreviewDetails(plan)

                HStack(spacing: 8) {
                    WinkButton("Cancel") {
                        editor.discardPendingRecipeImport()
                    }

                    Spacer(minLength: 8)

                    WinkButton("Skip Conflicts") {
                        editor.applyPendingImport(strategy: .skipConflicts)
                    }

                    WinkButton("Replace Existing", variant: .primary) {
                        editor.applyPendingImport(strategy: .replaceExisting)
                    }
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func importPreviewDetails(_ plan: WinkRecipeImportPlanner.ImportPlan) -> some View {
        if !plan.conflictEntries.isEmpty || !plan.unresolvedEntries.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !plan.conflictEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Conflicts")
                                .font(WinkType.captionStrong)
                                .foregroundStyle(palette.textPrimary)

                            ForEach(plan.conflictEntries) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(entry.imported.resolvedAppName) · \(entry.imported.displayText)")
                                        .font(WinkType.labelSmall)
                                        .foregroundStyle(palette.textPrimary)
                                    if let conflictingShortcut = entry.conflictingShortcut {
                                        Text("Conflicts with \(conflictingShortcut.appName) · \(conflictingShortcut.displayText)")
                                            .font(WinkType.labelSmall)
                                            .foregroundStyle(palette.textSecondary)
                                    }
                                }
                            }
                        }
                    }

                    if !plan.unresolvedEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Unresolved apps without conflicts will still be imported using their recipe app name and bundle identifier.")
                                .font(WinkType.labelSmall)
                                .foregroundStyle(palette.textSecondary)

                            ForEach(plan.unresolvedEntries) { entry in
                                Text("\(entry.imported.sourceAppName) (\(entry.imported.sourceBundleIdentifier))")
                                    .font(WinkType.labelSmall)
                                    .foregroundStyle(palette.textSecondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic, axes: .vertical)
            .frame(maxHeight: ShortcutImportPreviewMetrics.detailsMaxHeight)
        }
    }

    @ViewBuilder
    private func statView(title: String, count: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(WinkType.labelSmall)
                .foregroundStyle(palette.textSecondary)
            Text("\(count)")
                .font(WinkType.tabTitle)
                .foregroundStyle(tint)
        }
    }
}

struct ShortcutsListRow: View {
    @Environment(\.winkPalette) private var palette

    let shortcut: AppShortcut
    let usageCount: Int
    let lastUsed: Date?
    let runtimeStatus: ShortcutRuntimeStatus
    let accessibilityOptions: ShortcutRowAccessibilityOptions
    let importPreviewActive: Bool
    let index: Int
    let onToggleEnabled: @MainActor () -> Void
    let onRemove: @MainActor () -> Void

    private var presentation: ShortcutsListRowPresentation {
        ShortcutsListRowPresentation(
            shortcut: shortcut,
            usageCount: usageCount,
            runtimeStatus: runtimeStatus,
            accessibilityOptions: accessibilityOptions,
            lastUsed: lastUsed
        )
    }

    private var statusAnimationKey: ShortcutRowStatusAnimationKey {
        ShortcutRowStatusAnimationKey(
            isEnabled: shortcut.isEnabled,
            isRunning: runtimeStatus.isRunning,
            isUnavailable: runtimeStatus.isUnavailable,
            differentiateWithoutColor: accessibilityOptions.differentiateWithoutColor
        )
    }

    private var statusAnimation: Animation? {
        accessibilityOptions.reduceMotion
            ? nil
            : .easeOut(duration: 0.16)
    }

    var body: some View {
        HStack(spacing: ShortcutRowMetrics.spacing) {
            WinkIcon.grip.image(size: 11, weight: .semibold)
                .foregroundStyle(palette.textTertiary)
                .frame(width: ShortcutRowMetrics.gripColumnWidth)

            ZStack(alignment: .bottomTrailing) {
                AppIconView(
                    bundleIdentifier: shortcut.bundleIdentifier,
                    size: ShortcutRowMetrics.iconSize
                )

                if let unavailableHelpText = presentation.unavailableHelpText {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.amber)
                        .background(
                            Circle()
                                .fill(palette.cardBg)
                                .frame(width: 14, height: 14)
                        )
                        .offset(x: 3, y: 3)
                        .help(unavailableHelpText)
                }
            }

            VStack(alignment: .leading, spacing: ShortcutRowMetrics.textSpacing) {
                HStack(spacing: 6) {
                    Text(presentation.title)
                        .font(WinkType.bodyMedium)
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if presentation.showsRunningIndicator {
                        HStack(spacing: 4) {
                            WinkStatusDot(color: palette.green)

                            if let runningStatusText = presentation.runningStatusText {
                                Text(runningStatusText)
                                    .font(WinkType.labelSmall)
                                    .foregroundStyle(palette.textSecondary)
                            }
                        }
                        .help("App is currently running")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(presentation.metadataText)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let unavailableStatusText = presentation.unavailableStatusText {
                    Label(unavailableStatusText, systemImage: "exclamationmark.triangle.fill")
                        .font(WinkType.labelSmall)
                        .foregroundStyle(palette.amber)
                        .help(presentation.unavailableHelpText ?? unavailableStatusText)
                }
            }

            .frame(maxWidth: .infinity, alignment: .leading)

            shortcutAccessoryGroup
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, ShortcutRowMetrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alternatingRowBackground(index: index)
        .opacity(presentation.contentOpacity)
        .animation(statusAnimation, value: statusAnimationKey)
    }

    private var shortcutAccessoryGroup: some View {
        HStack(spacing: ShortcutRowMetrics.accessorySpacing) {
            Group {
                if shortcut.isHyper {
                    WinkHyperBadge()
                } else {
                    Color.clear
                        .accessibilityHidden(true)
                }
            }
            .frame(width: ShortcutRowMetrics.hyperBadgeColumnWidth, alignment: .trailing)

            ShortcutKeycapStrip(shortcut: shortcut)
                .frame(width: ShortcutRowMetrics.shortcutColumnWidth, alignment: .trailing)

            WinkSwitch(isOn: Binding(
                get: { shortcut.isEnabled },
                set: { _ in onToggleEnabled() }
            ))
            .frame(width: ShortcutRowMetrics.switchColumnWidth)
            .disabled(importPreviewActive)

            Menu {
                Button("Delete Shortcut", role: .destructive, action: onRemove)
            } label: {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.clear)
                    .frame(width: ShortcutRowMetrics.actionButtonSize, height: ShortcutRowMetrics.actionButtonSize)
                    .overlay {
                        WinkIcon.more.image(size: 12)
                            .foregroundStyle(palette.textTertiary)
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: ShortcutRowMetrics.actionButtonSize, height: ShortcutRowMetrics.actionButtonSize)
            .disabled(importPreviewActive)
        }
        .frame(width: ShortcutRowMetrics.accessoryGroupWidth, alignment: .trailing)
    }
}

private struct ShortcutRowStatusAnimationKey: Equatable {
    let isEnabled: Bool
    let isRunning: Bool
    let isUnavailable: Bool
    let differentiateWithoutColor: Bool
}

private struct SettingsFieldLabel: View {
    @Environment(\.winkPalette) private var palette

    let text: String
    let trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(text)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
            }
        }
        .font(WinkType.labelSmall)
        .foregroundStyle(palette.textSecondary)
    }
}

struct ShortcutRecorderIdleField: View {
    nonisolated static let placeholderText = "Press a key combination…"
    nonisolated static let dashPattern: [CGFloat] = [4, 4]

    @Environment(\.winkPalette) private var palette

    let recordedShortcut: RecordedShortcut?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let recordedShortcut {
                    ShortcutKeycapStrip(shortcut: recordedShortcut)
                    Spacer(minLength: 8)
                } else {
                    WinkIcon.record.image(size: 11)
                        .foregroundStyle(palette.textTertiary)
                    Text(Self.placeholderText)
                        .font(WinkType.bodyText)
                        .foregroundStyle(palette.textTertiary)
                    Spacer(minLength: 8)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(palette.fieldBg)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(palette.controlBorder.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: Self.dashPattern))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
