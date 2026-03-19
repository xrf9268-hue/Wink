import SwiftUI

enum SettingsTab: String, CaseIterable {
    case shortcuts = "Shortcuts"
    case general = "General"
    case insights = "Insights"
}

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
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
                ShortcutsTabView(viewModel: viewModel)
            case .general:
                GeneralTabView(viewModel: viewModel)
            case .insights:
                InsightsTabView()
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
    }
}
