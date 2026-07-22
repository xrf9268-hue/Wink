import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class MenuBarPopoverModel {
    private final class ObservationToken {
        let center: NotificationCenter
        let token: NSObjectProtocol

        init(center: NotificationCenter, token: NSObjectProtocol) {
            self.center = center
            self.token = token
        }

        deinit {
            center.removeObserver(token)
        }
    }

    struct ShortcutRow: Identifiable, Equatable {
        let id: UUID
        let shortcut: AppShortcut
        let isRunning: Bool
        let isUnavailable: Bool

        var title: String {
            shortcut.displayAppName
        }

        var statusText: String? {
            if isUnavailable {
                return String(localized: "App unavailable", bundle: WinkResourceBundle.bundle)
            }

            if !shortcut.isEnabled {
                return String(localized: "Disabled", bundle: WinkResourceBundle.bundle)
            }

            return nil
        }
    }

    private let shortcutStore: ShortcutStore
    private let preferences: AppPreferences
    private let shortcutStatusProvider: ShortcutStatusProvider
    private let usageTracker: any UsageTracking
    private let openSettingsAction: @MainActor (SettingsTab?) -> Void
    private let quitAction: @MainActor () -> Void
    private let workspaceNotificationCenter: NotificationCenter
    private let appNotificationCenter: NotificationCenter
    private var usageRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var observationTokens: [ObservationToken] = []

    var searchText = ""
    private(set) var shortcutRows: [ShortcutRow] = []
    private(set) var todayActivationCount = 0
    private(set) var todayHistogramBars = Array(repeating: 0.0, count: 24)

    init(
        shortcutStore: ShortcutStore,
        preferences: AppPreferences,
        shortcutStatusProvider: ShortcutStatusProvider,
        usageTracker: any UsageTracking,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        appNotificationCenter: NotificationCenter = .default,
        openSettings: @escaping @MainActor (SettingsTab?) -> Void,
        quit: @escaping @MainActor () -> Void
    ) {
        self.shortcutStore = shortcutStore
        self.preferences = preferences
        self.shortcutStatusProvider = shortcutStatusProvider
        self.usageTracker = usageTracker
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.appNotificationCenter = appNotificationCenter
        self.openSettingsAction = openSettings
        self.quitAction = quit
        observeNotifications()
        refresh()
    }

    var versionText: String {
        "v\(preferences.updatePresentation.currentVersion)"
    }

    var shortcutsPaused: Bool {
        preferences.shortcutsPaused
    }

    var autoPauseTriggerAppName: String? {
        preferences.autoPauseTriggerAppName
    }

    var secureInputActive: Bool {
        preferences.shortcutCaptureStatus.secureInputActive
    }

    var isCheckForUpdatesEnabled: Bool {
        preferences.updatePresentation.checkForUpdatesEnabled
    }

    /// Explains the disabled Check for Updates row instead of leaving a bare
    /// dead control (dev builds ship without an injected Sparkle feed).
    var updateUnavailableCaption: String? {
        preferences.updatePresentation.isConfigured
            ? nil
            : String(localized: "Updates are available in packaged builds with a signed update feed.", bundle: WinkResourceBundle.bundle)
    }

    struct UpdateNotice: Equatable {
        let title: String
        let subtitle: String
    }

    /// Non-modal surface for scheduled update findings (gentle sessions):
    /// clicking runs a user-initiated check, which resumes the held session
    /// into the Wink update panel.
    var updateNotice: UpdateNotice? {
        switch preferences.updatePhase {
        case .idle, .checking, .error, .upToDate, .installing:
            return nil
        case .available(let version):
            return UpdateNotice(
                title: String(localized: "Update available — v\(version)", bundle: WinkResourceBundle.bundle),
                subtitle: String(localized: "Click to review and install.", bundle: WinkResourceBundle.bundle)
            )
        case .downloading(let version, _, _):
            return UpdateNotice(
                title: String(localized: "Downloading update — v\(version)", bundle: WinkResourceBundle.bundle),
                subtitle: String(localized: "Click to view progress.", bundle: WinkResourceBundle.bundle)
            )
        case .extracting:
            return UpdateNotice(
                title: String(localized: "Preparing update…", bundle: WinkResourceBundle.bundle),
                subtitle: String(localized: "Click to view progress.", bundle: WinkResourceBundle.bundle)
            )
        case .ready(let version):
            return UpdateNotice(
                title: String(localized: "Update ready — v\(version)", bundle: WinkResourceBundle.bundle),
                subtitle: String(localized: "Installs when Wink quits. Click to install now.", bundle: WinkResourceBundle.bundle)
            )
        }
    }

    var filteredShortcutRows: [ShortcutRow] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            return shortcutRows
        }

        return shortcutRows.filter { row in
            row.title.localizedCaseInsensitiveContains(trimmedSearch)
                || row.shortcut.bundleIdentifier.localizedCaseInsensitiveContains(trimmedSearch)
        }
    }

    func refresh() {
        let shortcuts = shortcutStore.shortcuts
        shortcutStatusProvider.track(shortcuts)
        shortcutRows = shortcuts.map { shortcut in
            let status = shortcutStatusProvider.status(for: shortcut)
            return ShortcutRow(
                id: shortcut.id,
                shortcut: shortcut,
                isRunning: status.isRunning,
                isUnavailable: status.isUnavailable
            )
        }
        refreshUsage()
    }

    func waitForUsageRefreshForTesting() async {
        await usageRefreshTask?.value
    }

    func setShortcutsPaused(_ paused: Bool) {
        preferences.setShortcutsPaused(paused)
    }

    func openSettings() {
        openSettingsAction(nil)
    }

    func openManageShortcuts() {
        openSettingsAction(.shortcuts)
    }

    func checkForUpdates() {
        preferences.checkForUpdates()
    }

    func quit() {
        quitAction()
    }

    private func observeNotifications() {
        let workspaceNotifications: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]

        for name in workspaceNotifications {
            addObservation(for: name, center: workspaceNotificationCenter)
        }

        addObservation(
            for: NSApplication.didBecomeActiveNotification,
            center: appNotificationCenter
        )
    }

    private func addObservation(
        for name: Notification.Name,
        center: NotificationCenter
    ) {
        let token = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.refresh()
            }
        }

        observationTokens.append(ObservationToken(center: center, token: token))
    }

    private func refreshUsage() {
        usageRefreshTask?.cancel()
        let usageTracker = self.usageTracker
        usageRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let hourlyBuckets = await usageTracker.hourlyCounts(days: 1)
            let bars = hourlyBuckets.isEmpty
                ? Array(repeating: 0.0, count: 24)
                : hourlyBuckets.map(\.count).map(Double.init)
            let totalCount = hourlyBuckets.reduce(0) { partialResult, item in
                partialResult + item.count
            }
            guard !Task.isCancelled else { return }
            todayActivationCount = totalCount
            todayHistogramBars = bars
        }
    }
}

