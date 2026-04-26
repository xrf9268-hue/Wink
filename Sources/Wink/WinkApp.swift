import SwiftUI

enum SettingsWindowMetrics {
    static let width: CGFloat = 860
    static let height: CGFloat = 780
}

/// SwiftUI app entry for the menu bar utility.
///
/// Apple recommends declaring app settings through the `Settings` scene and
/// presenting them with `openSettings()` on macOS. Wink keeps the runtime in
/// AppKit-heavy services, but the settings shell now lives entirely in SwiftUI.
@main
struct WinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppPreferences.menuBarIconVisibleDefaultsKey)
    private var menuBarIconVisible = true

    var body: some Scene {
        let menuBarServices = appDelegate.menuBarSceneServices
        WinkMenuBarScene(isInserted: $menuBarIconVisible) {
            MenuBarPopoverView(
                model: MenuBarPopoverModel(
                    shortcutStore: menuBarServices.shortcutStore,
                    preferences: menuBarServices.preferences,
                    shortcutStatusProvider: menuBarServices.shortcutStatusProvider,
                    usageTracker: menuBarServices.usageTracker,
                    openSettings: menuBarServices.openSettings,
                    quit: menuBarServices.quit
                )
            )
            .frame(width: 356, height: 680)
            .winkChromeRoot()
        }

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
            .frame(
                width: SettingsWindowMetrics.width,
                height: SettingsWindowMetrics.height
            )
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
