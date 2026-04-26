import AppKit
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
            .toolbar(removing: .title)
            .toolbar(removing: .sidebarToggle)
            .background(SettingsWindowChromeConfigurator())
            .winkChromeRoot()
        }
        .commands {
            SettingsCommands(settingsLauncher: appDelegate.settingsLauncher)
        }
    }
}

/// Layout constants taken verbatim from the Wink design source
/// `docs/design/reference/chrome.jsx` and `primitives.jsx`. Anything that
/// touches the titlebar/chrome region must use these — do not re-derive.
enum SettingsTitlebarLayout {
    /// chrome.jsx: outer flex row `height: 36`.
    static let height: CGFloat = 36

    /// primitives.jsx TrafficLights: `padding: 0 16px`.
    static let trafficLightContainerHorizontalPadding: CGFloat = 16
    /// primitives.jsx TrafficLights: each dot `width: 12; height: 12`.
    static let trafficLightDotSize: CGFloat = 12
    /// primitives.jsx TrafficLights: flex `gap: 8` between dots.
    static let trafficLightDotGap: CGFloat = 8

    /// chrome.jsx title overlay: `fontSize: 13; fontWeight: 500`.
    static let titleFontSize: CGFloat = 13
    /// CSS `font-weight: 500` ≈ AppKit/SwiftUI `.medium`.
    static let titleFontWeight: NSFont.Weight = .medium

    /// Chrome browser reference titlebar puts the sidebar toggle ~24pt right
    /// of the zoom button's right edge, sharing the traffic-light baseline.
    /// We treat that as the "natural" gap between the lights cluster and the
    /// next titlebar control.
    static let toggleGapFromTrafficLights: CGFloat = 8

    /// SF Symbol `sidebar.leading` rendered at this point size matches the
    /// visual weight of the Chrome/Codex toggle icon at this scale.
    static let toggleIconPointSize: CGFloat = 14
    static let toggleHitSize = NSSize(width: 24, height: 24)

    /// chrome.jsx `borderBottom: 0.5px solid chromeBorder`.
    static let hairlineThickness: CGFloat = 0.5

    /// On macOS 15's compact SwiftUI Settings titlebar, `contentLayoutRect`
    /// starts 28pt below the window top. A bottom titlebar accessory with this
    /// height grows the native titlebar area to the CSS row height of 36pt.
    static let titlebarAccessoryHeight: CGFloat = 8

    static let backgroundIdentifier = NSUserInterfaceItemIdentifier("WinkSettingsTitlebarBackground")
    static let hairlineIdentifier = NSUserInterfaceItemIdentifier("WinkSettingsTitlebarHairline")
    static let sidebarToggleIdentifier = NSUserInterfaceItemIdentifier("WinkSettingsTitlebarSidebarToggle")
    static let titleIdentifier = NSUserInterfaceItemIdentifier("WinkSettingsTitlebarTitle")
    static let accessoryIdentifier = NSUserInterfaceItemIdentifier("WinkSettingsTitlebarAccessory")

    /// Right edge of the traffic-light container (= where the toggle starts
    /// counting its leading gap from). 16 + 12 + 8 + 12 + 8 + 12 + 16 = 84.
    static var trafficLightContainerWidth: CGFloat {
        2 * trafficLightContainerHorizontalPadding
            + 3 * trafficLightDotSize
            + 2 * trafficLightDotGap
    }

    /// Window-coords top of each dot (CSS `align-items: center` in 36pt row
    /// with 12pt dot ⇒ top inset = (36 − 12) / 2 = 12).
    static var trafficLightDotTopY: CGFloat {
        (height - trafficLightDotSize) / 2
    }

    /// Vertical center y shared by traffic lights, toggle and title.
    static var baselineCenterY: CGFloat {
        height / 2
    }

    /// Window-coords leading x for each of the three dots, in order.
    static var trafficLightDotLeadingXs: [CGFloat] {
        let firstX = trafficLightContainerHorizontalPadding
        return (0..<3).map { i in
            firstX + CGFloat(i) * (trafficLightDotSize + trafficLightDotGap)
        }
    }

    /// Window-coords leading x for the sidebar toggle hit area.
    static var toggleLeadingX: CGFloat {
        trafficLightContainerWidth + toggleGapFromTrafficLights
    }

    /// Window-coords top y for the sidebar-toggle hit target.
    static var toggleTopY: CGFloat {
        baselineCenterY - toggleHitSize.height / 2
    }
}

