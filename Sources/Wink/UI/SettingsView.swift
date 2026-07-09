import AppKit
import SwiftUI

@MainActor
struct SettingsViewLifecycleHandler {
    let preferences: AppPreferences

    func handleAppear() {
        preferences.refreshPermissions()
        preferences.refreshLaunchAtLoginStatus()
    }

    func handleAppDidBecomeActive() {
        preferences.refreshPermissions()
        preferences.refreshLaunchAtLoginStatus()
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

    private var lifecycleHandler: SettingsViewLifecycleHandler {
        SettingsViewLifecycleHandler(preferences: preferences)
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
            if newTab == .insights {
                insightsViewModel.scheduleRefresh()
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
