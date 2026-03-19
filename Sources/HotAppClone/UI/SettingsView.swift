import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App Shortcuts")
                .font(.title2)
                .bold()

            HStack(spacing: 12) {
                Button("Choose App") {
                    viewModel.chooseApplication()
                }
                Text(viewModel.selectedAppName.isEmpty ? "No app selected" : viewModel.selectedAppName)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                TextField("Bundle Identifier", text: $viewModel.selectedBundleIdentifier)
                TextField("Key", text: $viewModel.keyEquivalent)
                    .frame(width: 80)
                TextField("Modifiers (comma separated)", text: $viewModel.modifierFlagsText)
            }

            Button("Add Shortcut") {
                viewModel.addShortcut()
            }
            .disabled(viewModel.selectedBundleIdentifier.isEmpty || viewModel.keyEquivalent.isEmpty)

            List {
                ForEach(viewModel.shortcuts) { shortcut in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(shortcut.appName)
                            Text(shortcut.bundleIdentifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(shortcut.modifierFlags.joined(separator: "+") + "+" + shortcut.keyEquivalent.uppercased())
                            .font(.system(.body, design: .monospaced))
                        Button(role: .destructive) {
                            viewModel.removeShortcut(id: shortcut.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
    }
}
