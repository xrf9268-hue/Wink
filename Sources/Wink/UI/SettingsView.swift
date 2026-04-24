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

    private var lifecycleHandler: SettingsViewLifecycleHandler {
        SettingsViewLifecycleHandler(preferences: preferences)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $settingsLauncher.selectedTab) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .font(WinkType.bodyMedium)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(
                min: SettingsSidebarMetrics.width,
                ideal: SettingsSidebarMetrics.width,
                max: SettingsSidebarMetrics.width
            )
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
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

private enum SettingsSidebarMetrics {
    static let width: CGFloat = 180
}
