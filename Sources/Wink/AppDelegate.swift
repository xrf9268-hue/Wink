import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appController: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI's `Settings` scene defaults the app to `.regular` activation,
        // which would surface a Dock icon and About menu we don't want for a
        // menu bar utility. `LSUIElement=true` covers initial launch, but the
        // Settings scene re-elevates after activation; pin .accessory here so
        // the app stays a menu bar resident across show/hide cycles.
        NSApp.setActivationPolicy(.accessory)

        appController = AppController()
        appController?.start()
    }

    func openPrimarySettingsWindow() {
        appController?.openPrimarySettingsWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appController?.stop()
    }
}