/// Tighter NSMenu-style row metrics for the popover's list/footer rows —
/// distinct from `ShortcutsTabView`'s `ShortcutRowMetrics`, which are sized
/// for the full Shortcuts tab rather than menubar.jsx's compact rows.
private enum MenuBarRowMetrics {
    static let rowHorizontalPadding: CGFloat = 8
    static let listRowVerticalPadding: CGFloat = 6
    static let listRowSpacing: CGFloat = 9
    static let listRowCornerRadius: CGFloat = 6
    static let footerRowVerticalPadding: CGFloat = 5
    static let footerRowCornerRadius: CGFloat = 5
}

struct MenuBarPopoverView: View {
    @Environment(\.winkPalette) private var palette

    @Bindable var model: MenuBarPopoverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                header
                search
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            todaySection
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider().overlay(palette.hairline)

            shortcutsHeader

            shortcutsList
                .layoutPriority(1)

            Divider().overlay(palette.hairline)

            manageRow

            Divider().overlay(palette.hairline)

            actionsSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.windowBg)
        .onAppear {
            model.refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            WinkAppIcon(size: 24)

            VStack(alignment: .leading, spacing: 2) {
                WinkWordmark(size: 14, color: palette.textPrimary)
                Text(model.versionText)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer(minLength: 8)

            MenuBarStatusPill(
                paused: model.shortcutsPaused || model.autoPauseTriggerAppName != nil,
                autoPausedBy: model.autoPauseTriggerAppName,
                secureInputActive: model.secureInputActive
            )
        }
    }

    private var search: some View {
        WinkTextField(
            placeholder: String(localized: "Search shortcuts", bundle: WinkResourceBundle.bundle),
            text: $model.searchText
        ) {
            WinkIcon.search.image(size: 11)
                .foregroundStyle(palette.textTertiary)
        } trailing: {
            WinkKeycap("⌘K", size: .small)
        }
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                WinkSectionLabel(String(localized: "Today", bundle: WinkResourceBundle.bundle))
                Spacer(minLength: 8)
                Text("\(model.todayActivationCount) activations", bundle: WinkResourceBundle.bundle)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textTertiary)
            }
            MenuBarTodayHistogram(
                bars: model.todayHistogramBars
            )
        }
    }

    private var shortcutsHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            WinkSectionLabel(String(localized: "Shortcuts", bundle: WinkResourceBundle.bundle))
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var shortcutsList: some View {
        let filteredRows = model.filteredShortcutRows
        return Group {
            if model.shortcutRows.isEmpty {
                Text("No shortcuts configured", bundle: WinkResourceBundle.bundle)
                    .font(WinkType.bodyText)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else if filteredRows.isEmpty {
                Text("No shortcuts match your search", bundle: WinkResourceBundle.bundle)
                    .font(WinkType.bodyText)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredRows) { row in
                                MenuBarShortcutRow(row: row)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: proxy.size.height, alignment: .top)
                    }
                    .scrollIndicators(.automatic, axes: .vertical)
                }
                .frame(minHeight: 120, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var manageRow: some View {
        Button(action: model.openManageShortcuts) {
            HStack(spacing: 6) {
                Text("Manage…", bundle: WinkResourceBundle.bundle)
                WinkIcon.chevronRight.image(size: 10)
            }
            .font(WinkType.bodyMedium)
            .foregroundStyle(palette.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private var actionsSection: some View {
        VStack(spacing: 0) {
            MenuBarToggleRow(
                title: String(localized: "Pause all shortcuts", bundle: WinkResourceBundle.bundle),
                isOn: Binding(
                    get: { model.shortcutsPaused },
                    set: { model.setShortcutsPaused($0) }
                )
            )

            Divider().overlay(palette.hairline)

            MenuBarActionRow(
                title: String(localized: "Settings…", bundle: WinkResourceBundle.bundle),
                keycaps: ["⌘", ","],
                action: model.openSettings
            )

            Divider().overlay(palette.hairline)

            if let notice = model.updateNotice {
                MenuBarUpdateNoticeRow(notice: notice, action: model.checkForUpdates)

                Divider().overlay(palette.hairline)
            }

            MenuBarActionRow(
                title: String(localized: "Check for Updates…", bundle: WinkResourceBundle.bundle),
                action: model.checkForUpdates
            )
            .disabled(!model.isCheckForUpdatesEnabled)

            if let caption = model.updateUnavailableCaption {
                Text(caption)
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Divider().overlay(palette.hairline)

            MenuBarActionRow(
                title: String(localized: "Quit Wink", bundle: WinkResourceBundle.bundle),
                keycaps: ["⌘", "Q"],
                action: model.quit
            )
        }
        .padding(.bottom, 8)
    }
}

private struct MenuBarStatusPill: View {
    @Environment(\.winkPalette) private var palette

    let paused: Bool
    var autoPausedBy: String?
    var secureInputActive: Bool = false

    private var title: String {
        guard paused else {
            // Secure Input silently starves the Hyper/event-tap route;
            // name it instead of showing a false "Ready".
            return secureInputActive
                ? String(localized: "Limited · Secure Input", bundle: WinkResourceBundle.bundle)
                : String(localized: "Ready", bundle: WinkResourceBundle.bundle)
        }
        // Exception auto-pause names its trigger (an NSWorkspace app display
        // name — not itself localized) so "my shortcuts are dead" never
        // reads as a mystery.
        if let autoPausedBy {
            return String(localized: "Paused · \(autoPausedBy)", bundle: WinkResourceBundle.bundle)
        }
        return String(localized: "Paused", bundle: WinkResourceBundle.bundle)
    }

    private var degraded: Bool {
        paused || secureInputActive
    }

    private var background: Color {
        degraded ? palette.amberBgSoft : palette.greenSoft
    }

    private var foreground: Color {
        degraded ? palette.amber : palette.green
    }

    var body: some View {
        Text(title)
            .help(secureInputActive && !paused
                ? String(
                    localized: "A password field or secure prompt is capturing keyboard input. Hyper and Fn-based shortcuts may not fire until it ends; other standard shortcuts keep working.",
                    bundle: WinkResourceBundle.bundle
                  )
                : "")
            .font(WinkType.labelSmall.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background)
            .clipShape(Capsule())
    }
}

private struct MenuBarTodayHistogram: View {
    @Environment(\.winkPalette) private var palette

    let bars: [Double]

    private var currentHour: Int {
        Calendar.current.component(.hour, from: Date())
    }

    var body: some View {
        GeometryReader { geometry in
            let maxValue = max(bars.max() ?? 0, 1)
            let barWidth = max((geometry.size.width - CGFloat(max(0, bars.count - 1)) * 4) / CGFloat(max(bars.count, 1)), 4)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fill(for: index))
                        .frame(
                            width: barWidth,
                            height: height(
                                for: value,
                                maxValue: maxValue,
                                availableHeight: geometry.size.height
                            )
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(height: 84)
    }

    private func fill(for hour: Int) -> Color {
        if hour == currentHour {
            return palette.accent
        }

        if hour < currentHour {
            return palette.accentBgSoft
        }

        return palette.textPrimary.opacity(0.04)
    }

    private func height(for value: Double, maxValue: Double, availableHeight: CGFloat) -> CGFloat {
        let normalized = maxValue > 0 ? value / maxValue : 0
        let minHeight: CGFloat = 10
        return max(CGFloat(normalized) * availableHeight, minHeight)
    }
}

private struct MenuBarShortcutRow: View {
    @Environment(\.winkPalette) private var palette
    @State private var isHovering = false

    let row: MenuBarPopoverModel.ShortcutRow

    var body: some View {
        HStack(spacing: MenuBarRowMetrics.listRowSpacing) {
            AppIconView(
                bundleIdentifier: row.shortcut.bundleIdentifier,
                size: 22
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(WinkType.bodyMedium)
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)

                    if row.isRunning {
                        WinkStatusDot(color: palette.green)
                    }
                }

                if let statusText = row.statusText {
                    Text(statusText)
                        .font(WinkType.labelSmall)
                        .foregroundStyle(row.isUnavailable ? palette.amber : palette.textTertiary)
                }
            }

            Spacer(minLength: 8)

            if row.shortcut.isHyper {
                WinkHyperBadge(size: .small)
            }

            WinkShortcutGlyph(
                ShortcutKeycapStrip.labels(
                    keyEquivalent: row.shortcut.keyEquivalent,
                    modifierFlags: row.shortcut.modifierFlags
                ).joined()
            )
        }
        .padding(.horizontal, MenuBarRowMetrics.rowHorizontalPadding)
        .padding(.vertical, MenuBarRowMetrics.listRowVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: MenuBarRowMetrics.listRowCornerRadius, style: .continuous)
                .fill(isHovering ? palette.sidebarItemHover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .opacity(row.shortcut.isEnabled ? 1 : 0.6)
    }
}

private struct MenuBarToggleRow: View {
    @Environment(\.winkPalette) private var palette
    @State private var isHovering = false

    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: MenuBarRowMetrics.listRowSpacing) {
            Text(title)
                .font(WinkType.bodyMedium)
                .foregroundStyle(palette.textPrimary)

            Spacer(minLength: 8)

            WinkSwitch(isOn: isOn, size: .small)
        }
        .padding(.horizontal, MenuBarRowMetrics.rowHorizontalPadding)
        .padding(.vertical, MenuBarRowMetrics.listRowVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: MenuBarRowMetrics.listRowCornerRadius, style: .continuous)
                .fill(isHovering ? palette.sidebarItemHover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

private struct MenuBarUpdateNoticeRow: View {
    @Environment(\.winkPalette) private var palette

    let notice: MenuBarPopoverModel.UpdateNotice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(WinkType.bodyMedium)
                        .foregroundStyle(palette.textPrimary)
                    Text(notice.subtitle)
                        .font(WinkType.labelSmall)
                        .foregroundStyle(palette.textSecondary)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MenuBarUpdateNoticeRow")
    }
}

private struct MenuBarActionRow: View {
    @Environment(\.winkPalette) private var palette
    @State private var isHovering = false

    let title: String
    var keycaps: [String] = []
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(WinkType.bodyMedium)
                    .foregroundStyle(palette.textPrimary)

                Spacer(minLength: 8)

                if !keycaps.isEmpty {
                    WinkShortcutGlyph(keycaps.joined())
                }
            }
            .padding(.horizontal, MenuBarRowMetrics.rowHorizontalPadding)
            .padding(.vertical, MenuBarRowMetrics.footerRowVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: MenuBarRowMetrics.footerRowCornerRadius, style: .continuous)
                    .fill(isHovering ? palette.sidebarItemHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
