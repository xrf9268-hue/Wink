import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appController = AppController()

    var settingsSceneServices: AppController.SettingsSceneServices {
        appController.settingsSceneServices
    }

    var settingsLauncher: SettingsLauncher {
        appController.settingsLauncherService
    }

    var menuBarSceneServices: AppController.MenuBarSceneServices {
        appController.menuBarSceneServices
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI's `Settings` scene defaults the app to `.regular` activation,
        // which would surface a Dock icon and About menu we don't want for a
        // menu bar utility. `LSUIElement=true` covers initial launch, but the
        // Settings scene re-elevates after activation; pin .accessory here so
        // the app stays a menu bar resident across show/hide cycles.
        NSApp.setActivationPolicy(.accessory)

        appController.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else {
            return true
        }

        // Keep a recovery path into Settings when the menu bar icon is hidden
        // or no Settings window is currently visible.
        appController.openPrimarySettingsWindow()
        return true
    }

    func openPrimarySettingsWindow() {
        appController.openPrimarySettingsWindow()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        appController.handleURLs(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        appController.stop()
    }
}
