import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class MenuBarPopoverModel {
    private struct ObservationToken {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    struct ShortcutRow: Identifiable, Equatable {
        let id: UUID
        let shortcut: AppShortcut
        let isRunning: Bool
        let isUnavailable: Bool

        var title: String {
            shortcut.appName
        }

        var statusText: String? {
            if isUnavailable {
                return "App unavailable"
            }

            if !shortcut.isEnabled {
                return "Disabled"
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
    private nonisolated(unsafe) var observationTokens: [ObservationToken] = []

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

    deinit {
        for observation in observationTokens {
            observation.center.removeObserver(observation.token)
        }
    }

    var versionText: String {
        "v\(preferences.updatePresentation.currentVersion)"
    }

    var shortcutsPaused: Bool {
        preferences.shortcutsPaused
    }

    var isCheckForUpdatesEnabled: Bool {
        preferences.updatePresentation.checkForUpdatesEnabled
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

struct MenuBarPopoverView: View {
    @Environment(\.winkPalette) private var palette

    @Bindable var model: MenuBarPopoverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            search
            todayCard
            shortcutsCard
            actionsCard
        }
        .padding(12)
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

            MenuBarStatusPill(paused: model.shortcutsPaused)
        }
    }

    private var search: some View {
        WinkTextField(
            placeholder: "Search shortcuts",
            text: $model.searchText
        ) {
            WinkIcon.search.image(size: 11)
                .foregroundStyle(palette.textTertiary)
        } trailing: {
            WinkKeycap("⌘K", size: .small)
        }
    }

    private var todayCard: some View {
        WinkCard(
            title: {
                Text("Today")
            },
            accessory: {
                Text("\(model.todayActivationCount) activations")
                    .font(WinkType.labelSmall)
                    .foregroundStyle(palette.textTertiary)
            }
        ) {
            MenuBarTodayHistogram(
                bars: model.todayHistogramBars
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var shortcutsCard: some View {
        WinkCard(
            title: {
                Text("Shortcuts")
            }
        ) {
            let filteredRows = model.filteredShortcutRows
            if model.shortcutRows.isEmpty {
                Text("No shortcuts configured")
                    .font(WinkType.bodyText)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            } else if filteredRows.isEmpty {
                Text("No shortcuts match your search")
                    .font(WinkType.bodyText)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredRows.enumerated()), id: \.element.id) { index, row in
                                MenuBarShortcutRow(row: row)

                                if index < filteredRows.count - 1 {
                                    Divider()
                                        .overlay(palette.hairline)
                                        .padding(.leading, 48)
                                }
                            }
                        }
                        .frame(width: proxy.size.width, alignment: .leading)
                        .frame(minHeight: proxy.size.height, alignment: .top)
                    }
                    .scrollIndicators(.automatic, axes: .vertical)
                }
                .frame(minHeight: 120, maxHeight: .infinity, alignment: .top)
            }

            Divider().overlay(palette.hairline)

            Button(action: model.openManageShortcuts) {
                HStack(spacing: 6) {
                    Text("Manage…")
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
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .layoutPriority(1)
    }

    private var actionsCard: some View {
        WinkCard {
            VStack(spacing: 0) {
                MenuBarToggleRow(
                    title: "Pause all shortcuts",
                    isOn: Binding(
                        get: { model.shortcutsPaused },
                        set: { model.setShortcutsPaused($0) }
                    )
                )

                Divider().overlay(palette.hairline)

                MenuBarActionRow(
                    title: "Settings…",
                    keycaps: ["⌘", ","],
                    action: model.openSettings
                )

                Divider().overlay(palette.hairline)

                MenuBarActionRow(
                    title: "Check for Updates…",
                    action: model.checkForUpdates
                )
                .disabled(!model.isCheckForUpdatesEnabled)

                Divider().overlay(palette.hairline)

                MenuBarActionRow(
                    title: "Quit Wink",
                    keycaps: ["⌘", "Q"],
                    action: model.quit
                )
            }
        }
    }
}

private struct MenuBarStatusPill: View {
    @Environment(\.winkPalette) private var palette

    let paused: Bool

    private var title: String {
        paused ? "Paused" : "Ready"
    }

    private var background: Color {
        paused ? palette.amberBgSoft : palette.greenSoft
    }

    private var foreground: Color {
        paused ? palette.amber : palette.green
    }

    var body: some View {
        Text(title)
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

    let row: MenuBarPopoverModel.ShortcutRow

    var body: some View {
        HStack(spacing: 10) {
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

            ShortcutKeycapStrip(shortcut: row.shortcut, size: .small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(row.shortcut.isEnabled ? 1 : 0.6)
    }
}

private struct MenuBarToggleRow: View {
    @Environment(\.winkPalette) private var palette

    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(WinkType.bodyMedium)
                .foregroundStyle(palette.textPrimary)

            Spacer(minLength: 8)

            WinkSwitch(isOn: isOn, size: .small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct MenuBarActionRow: View {
    @Environment(\.winkPalette) private var palette

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
                    ShortcutKeycapStrip(labels: keycaps, size: .small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
