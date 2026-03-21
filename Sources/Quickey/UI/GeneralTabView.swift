import SwiftUI

struct GeneralTabView: View {
    var preferences: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Launch at Login", isOn: Binding(
                get: { preferences.launchAtLoginEnabled },
                set: { preferences.setLaunchAtLogin($0) }
            ))

            switch preferences.launchAtLoginStatus {
            case .requiresApproval:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Enabled in Quickey, but still needs approval in System Settings > General > Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items Settings") {
                        preferences.openLoginItemsSettings()
                    }
                }
            case .notFound:
                Text("Quickey could not find the packaged login item. Rebuild or reinstall the app bundle and try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .enabled, .disabled:
                EmptyView()
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Enable Hyper Key (Caps Lock → ⌃⌥⇧⌘)", isOn: Binding(
                    get: { preferences.hyperKeyEnabled },
                    set: { preferences.setHyperKeyEnabled($0) }
                ))
                Text("将 Caps Lock 映射为 Hyper Key。按住 Caps Lock 再按其他键，等同于 ⌃⌥⇧⌘ 组合。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
