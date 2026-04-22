import SwiftUI

/// SwiftUI App scene entry point.
///
/// Wink is a macOS menu bar utility (`LSUIElement=true`); the AppKit-style
/// `NSApplication.shared.run()` boot has been replaced with the modern
/// SwiftUI `App` protocol per Apple's macOS 14+ guidance. `AppDelegate`
/// continues to host service wiring through `@NSApplicationDelegateAdaptor`,
/// so all existing Carbon / SkyLight / TCC paths remain untouched.
///
/// Phase 1 ships the `Settings` Scene as a placeholder. Phase 2 wires the
/// real `SettingsView`; Phase 3 adds the `MenuBarExtra` popover Scene.
@main
struct WinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            // Phase 2 replaces this with the real SettingsView.
            SettingsPlaceholderView()
                .frame(minWidth: 480, minHeight: 320)
                .winkPaletteFromColorScheme()
        }
    }
}

/// Temporary settings content for Phase 1. Confirms the Settings scene
/// is reachable via `openSettings()` and the design system loads cleanly.
private struct SettingsPlaceholderView: View {
    @Environment(\.winkPalette) private var palette

    var body: some View {
        VStack(spacing: 16) {
            WinkAppIcon(size: 56)
            WinkWordmark(size: 22, color: palette.textPrimary)
            Text("Phase 2 will replace this placeholder with the real settings UI.")
                .font(WinkType.bodyText)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.windowBg)
    }
}
