import AppKit
import SwiftUI

/// Collapses bursts of reactivation notifications into at most one usage
/// refresh per window. Held as view `@State` so the window survives across
/// body evaluations; only dispatched refreshes consume the window, so a
/// suppressed tab (General) never blocks a later real refresh.
@MainActor
final class SettingsUsageRefreshCoalescer {
    static let minimumInterval: TimeInterval = 1.0

    private let now: @Sendable () -> Date
    private var lastRefreshAt: Date?

    nonisolated init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func shouldRefresh() -> Bool {
        let timestamp = now()
        if let lastRefreshAt, timestamp.timeIntervalSince(lastRefreshAt) < Self.minimumInterval {
            return false
        }

        lastRefreshAt = timestamp
        return true
    }
}

@MainActor
struct SettingsViewLifecycleHandler {
    let preferences: AppPreferences
    var usageRefreshCoalescer: SettingsUsageRefreshCoalescer
    var selectedTab: () -> SettingsTab
    var refreshInsightsUsage: () -> Void
    var refreshShortcutsUsage: () -> Void

    init(
        preferences: AppPreferences,
        usageRefreshCoalescer: SettingsUsageRefreshCoalescer = SettingsUsageRefreshCoalescer(),
        selectedTab: @escaping () -> SettingsTab = { .shortcuts },
        refreshInsightsUsage: @escaping () -> Void = {},
        refreshShortcutsUsage: @escaping () -> Void = {}
    ) {
        self.preferences = preferences
        self.usageRefreshCoalescer = usageRefreshCoalescer
        self.selectedTab = selectedTab
        self.refreshInsightsUsage = refreshInsightsUsage
        self.refreshShortcutsUsage = refreshShortcutsUsage
    }

    func handleAppear() {
        preferences.refreshPermissions()
        preferences.refreshLaunchAtLoginStatus()
    }

    func handleAppDidBecomeActive() {
        preferences.refreshPermissions()
        preferences.refreshLaunchAtLoginStatus()
        refreshUsageForSelectedTab()
    }

    /// Reactivation refreshes only the visible tab's usage model; the hidden
    /// tab gets its own fresh query when it is selected (issue #326).
    private func refreshUsageForSelectedTab() {
        switch selectedTab() {
        case .insights:
            guard usageRefreshCoalescer.shouldRefresh() else { return }
            refreshInsightsUsage()
        case .shortcuts:
            guard usageRefreshCoalescer.shouldRefresh() else { return }
            refreshShortcutsUsage()
        case .general:
            break
        }
    }
}

struct SettingsView: View {
    @Environment(\.winkPalette) private var palette

    @Bindable var editor: ShortcutEditorState
    var preferences: AppPreferences
    var insightsViewModel: InsightsViewModel
    var appListProvider: AppListProvider
    var shortcutStatusProvider: ShortcutStatusProvider
    @Bindable var settingsLauncher: SettingsLauncher

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var usageRefreshCoalescer = SettingsUsageRefreshCoalescer()

    private var lifecycleHandler: SettingsViewLifecycleHandler {
        SettingsViewLifecycleHandler(
            preferences: preferences,
            usageRefreshCoalescer: usageRefreshCoalescer,
            selectedTab: { settingsLauncher.selectedTab },
            refreshInsightsUsage: { insightsViewModel.scheduleRefresh() },
            refreshShortcutsUsage: { editor.scheduleUsageRefresh() }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $settingsLauncher.selectedTab) {
                Color.clear
                    .frame(height: SettingsSidebarMetrics.topContentPadding)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(palette.sidebarBg)
                    .accessibilityHidden(true)

                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .font(WinkType.sidebarRow)
                        .padding(.leading, SettingsSidebarMetrics.rowContentLeadingAdjustment)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .navigationSplitViewColumnWidth(
                min: SettingsSidebarMetrics.width,
                ideal: SettingsSidebarMetrics.width,
                max: SettingsSidebarMetrics.width
            )
            .background(palette.sidebarBg)
        } detail: {
            GeometryReader { proxy in
                selectedTabView
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height,
                        alignment: .topLeading
                    )
                    .background(palette.windowBg)
            }
            .background(palette.windowBg)
        }
        .navigationSplitViewStyle(.balanced)
        .background(palette.windowBg)
        .onReceive(NotificationCenter.default.publisher(for: .settingsSidebarToggleRequested)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                toggleSidebar()
            }
        }
        .onChange(of: settingsLauncher.selectedTab) { _, newTab in
            switch newTab {
            case .insights:
                insightsViewModel.scheduleRefresh()
            case .shortcuts:
                editor.scheduleUsageRefresh()
            case .general:
                break
            }
        }
        .onAppear {
            lifecycleHandler.handleAppear()
            if settingsLauncher.selectedTab == .insights {
                insightsViewModel.scheduleRefresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            lifecycleHandler.handleAppDidBecomeActive()
        }
    }

    private func toggleSidebar() {
        columnVisibility = columnVisibility == .all ? .detailOnly : .all
    }

    @ViewBuilder
    private var selectedTabView: some View {
        switch settingsLauncher.selectedTab {
        case .shortcuts:
            ShortcutsTabView(
                editor: editor,
                preferences: preferences,
                appListProvider: appListProvider,
                shortcutStatusProvider: shortcutStatusProvider
            )
        case .insights:
            InsightsTabView(viewModel: insightsViewModel)
        case .general:
            GeneralTabView(preferences: preferences, editor: editor)
        }
    }
}

enum SettingsSidebarMetrics {
    /// chrome.jsx Sidebar: `width: 180`. PR #239 silently narrowed this to
    /// 150 while fixing an unrelated scrolling issue, with no documented
    /// rationale — restored to match the design (Issue #304).
    static let width: CGFloat = 180
    static let topContentPadding: CGFloat = 8
    static let rowContentLeadingAdjustment: CGFloat = -2
}
