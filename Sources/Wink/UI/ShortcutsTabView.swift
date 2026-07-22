import AppKit
import Combine
import SwiftUI

private enum ShortcutRowMetrics {
    static let spacing: CGFloat = 10
    static let gripColumnWidth: CGFloat = 24
    static let gripHitHeight: CGFloat = 24
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
    static let accessorySpacing: CGFloat = 10

    static var accessoryGroupWidth: CGFloat {
        hyperBadgeColumnWidth + shortcutColumnWidth + switchColumnWidth + actionButtonSize + accessorySpacing * 3
    }
}

private enum ShortcutListCoordinateSpace {
    static let name = "WinkShortcutListCoordinateSpace"
}

private struct ShortcutRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ShortcutRowReorderHandlers {
    let onChanged: (DragGesture.Value) -> Void
    let onEnded: (DragGesture.Value) -> Void
}

struct ShortcutGripCursorRegion: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> ShortcutGripCursorView {
        let view = ShortcutGripCursorView()
        view.updateCursor(cursor)
        return view
    }

    func updateNSView(_ nsView: ShortcutGripCursorView, context: Context) {
        nsView.updateCursor(cursor)
    }
}

final class ShortcutGripCursorView: NSView {
    private var cursor = NSCursor.openHand

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursorRect = bounds.intersection(visibleRect)
        guard !cursorRect.isEmpty else {
            return
        }
        addCursorRect(cursorRect, cursor: cursor)
    }

    func updateCursor(_ cursor: NSCursor) {
        self.cursor = cursor
        window?.invalidateCursorRects(for: self)

        guard let window else {
            return
        }
        let mouseLocation = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(mouseLocation) {
            cursor.set()
        }
    }
}

