import SwiftUI

/// SwiftUI app entry for the menu bar utility.
///
/// Apple recommends declaring app settings through the `Settings` scene and
/// presenting them with `openSettings()` on macOS. Wink keeps the runtime in
/// AppKit-heavy services, but the settings shell now lives entirely in SwiftUI.
@main
struct WinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            let services = appDelegate.settingsSceneServices
            SettingsView(
                editor: services.editor,
                preferences: services.preferences,
                insightsViewModel: services.insightsViewModel,
                appListProvider: services.appListProvider,
                shortcutStatusProvider: services.shortcutStatusProvider,
                settingsLauncher: services.settingsLauncher
            )
            .frame(minWidth: 760, minHeight: 560)
            .winkChromeRoot()
        }
        .commands {
            SettingsCommands(settingsLauncher: appDelegate.settingsLauncher)
        }
    }
}

private struct SettingsCommands: Commands {
    @Environment(\.openSettings) private var openSettings
    let settingsLauncher: SettingsLauncher

    var body: some Commands {
        let _ = installOpenSettingsHandler()

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                settingsLauncher.open()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    @MainActor
    private func installOpenSettingsHandler() {
        settingsLauncher.installOpenSettingsHandler {
            openSettings()
        }
    }
}