/// Minimal NSWindow surgery for the SwiftUI `Settings` scene:
///   1. Hide the system-rendered title — `NSSplitViewItem` would otherwise
///      center it in the detail half of the titlebar rather than across the
///      whole window. AppKit draws the visible replacement title instead.
///   2. `titlebarAppearsTransparent = true` + `.fullSizeContentView` so the
///      custom titlebar background can draw underneath the system titlebar and
///      so clicks on custom controls in that area pass through
///      (per the AppKit SDK header: "the titlebar doesn't draw its
///      background, allowing all buttons to show through, and 'click through'
///      to happen").
///   3. Add an 8pt bottom `NSTitlebarAccessoryViewController` so the Settings
///      content starts below the design's 36pt chrome row instead of below the
///      native 28pt titlebar safe area.
///   4. Reposition the three native `standardWindowButton`s so their colored
///      dots land at the design coordinates from `chrome.jsx` /
///      `primitives.jsx` (close dot top-left = (16, 12) etc). This is *not*
///      a stylistic offset; it is the exact placement the design CSS
///      `align-items: center` produces inside a 36pt row.
private struct SettingsWindowChromeConfigurator: NSViewRepresentable {
    func makeCoordinator() -> SettingsWindowChromeCoordinator {
        SettingsWindowChromeCoordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        scheduleConfiguration(for: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scheduleConfiguration(for: nsView, coordinator: context.coordinator)
    }

    private func scheduleConfiguration(for view: NSView, coordinator: SettingsWindowChromeCoordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            coordinator.attach(to: window)
        }
    }
}

extension Notification.Name {
    static let settingsSidebarToggleRequested = Notification.Name("WinkSettingsSidebarToggleRequested")
}

@MainActor
final class SettingsWindowChromeCoordinator: NSObject {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func attach(to window: NSWindow) {
        guard self.window !== window else {
            applyAll()
            return
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        self.window = window
        applyOnce()

        // AppKit re-asserts titlebar layout on internal updates (key state,
        // content attachment, titlebar accessory changes, resize). Re-apply so
        // the CSS-derived coordinates stay pinned.
        let nc = NotificationCenter.default
        for name in [NSWindow.didUpdateNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification,
                     NSWindow.didExposeNotification,
                     NSWindow.didResizeNotification] {
            let token = nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyAll() }
            }
            observers.append(token)
        }
    }

    private func applyOnce() {
        guard let window else { return }
        window.title = "Wink"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unifiedCompact
        window.toolbar = nil
        window.isMovableByWindowBackground = true
        applyAll()
    }

    fileprivate func applyAll() {
        guard let window else { return }
        installTitlebarAccessory(in: window)
        window.layoutIfNeeded()
        guard let titlebarView = positionTrafficLights(in: window) else { return }
        installOrUpdateTitlebarChrome(in: titlebarView)
    }

    private func installTitlebarAccessory(in window: NSWindow) {
        if let accessory = window.titlebarAccessoryViewControllers.first(where: {
            $0.view.identifier == SettingsTitlebarLayout.accessoryIdentifier
        }) {
            accessory.layoutAttribute = .bottom
            accessory.automaticallyAdjustsSize = false
            accessory.view.setFrameSize(NSSize(
                width: accessory.view.frame.width,
                height: SettingsTitlebarLayout.titlebarAccessoryHeight
            ))
            return
        }

        let accessoryView = SettingsTitlebarPassthroughView(frame: NSRect(
            x: 0,
            y: 0,
            width: 0,
            height: SettingsTitlebarLayout.titlebarAccessoryHeight
        ))
        accessoryView.identifier = SettingsTitlebarLayout.accessoryIdentifier

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        accessory.automaticallyAdjustsSize = false
        accessory.fullScreenMinHeight = SettingsTitlebarLayout.titlebarAccessoryHeight
        accessory.view = accessoryView
        window.addTitlebarAccessoryViewController(accessory)
    }

    @discardableResult
    private func positionTrafficLights(in window: NSWindow) -> NSView? {
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = buttonTypes.compactMap { window.standardWindowButton($0) }
        guard let titlebarView = buttons.first?.superview else { return nil }

        // Release constraints anchoring the standard buttons. Without this,
        // `setFrameOrigin` is overwritten on the next layout pass.
        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = true
        }
        var node: NSView? = titlebarView
        while let view = node {
            let related = view.constraints.filter { constraint in
                buttons.contains {
                    ((constraint.firstItem as AnyObject?) === $0)
                        || ((constraint.secondItem as AnyObject?) === $0)
                }
            }
            NSLayoutConstraint.deactivate(related)
            node = view.superview
        }

        let dotTopY = SettingsTitlebarLayout.trafficLightDotTopY      // 12
        let dotSize = SettingsTitlebarLayout.trafficLightDotSize      // 12
        let dotXs = SettingsTitlebarLayout.trafficLightDotLeadingXs   // [16, 36, 56]

        for (button, dotX) in zip(buttons, dotXs) {
            let buttonSize = button.frame.size
            let buttonTopY = dotTopY - (buttonSize.height - dotSize) / 2
            let buttonLeadingX = dotX - (buttonSize.width - dotSize) / 2
            let yFromBottom = titlebarView.bounds.height - buttonTopY - buttonSize.height
            button.setFrameOrigin(NSPoint(x: buttonLeadingX, y: yFromBottom))
        }

        return titlebarView
    }

    private func installOrUpdateTitlebarChrome(in titlebarView: NSView) {
        let background = titlebarView.subviews.first {
            $0.identifier == SettingsTitlebarLayout.backgroundIdentifier
        } as? SettingsTitlebarPassthroughView ?? {
            let view = SettingsTitlebarPassthroughView(frame: titlebarView.bounds)
            view.identifier = SettingsTitlebarLayout.backgroundIdentifier
            titlebarView.addSubview(view, positioned: .below, relativeTo: nil)
            return view
        }()
        background.frame = titlebarView.bounds
        background.autoresizingMask = [.width, .height]
        background.updateBackgroundColor()

        let hairline = titlebarView.subviews.first {
            $0.identifier == SettingsTitlebarLayout.hairlineIdentifier
        } as? SettingsTitlebarHairlineView ?? {
            let view = SettingsTitlebarHairlineView(frame: .zero)
            view.identifier = SettingsTitlebarLayout.hairlineIdentifier
            titlebarView.addSubview(view)
            return view
        }()
        hairline.frame = NSRect(
            x: 0,
            y: 0,
            width: titlebarView.bounds.width,
            height: SettingsTitlebarLayout.hairlineThickness
        )
        hairline.autoresizingMask = [.width, .maxYMargin]
        hairline.updateBackgroundColor()

        let toggle = titlebarView.subviews.first {
            $0.identifier == SettingsTitlebarLayout.sidebarToggleIdentifier
        } as? NSButton ?? {
            let button = NSButton(frame: .zero)
            button.identifier = SettingsTitlebarLayout.sidebarToggleIdentifier
            button.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle Sidebar")
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.setButtonType(.momentaryChange)
            button.toolTip = "Toggle Sidebar"
            button.target = self
            button.action = #selector(toggleSidebar(_:))
            titlebarView.addSubview(button)
            return button
        }()
        toggle.target = self
        toggle.action = #selector(toggleSidebar(_:))
        toggle.contentTintColor = SettingsTitlebarColors.textSecondary(for: titlebarView.effectiveAppearance)
        toggle.frame = frameFromTopLeft(
            x: SettingsTitlebarLayout.toggleLeadingX,
            y: SettingsTitlebarLayout.toggleTopY,
            size: SettingsTitlebarLayout.toggleHitSize,
            in: titlebarView
        )

        let title = titlebarView.subviews.first {
            $0.identifier == SettingsTitlebarLayout.titleIdentifier
        } as? NSTextField ?? {
            let label = NSTextField(labelWithString: "Wink")
            label.identifier = SettingsTitlebarLayout.titleIdentifier
            label.alignment = .center
            label.isBezeled = false
            label.isBordered = false
            label.drawsBackground = false
            label.isEditable = false
            label.isSelectable = false
            label.allowsDefaultTighteningForTruncation = false
            label.lineBreakMode = .byClipping
            titlebarView.addSubview(label)
            return label
        }()
        title.stringValue = "Wink"
        title.font = .systemFont(
            ofSize: SettingsTitlebarLayout.titleFontSize,
            weight: SettingsTitlebarLayout.titleFontWeight
        )
        title.textColor = SettingsTitlebarColors.textPrimary(for: titlebarView.effectiveAppearance)
        title.sizeToFit()
        let titleSize = title.intrinsicContentSize
        title.frame = NSRect(
            x: (titlebarView.bounds.width - titleSize.width) / 2,
            y: titlebarView.bounds.height - SettingsTitlebarLayout.baselineCenterY - titleSize.height / 2,
            width: titleSize.width,
            height: titleSize.height
        ).integral
    }

    private func frameFromTopLeft(x: CGFloat, y: CGFloat, size: NSSize, in container: NSView) -> NSRect {
        NSRect(
            x: x,
            y: container.bounds.height - y - size.height,
            width: size.width,
            height: size.height
        )
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        NotificationCenter.default.post(name: .settingsSidebarToggleRequested, object: window)
    }
}

