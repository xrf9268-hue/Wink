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

    /// chrome.jsx title overlay: `fontSize: 13; fontWeight: 500`.
    static let titleFontSize: CGFloat = 13
    /// CSS `font-weight: 500` ≈ AppKit/SwiftUI `.medium`.
    static let titleFontWeight: NSFont.Weight = .medium

    /// Chrome browser reference titlebar puts the sidebar toggle about 24pt to
    /// the trailing side of the zoom button, sharing the traffic-light baseline.
    /// AppKit owns the traffic-light positions; Wink only places its own toggle
    /// relative to the current system button frames.
    static let toggleGapFromZoomButton: CGFloat = 24

    /// SF Symbol `sidebar.leading` rendered at this point size matches the
    /// visual weight of the Chrome/Codex toggle icon at this scale.
    static let toggleIconPointSize: CGFloat = 14
    static let toggleHitSize = NSSize(width: 24, height: 24)
    static let sidebarToggleSymbolName = "rectangle.leadinghalf.inset.filled"
    static let sidebarToggleFallbackSymbolName = "sidebar.leading"

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
///   4. Add Wink's own sidebar toggle and title beside the system traffic
///      lights without rewriting the native button frames. AppKit remains the
///      owner of the standard close/minimize/zoom placement, and every
///      Wink-added control shares the traffic lights' vertical centerline
///      (`zoomButton.frame.midY`) — a single baseline, never a second one
///      derived from the design row height (PR #239 removed traffic-light
///      repositioning; a design-height centerline can no longer agree with
///      the AppKit-owned buttons).
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

private final class NotificationObserverBag {
    private var tokens: [NSObjectProtocol] = []

    func removeAll() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
    }

    func append(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        removeAll()
    }
}

@MainActor
final class SettingsWindowChromeCoordinator: NSObject {
    private weak var window: NSWindow?
    private weak var chromeHostView: NSView?
    private let observers = NotificationObserverBag()

