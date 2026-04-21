import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case shortcuts = "Shortcuts"
    case general = "General"
    case insights = "Insights"
}

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
    var editor: ShortcutEditorState
    var preferences: AppPreferences
    var insightsViewModel: InsightsViewModel
    var appListProvider: AppListProvider
    var shortcutStatusProvider: ShortcutStatusProvider
    @State private var selectedTab: SettingsTab = .shortcuts

    private var lifecycleHandler: SettingsViewLifecycleHandler {
        SettingsViewLifecycleHandler(preferences: preferences)
    }

    var body: some View {
        VStack(spacing: 16) {
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch selectedTab {
                case .shortcuts:
                    ShortcutsTabView(
                        editor: editor,
                        preferences: preferences,
                        appListProvider: appListProvider,
                        shortcutStatusProvider: shortcutStatusProvider
                    )
                case .general:
                    GeneralTabView(preferences: preferences, editor: editor)
                case .insights:
                    InsightsTabView(viewModel: insightsViewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .insights {
                insightsViewModel.scheduleRefresh()
            }
        }
        .onAppear {
            lifecycleHandler.handleAppear()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            lifecycleHandler.handleAppDidBecomeActive()
        }
    }
}
