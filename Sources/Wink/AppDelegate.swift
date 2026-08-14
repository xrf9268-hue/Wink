import AppKit
import WinkIntents

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appController = AppController()

    override init() {
        super.init()
        WinkAppIntentDependency.register(appController.appIntentClient)
    }

    var settingsSceneServices: AppController.SettingsSceneServices {
        appController.settingsSceneServices
    }

    var settingsLauncher: SettingsLauncher {
        appController.settingsLauncherService
    }

    var menuBarSceneServices: AppController.MenuBarSceneServices {
        appController.menuBarSceneServices
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // NSApplication's URL delegate callback receives Foundation-normalized
        // URLs, which irreversibly folds some Unicode host spellings into ASCII
        // allowlisted commands. Own the Get URL Apple Event instead so the
        // parser sees the exact delivered string from its direct object.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
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

    func applicationWillTerminate(_ notification: Notification) {
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        appController.stop()
    }

    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        appController.handleURLStrings(Self.rawURLStrings(from: event))
    }

    static func rawURLStrings(from event: NSAppleEventDescriptor) -> [String] {
        guard let directObject = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            return []
        }
        guard directObject.descriptorType == DescType(typeAEList) else {
            return directObject.stringValue.map { [$0] } ?? []
        }
        guard directObject.numberOfItems > 0 else {
            return []
        }
        return (1 ... directObject.numberOfItems).compactMap {
            directObject.atIndex($0)?.stringValue
        }
    }
}