    func attach(to window: NSWindow) {
        guard self.window !== window else {
            applyAll()
            return
        }
        observers.removeAll()

        self.window = window
        applyOnce()

        // AppKit (and SwiftUI's Settings scene) can re-assert titlebar state
        // on internal updates: a toolbar may be re-attached, the separator
        // style reset, or the chrome subviews re-laid out. `didUpdate` posts
        // on essentially every event-loop pass for a visible window, which is
        // acceptable only because `applyAll()` is idempotent-cheap: every
        // write below is guarded by an inequality check, so a steady-state
        // pass reduces to a handful of property reads with no layout work.
        // `didResize` is listed explicitly for clarity; key-state and expose
        // changes are already followed by window updates.
        let nc = NotificationCenter.default
        for name in [NSWindow.didUpdateNotification,
                     NSWindow.didResizeNotification] {
            let token = nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyAll() }
            }
            observers.append(token)
        }
    }

    private func applyOnce() {
        guard let window else { return }
        applyWindowChromeOptions(to: window)
        applyAll()
    }

    /// Every write is guarded so a no-drift pass performs reads only — this
    /// runs on every `didUpdate` notification.
    private func applyWindowChromeOptions(to window: NSWindow) {
        if window.title != "Wink" { window.title = "Wink" }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        // Inert while no toolbar is attached; kept so a transiently attached
        // toolbar lays out compactly before the removal below lands.
        if window.toolbarStyle != .unifiedCompact { window.toolbarStyle = .unifiedCompact }
        if window.toolbar != nil {
            window.toolbar = nil
        }
        // Keep the window non-movable from its content area so SwiftUI gestures
        // inside the detail pane (e.g. the Your Shortcuts grip drag) can
        // receive mouse-down events. The native 28pt titlebar plus the 8pt
        // titlebar accessory keep the full 36pt chrome row draggable.
        if window.isMovableByWindowBackground { window.isMovableByWindowBackground = false }
    }

    fileprivate func applyAll() {
        guard let window else { return }
        applyWindowChromeOptions(to: window)
        if installTitlebarAccessory(in: window) {
            window.layoutIfNeeded()
        }
        guard let titlebarView = titlebarHostView(in: window) else { return }
        installOrUpdateTitlebarChrome(in: titlebarView)
    }

    /// Returns `true` when the accessory was added or resized and a layout
    /// pass is needed before button frames can be read.
    @discardableResult
    private func installTitlebarAccessory(in window: NSWindow) -> Bool {
        if let accessory = window.titlebarAccessoryViewControllers.first(where: {
            $0.view.identifier == SettingsTitlebarLayout.accessoryIdentifier
        }) {
            var changed = false
            if accessory.layoutAttribute != .bottom {
                accessory.layoutAttribute = .bottom
                changed = true
            }
            if accessory.automaticallyAdjustsSize {
                accessory.automaticallyAdjustsSize = false
                changed = true
            }
            if accessory.view.frame.height != SettingsTitlebarLayout.titlebarAccessoryHeight {
                accessory.view.setFrameSize(NSSize(
                    width: accessory.view.frame.width,
                    height: SettingsTitlebarLayout.titlebarAccessoryHeight
                ))
                changed = true
            }
            return changed
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
        return true
    }

    private func titlebarHostView(in window: NSWindow) -> NSView? {
        window.standardWindowButton(.closeButton)?.superview
    }

    private func installOrUpdateTitlebarChrome(in titlebarView: NSView) {
        if chromeHostView !== titlebarView {
            if let chromeHostView {
                removeInstalledChrome(from: chromeHostView)
            }
            chromeHostView = titlebarView
        }

        let background = titlebarView.subviews.first {
            $0.identifier == SettingsTitlebarLayout.backgroundIdentifier
        } as? SettingsTitlebarPassthroughView ?? {
            let view = SettingsTitlebarPassthroughView(frame: titlebarView.bounds)
            view.identifier = SettingsTitlebarLayout.backgroundIdentifier
            view.autoresizingMask = [.width, .height]
            titlebarView.addSubview(view, positioned: .below, relativeTo: nil)
            return view
        }()
        if background.frame != titlebarView.bounds {
            background.frame = titlebarView.bounds
        }

        let hairline = titlebarView.subviews.first {
            $0.identifier == SettingsTitlebarLayout.hairlineIdentifier
        } as? SettingsTitlebarHairlineView ?? {
            let view = SettingsTitlebarHairlineView(frame: .zero)
            view.identifier = SettingsTitlebarLayout.hairlineIdentifier
            view.autoresizingMask = [.width, .maxYMargin]
            titlebarView.addSubview(view)
            return view
        }()
        let hairlineFrame = NSRect(
            x: 0,
            y: 0,
            width: titlebarView.bounds.width,
            height: SettingsTitlebarLayout.hairlineThickness
        )
        if hairline.frame != hairlineFrame {
            hairline.frame = hairlineFrame
        }

        let toggle = titlebarView.subviews.first {
            $0.identifier == SettingsTitlebarLayout.sidebarToggleIdentifier
        } as? NSButton ?? {
            let button = NSButton(frame: .zero)
            button.identifier = SettingsTitlebarLayout.sidebarToggleIdentifier
            button.image = Self.sidebarToggleImage()
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
        let toggleTint = SettingsTitlebarColors.textSecondary(for: titlebarView.effectiveAppearance)
        if toggle.contentTintColor != toggleTint {
            toggle.contentTintColor = toggleTint
        }
        if let toggleFrame = sidebarToggleFrame(in: titlebarView), toggle.frame != toggleFrame {
            toggle.frame = toggleFrame
        }

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
            label.font = .systemFont(
                ofSize: SettingsTitlebarLayout.titleFontSize,
                weight: SettingsTitlebarLayout.titleFontWeight
            )
            titlebarView.addSubview(label)
            return label
        }()
        let titleColor = SettingsTitlebarColors.textPrimary(for: titlebarView.effectiveAppearance)
        if title.textColor != titleColor {
            title.textColor = titleColor
        }
        let titleSize = title.intrinsicContentSize
        let titleFrame = NSRect(
            x: (titlebarView.bounds.width - titleSize.width) / 2,
            y: chromeBaselineCenterY(in: titlebarView) - titleSize.height / 2,
            width: titleSize.width,
            height: titleSize.height
        ).integral
        if title.frame != titleFrame {
            title.frame = titleFrame
        }
    }

    /// The single vertical centerline shared by every Wink-added titlebar
    /// control: the AppKit-owned traffic lights' midY. Deriving a second
    /// centerline from the design row height cannot agree with the buttons
    /// (native titlebar band is 28pt; the 36pt row adds an 8pt bottom
    /// accessory below it), so nothing else may define one.
    private func chromeBaselineCenterY(in titlebarView: NSView) -> CGFloat {
        window?.standardWindowButton(.zoomButton)?.frame.midY
            ?? titlebarView.bounds.midY
    }

    private func removeInstalledChrome(from hostView: NSView) {
        let identifiers = [
            SettingsTitlebarLayout.backgroundIdentifier,
            SettingsTitlebarLayout.hairlineIdentifier,
            SettingsTitlebarLayout.sidebarToggleIdentifier,
            SettingsTitlebarLayout.titleIdentifier,
        ]
        for subview in hostView.subviews where subview.identifier.map(identifiers.contains) == true {
            subview.removeFromSuperview()
        }
    }

    private static func sidebarToggleImage() -> NSImage? {
        NSImage(
            systemSymbolName: SettingsTitlebarLayout.sidebarToggleSymbolName,
            accessibilityDescription: "Toggle Sidebar"
        ) ?? NSImage(
            systemSymbolName: SettingsTitlebarLayout.sidebarToggleFallbackSymbolName,
            accessibilityDescription: "Toggle Sidebar"
        )
    }

    /// The toggle sits `toggleGapFromZoomButton` past the button cluster's
    /// trailing edge (in reading direction), on the shared baseline. A titled
    /// window always carries a zoom button alongside its close button, so
    /// `nil` (leave the current frame untouched) is a defensive fallback, not
    /// a reachable layout state.
    private func sidebarToggleFrame(in titlebarView: NSView) -> NSRect? {
        guard let window,
              let zoomButton = window.standardWindowButton(.zoomButton) else {
            return nil
        }
        let size = SettingsTitlebarLayout.toggleHitSize
        let x = window.windowTitlebarLayoutDirection == .rightToLeft
            ? zoomButton.frame.minX - SettingsTitlebarLayout.toggleGapFromZoomButton - size.width
            : zoomButton.frame.maxX + SettingsTitlebarLayout.toggleGapFromZoomButton
        return NSRect(
            x: x,
            y: chromeBaselineCenterY(in: titlebarView) - size.height / 2,
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
