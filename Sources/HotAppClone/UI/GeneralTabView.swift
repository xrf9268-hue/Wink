import SwiftUI

struct GeneralTabView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Launch at Login", isOn: Binding(
                get: { viewModel.launchAtLoginEnabled },
                set: { viewModel.setLaunchAtLogin($0) }
            ))

            Spacer()

            HStack {
                Spacer()
                Text("Quickey v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }
}