private class SettingsTitlebarPassthroughView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateBackgroundColor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        updateBackgroundColor()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    func updateBackgroundColor() {
        layer?.backgroundColor = SettingsTitlebarColors.chromeBackground(for: effectiveAppearance).cgColor
    }
}

private final class SettingsTitlebarHairlineView: SettingsTitlebarPassthroughView {
    override func updateBackgroundColor() {
        layer?.backgroundColor = SettingsTitlebarColors.hairline(for: effectiveAppearance).cgColor
    }
}

private enum SettingsTitlebarColors {
    static func chromeBackground(for appearance: NSAppearance) -> NSColor {
        isDark(appearance)
            ? NSColor(srgbRed: 0x2C, green: 0x2C, blue: 0x2E)
            : NSColor(srgbRed: 0xEC, green: 0xEC, blue: 0xEC)
    }

    static func hairline(for appearance: NSAppearance) -> NSColor {
        isDark(appearance)
            ? NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.08)
            : NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.08)
    }

    static func textPrimary(for appearance: NSAppearance) -> NSColor {
        isDark(appearance)
            ? NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.92)
            : NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.88)
    }

    static func textSecondary(for appearance: NSAppearance) -> NSColor {
        isDark(appearance)
            ? NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.55)
            : NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.55)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

private extension NSColor {
    convenience init(srgbRed red: Int, green: Int, blue: Int, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: alpha
        )
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