enum ShortcutReorderPlanner {
    static func visibleDropOffset(
        for shortcutID: UUID,
        translationY: CGFloat,
        visibleShortcutIDs: [UUID],
        rowFrames: [UUID: CGRect],
        sourceFrame: CGRect? = nil
    ) -> Int? {
        guard let sourceFrame = sourceFrame ?? rowFrames[shortcutID],
              let sourceVisibleOffset = visibleShortcutIDs.firstIndex(of: shortcutID) else {
            return nil
        }

        let projectedMidY = sourceFrame.midY + translationY
        let measuredRows = visibleShortcutIDs
            .enumerated()
            .compactMap { visibleOffset, id -> (visibleOffset: Int, frame: CGRect)? in
                guard id != shortcutID, let frame = rowFrames[id] else {
                    return nil
                }
                return (visibleOffset, frame)
            }
            .sorted { lhs, rhs in
                lhs.frame.midY < rhs.frame.midY
            }

        guard !measuredRows.isEmpty else {
            return sourceVisibleOffset
        }

        return measuredRows.first { projectedMidY <= $0.frame.midY }?.visibleOffset
            ?? visibleShortcutIDs.count
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
        title = shortcut.displayAppName
        let usageSummary = String(localized: "\(usageCount)× past 7 days", bundle: WinkResourceBundle.bundle)
        usageText = usageSummary

        if let lastUsed {
            let relative = Self.makeRelativeFormatter().localizedString(for: lastUsed, relativeTo: now)
            lastUsedText = String(localized: "Last used \(relative)", bundle: WinkResourceBundle.bundle)
        } else {
            lastUsedText = String(localized: "Last used —", bundle: WinkResourceBundle.bundle)
        }

        // `usageCount` only covers the past 7 days, but `lastUsed` reflects all stored
        // hourly history. A shortcut triggered more than a week ago therefore has
        // count == 0 while still carrying a real last-used bucket, so only fall back
        // to "Not used yet" when we truly have no history to report.
        if usageCount > 0 {
            // " · " is a fixed design-system glue between two already-localized
            // fragments (matches the CycleHUD "N/M · Title" convention) — not
            // routed through the catalog itself.
            metadataText = "\(usageSummary) · \(lastUsedText)"
        } else if lastUsed != nil {
            metadataText = lastUsedText
        } else {
            metadataText = String(localized: "Not used yet", bundle: WinkResourceBundle.bundle)
        }

        contentOpacity = shortcut.isEnabled ? 1.0 : 0.65
        showsRunningIndicator = runtimeStatus.isRunning
        runningStatusText = runtimeStatus.isRunning && accessibilityOptions.differentiateWithoutColor
            ? String(localized: "Running", bundle: WinkResourceBundle.bundle)
            : nil
        unavailableStatusText = runtimeStatus.isUnavailable
            ? String(localized: "App unavailable", bundle: WinkResourceBundle.bundle)
            : nil
        unavailableHelpText = runtimeStatus.isUnavailable
            ? String(localized: "Couldn't find this app. Rebind it to restore the shortcut.", bundle: WinkResourceBundle.bundle)
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
        if status.shortcutsPaused {
            self = .info(
                title: String(localized: "Shortcuts paused", bundle: WinkResourceBundle.bundle),
                message: status.bannerDetail
            )
            return
        }

        if !status.accessibilityGranted {
            self = .warning(
                title: String(localized: "Accessibility permission needed", bundle: WinkResourceBundle.bundle),
                message: String(localized: "Wink needs Accessibility access to route global shortcuts.", bundle: WinkResourceBundle.bundle),
                showsAction: true
            )
            return
        }

        if status.inputMonitoringRequired && !status.inputMonitoringGranted {
            self = .warning(
                title: String(localized: "Input Monitoring needed", bundle: WinkResourceBundle.bundle),
                message: String(localized: "Some shortcuts need Input Monitoring before Wink can capture them.", bundle: WinkResourceBundle.bundle),
                showsAction: true
            )
            return
        }

        if let warning = status.standardRegistrationWarning {
            self = .warning(
                title: String(localized: "Shortcut capture needs attention", bundle: WinkResourceBundle.bundle),
                message: warning,
                showsAction: false
            )
            return
        }

        if status.inputMonitoringRequired,
           let warning = status.permissionWarning {
            self = .warning(
                title: String(localized: "Shortcut capture needs attention", bundle: WinkResourceBundle.bundle),
                message: warning,
                showsAction: false
            )
            return
        }

        let title: String
        if status.standardShortcutsReady && status.hyperShortcutsReady {
            title = String(localized: "Shortcut capture ready", bundle: WinkResourceBundle.bundle)
        } else {
            title = String(localized: "Standard shortcuts ready", bundle: WinkResourceBundle.bundle)
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
    @State private var shortcutRowFrames: [UUID: CGRect] = [:]
    @State private var draggingShortcutID: UUID?
    @State private var dragStartSourceFrame: CGRect?
    @State private var dragTranslationY: CGFloat = 0

    private var filteredShortcuts: [AppShortcut] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return editor.shortcuts
        }

        return editor.shortcuts.filter { shortcut in
            shortcut.displayAppName.localizedCaseInsensitiveContains(query)
                || shortcut.displayText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let importPreviewActive = editor.pendingRecipeImport != nil

        VStack(alignment: .leading, spacing: 14) {
            SettingsTabHeader(
                title: String(localized: "Shortcuts", bundle: WinkResourceBundle.bundle),
                subtitle: String(localized: "Bind a keystroke to launch, toggle, or hide an app.", bundle: WinkResourceBundle.bundle)
            ) {
                WinkButton(String(localized: "Refresh", bundle: WinkResourceBundle.bundle), systemImage: WinkIcon.refresh.systemName) {
                    preferences.requestShortcutPermissions()
                }
            }

            permissionBanner

            WinkCard(
                title: {
                    Text("New Shortcut", bundle: WinkResourceBundle.bundle)
                }
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            SettingsFieldLabel(String(localized: "Target app", bundle: WinkResourceBundle.bundle))
                            Button {
                                showingAppPicker = true
                            } label: {
                                HStack(spacing: 8) {
                                    if editor.selectedBundleIdentifier.isEmpty {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(palette.appPlaceholderSwatchBg)
                                            .frame(width: 18, height: 18)
                                            .overlay {
                                                WinkIcon.plus.image(size: 10)
                                                    .foregroundStyle(.white)
                                            }

                                        Text("Choose an app…", bundle: WinkResourceBundle.bundle)
                                            .font(WinkType.bodyText)
                                            .foregroundStyle(palette.textTertiary)
                                    } else {
                                        AppIconView(bundleIdentifier: editor.selectedBundleIdentifier, size: 20)
                                        // `selectedAppName` holds the locale-stable name for a
                                        // pseudo-target selection (it becomes the persisted
                                        // appName on Add) — resolve the localized label here,
                                        // display-only.
                                        Text(
                                            editor.selectedBundleIdentifier == AppShortcut.frontmostTargetSentinelBundleIdentifier
                                                ? AppShortcut.frontmostTargetDisplayName
                                                : editor.selectedAppName
                                        )
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
                            SettingsFieldLabel(
                                String(localized: "Shortcut", bundle: WinkResourceBundle.bundle),
                                trailing: String(localized: "Click to record", bundle: WinkResourceBundle.bundle)
                            )

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
                            Text("Tip: hold", bundle: WinkResourceBundle.bundle)
                            WinkKeycap("Caps Lock", size: .small)
                            Text("for a Hyper shortcut.", bundle: WinkResourceBundle.bundle)
                        }
                        .font(WinkType.labelSmall)
                        .foregroundStyle(palette.textTertiary)

                        Spacer(minLength: 8)

                        WinkButton(String(localized: "Clear", bundle: WinkResourceBundle.bundle)) {
                            editor.clearRecordedShortcut()
                        }
                        .disabled(importPreviewActive || (editor.recordedShortcut == nil && !editor.isRecordingShortcut))

                        WinkButton(String(localized: "Add Shortcut", bundle: WinkResourceBundle.bundle), variant: .primary) {
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

            if let saveErrorMessage = editor.saveErrorMessage {
                Text(saveErrorMessage)
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
                    WinkButton(String(localized: "Refresh", bundle: WinkResourceBundle.bundle)) {
                        preferences.refreshPermissions()
                    }
                }
            }
        }
    }

    private var permissionActionTitle: String {
        let status = preferences.shortcutCaptureStatus
        if !status.accessibilityGranted {
            return String(localized: "Request Accessibility", bundle: WinkResourceBundle.bundle)
        }
        if status.inputMonitoringRequired && !status.inputMonitoringGranted {
            return String(localized: "Request Input Monitoring", bundle: WinkResourceBundle.bundle)
        }
        return String(localized: "Request Access", bundle: WinkResourceBundle.bundle)
    }

    @ViewBuilder
    private func shortcutsCard(importPreviewActive: Bool) -> some View {
        let canReorder = filterText.isEmpty && !importPreviewActive

        WinkCard(
            title: {
                Text("Your Shortcuts · \(editor.shortcuts.count)", bundle: WinkResourceBundle.bundle)
            },
            accessory: {
                HStack(spacing: 6) {
                    WinkTextField(
                        placeholder: String(localized: "Filter…", bundle: WinkResourceBundle.bundle),
                        text: $filterText,
                        leading: {
                            WinkIcon.search.image(size: 11)
                                .foregroundStyle(palette.textTertiary)
                        }
                    )
                    .frame(width: 140)

                    Menu {
                        Button(String(localized: "Import…", bundle: WinkResourceBundle.bundle)) {
                            Task {
                                await editor.importRecipes(using: appListProvider)
                            }
                        }
                        Button(String(localized: "Export…", bundle: WinkResourceBundle.bundle)) {
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
                    .help(String(localized: "Import or export shortcuts", bundle: WinkResourceBundle.bundle))
                    .disabled(importPreviewActive)
                }
            }
        ) {
            if filteredShortcuts.isEmpty {
                Text(
                    filterText.isEmpty
                        ? String(localized: "No shortcuts configured", bundle: WinkResourceBundle.bundle)
                        : String(localized: "No shortcuts match your filter", bundle: WinkResourceBundle.bundle)
                )
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
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: proxy.size.height, alignment: .top)
                    }
                    .coordinateSpace(name: ShortcutListCoordinateSpace.name)
                    .onPreferenceChange(ShortcutRowFramePreferenceKey.self) { frames in
                        shortcutRowFrames = frames
                    }
                    .scrollIndicators(.automatic, axes: .vertical)
                    .scrollDisabled(draggingShortcutID != nil)
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

    // Drag-to-reorder is local to the visible shortcut list. We gate it on
    // `canReorder` so filtering or an active import preview cannot produce a
    // silently-wrong reorder against the full shortcut list.
    @ViewBuilder
    private func reorderableRow(_ shortcut: AppShortcut, index: Int, canReorder: Bool) -> some View {
        if canReorder {
            shortcutRow(
                shortcut,
                index: index,
                reorderHandlers: ShortcutRowReorderHandlers(
                    onChanged: { value in
                        beginReorderDragIfNeeded(shortcutID: shortcut.id)
                        dragTranslationY = Self.reorderTranslationY(from: value)
                    },
                    onEnded: { value in
                        completeReorderDrag(
                            shortcutID: shortcut.id,
                            translationY: Self.reorderTranslationY(from: value)
                        )
                    }
                )
            )
                .background(rowFrameReader(for: shortcut.id))
                .offset(y: draggingShortcutID == shortcut.id ? dragTranslationY : 0)
                .zIndex(draggingShortcutID == shortcut.id ? 1 : 0)
        } else {
            shortcutRow(shortcut, index: index)
        }
    }

    private func rowFrameReader(for shortcutID: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ShortcutRowFramePreferenceKey.self,
                value: [shortcutID: proxy.frame(in: .named(ShortcutListCoordinateSpace.name))]
            )
        }
    }

    private func completeReorderDrag(shortcutID: UUID, translationY: CGFloat) {
        defer {
            draggingShortcutID = nil
            dragStartSourceFrame = nil
            dragTranslationY = 0
        }

        // Treat sub-pixel translations as a stationary click on the grip — avoid
        // reordering when the user merely tapped the handle without dragging.
        guard abs(translationY) >= ShortcutsTabView.minimumReorderTranslation else {
            return
        }

        guard let offset = visibleDropOffset(for: shortcutID, translationY: translationY) else {
            return
        }

        editor.reorderShortcut(
            draggedID: shortcutID,
            toVisibleOffset: offset,
            visibleShortcutIDs: filteredShortcuts.map(\.id)
        )
    }

    fileprivate static let minimumReorderTranslation: CGFloat = 4

    private func visibleDropOffset(for shortcutID: UUID, translationY: CGFloat) -> Int? {
        ShortcutReorderPlanner.visibleDropOffset(
            for: shortcutID,
            translationY: translationY,
            visibleShortcutIDs: filteredShortcuts.map(\.id),
            rowFrames: shortcutRowFrames,
            sourceFrame: dragStartSourceFrame
        )
    }

    private func beginReorderDragIfNeeded(shortcutID: UUID) {
        guard draggingShortcutID != shortcutID else {
            return
        }

        dragStartSourceFrame = shortcutRowFrames[shortcutID]
        draggingShortcutID = shortcutID
    }

    private static func reorderTranslationY(from value: DragGesture.Value) -> CGFloat {
        value.location.y - value.startLocation.y
    }

    @ViewBuilder
    private func shortcutRow(
        _ shortcut: AppShortcut,
        index: Int,
        reorderHandlers: ShortcutRowReorderHandlers? = nil
    ) -> some View {
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
            isReordering: draggingShortcutID == shortcut.id,
            onToggleEnabled: {
                editor.toggleShortcutEnabled(id: shortcut.id)
            },
            onRemove: {
                editor.removeShortcut(id: shortcut.id)
            },
            onSetFrontmostBehaviorOverride: { behavior in
                editor.setFrontmostBehaviorOverride(id: shortcut.id, behavior: behavior)
            },
            onSetHoldAction: { holdAction in
                editor.setHoldAction(id: shortcut.id, holdAction: holdAction)
            },
            reorderHandlers: reorderHandlers
        )
    }

    @ViewBuilder
    private func importPreviewCard(_ plan: WinkRecipeImportPlanner.ImportPlan) -> some View {
        WinkCard(
            title: {
                Text("Import Preview", bundle: WinkResourceBundle.bundle)
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    statView(title: String(localized: "Ready", bundle: WinkResourceBundle.bundle), count: plan.readyEntries.count, tint: palette.green)
                    statView(title: String(localized: "Conflicts", bundle: WinkResourceBundle.bundle), count: plan.conflictEntries.count, tint: palette.amber)
                    statView(title: String(localized: "Unresolved", bundle: WinkResourceBundle.bundle), count: plan.unresolvedEntries.count, tint: palette.textSecondary)
                }

                importPreviewDetails(plan)

                HStack(spacing: 8) {
                    WinkButton(String(localized: "Cancel", bundle: WinkResourceBundle.bundle)) {
                        editor.discardPendingRecipeImport()
                    }

                    Spacer(minLength: 8)

                    WinkButton(String(localized: "Skip Conflicts", bundle: WinkResourceBundle.bundle)) {
                        editor.applyPendingImport(strategy: .skipConflicts)
                    }

                    WinkButton(String(localized: "Replace Existing", bundle: WinkResourceBundle.bundle), variant: .primary) {
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
                            Text("Conflicts", bundle: WinkResourceBundle.bundle)
                                .font(WinkType.captionStrong)
                                .foregroundStyle(palette.textPrimary)

                            ForEach(plan.conflictEntries) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(entry.imported.displayAppName) · \(entry.imported.displayText)")
                                        .font(WinkType.labelSmall)
                                        .foregroundStyle(palette.textPrimary)
                                    if let conflictingShortcut = entry.conflictingShortcut {
                                        Text("Conflicts with \(conflictingShortcut.displayAppName) · \(conflictingShortcut.displayText)", bundle: WinkResourceBundle.bundle)
                                            .font(WinkType.labelSmall)
                                            .foregroundStyle(palette.textSecondary)
                                    }
                                }
                            }
                        }
                    }

                    if !plan.unresolvedEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Unresolved apps without conflicts will still be imported using their recipe app name and bundle identifier.", bundle: WinkResourceBundle.bundle)
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
    let isReordering: Bool
    let onToggleEnabled: @MainActor () -> Void
    let onRemove: @MainActor () -> Void
    let onSetFrontmostBehaviorOverride: @MainActor (FrontmostTargetBehavior?) -> Void
    let onSetHoldAction: @MainActor (HoldAction?) -> Void
    let reorderHandlers: ShortcutRowReorderHandlers?

    @State private var isRowHovering = false
    @State private var isMenuButtonHovering = false

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
            gripHandle

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
                        .help(String(localized: "App is currently running", bundle: WinkResourceBundle.bundle))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(presentation.metadataText)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let unavailableStatusText = presentation.unavailableStatusText {
                    // `unavailableStatusText`/`unavailableHelpText` are already
                    // localized `String` values built in `ShortcutsListRowPresentation`
                    // — `Label`/`.help` take a concrete `String` verbatim (no further
                    // catalog lookup) via their `StringProtocol` overloads.
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
        .background(isRowHovering ? Color.primary.opacity(0.035) : Color.clear)
        .onHover { isRowHovering = $0 }
        .opacity(presentation.contentOpacity)
        .animation(statusAnimation, value: statusAnimationKey)
    }

    @ViewBuilder
    private var gripHandle: some View {
        let icon = WinkIcon.grip.image(size: 12, weight: .semibold)
            .foregroundStyle(palette.textTertiary)
            .frame(
                width: ShortcutRowMetrics.gripColumnWidth,
                height: ShortcutRowMetrics.gripHitHeight
            )
            .contentShape(Rectangle())
            .help(String(localized: "Drag to reorder", bundle: WinkResourceBundle.bundle))

        if let reorderHandlers {
            icon
                .overlay {
                    ShortcutGripCursorRegion(cursor: isReordering ? .closedHand : .openHand)
                }
                .simultaneousGesture(
                    DragGesture(
                        minimumDistance: 2,
                        coordinateSpace: .named(ShortcutListCoordinateSpace.name)
                    )
                    .onChanged(reorderHandlers.onChanged)
                    .onEnded(reorderHandlers.onEnded)
                )
        } else {
            icon
        }
    }

    // The row badge is one unified pill holding the whole chord string, unlike
    // the composer's live-record preview which shows discrete Keycap chips
    // per modifier (tab-shortcuts.jsx:143-151 vs. :91-93).
    private var shortcutBadge: some View {
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

            shortcutBadge
                .frame(width: ShortcutRowMetrics.shortcutColumnWidth, alignment: .trailing)

            WinkSwitch(isOn: Binding(
                get: { shortcut.isEnabled },
                set: { _ in onToggleEnabled() }
            ))
            .frame(width: ShortcutRowMetrics.switchColumnWidth)
            .disabled(importPreviewActive)

            Menu {
                Picker(String(localized: "When Frontmost", bundle: WinkResourceBundle.bundle), selection: Binding(
                    get: { shortcut.frontmostBehaviorOverride },
                    set: { onSetFrontmostBehaviorOverride($0) }
                )) {
                    Text(String(localized: "Default", bundle: WinkResourceBundle.bundle)).tag(FrontmostTargetBehavior?.none)
                    ForEach(FrontmostTargetBehavior.allCases, id: \.self) { behavior in
                        // `behavior.title` is already localized (AppPreferences.swift).
                        Text(behavior.title).tag(FrontmostTargetBehavior?.some(behavior))
                    }
                }
                .pickerStyle(.menu)

                Picker(String(localized: "Hold Action", bundle: WinkResourceBundle.bundle), selection: Binding(
                    get: { shortcut.holdAction },
                    set: { onSetHoldAction($0) }
                )) {
                    Text(String(localized: "None", bundle: WinkResourceBundle.bundle)).tag(HoldAction?.none)
                    ForEach(HoldAction.allCases, id: \.self) { action in
                        Text(action.title).tag(HoldAction?.some(action))
                    }
                }
                .pickerStyle(.menu)

                Divider()

                Button(String(localized: "Delete Shortcut", bundle: WinkResourceBundle.bundle), role: .destructive, action: onRemove)
            } label: {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isMenuButtonHovering ? palette.controlBgRest : Color.clear)
                    .frame(width: ShortcutRowMetrics.actionButtonSize, height: ShortcutRowMetrics.actionButtonSize)
                    .overlay {
                        WinkIcon.more.image(size: 12)
                            .foregroundStyle(palette.textTertiary)
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: ShortcutRowMetrics.actionButtonSize, height: ShortcutRowMetrics.actionButtonSize)
            .onHover { isMenuButtonHovering = $0 }
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
    nonisolated static var placeholderText: String {
        String(localized: "Press a key combination…", bundle: WinkResourceBundle.bundle)
    }
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
