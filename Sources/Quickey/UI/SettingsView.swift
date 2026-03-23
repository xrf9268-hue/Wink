import SwiftUI

enum SettingsTab: String, CaseIterable {
    case shortcuts = "Shortcuts"
    case general = "General"
    case insights = "Insights"
}

struct SettingsView: View {
    var editor: ShortcutEditorState
    var preferences: AppPreferences
    var insightsViewModel: InsightsViewModel
    var appListProvider: AppListProvider
    @State private var selectedTab: SettingsTab = .shortcuts

    var body: some View {
        VStack(spacing: 16) {
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case .shortcuts:
                ShortcutsTabView(editor: editor, preferences: preferences, appListProvider: appListProvider)
            case .general:
                GeneralTabView(preferences: preferences, editor: editor)
            case .insights:
                InsightsTabView(viewModel: insightsViewModel)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .insights {
                insightsViewModel.scheduleRefresh()
            }
        }
        .onAppear {
            preferences.refreshPermissions()
        }
    }
}
