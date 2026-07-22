import AppKit
import Foundation
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

    /// primitives.jsx TrafficLights: `padding: 0 16px`. AppKit's native
    /// button inset (~13pt center) is a fixed system value that isn't this
    /// value — now that Wink owns the traffic-light buttons (see
    /// `installOwnedTrafficLights`), their x position is driven by this
    /// design constant instead of wherever AppKit happened to place the
    /// originals.
    static let trafficLightLeadingPadding: CGFloat = 16
    /// primitives.jsx TrafficLights: each dot `width: 12; height: 12`.
    static let trafficLightDotSize: CGFloat = 12
    /// primitives.jsx TrafficLights: flex `gap: 8` between dots.
    static let trafficLightDotGap: CGFloat = 8

    /// chrome.jsx title overlay: `fontSize: 13; fontWeight: 500`.
    static let titleFontSize: CGFloat = 13
    /// CSS `font-weight: 500` ≈ AppKit/SwiftUI `.medium`.
    static let titleFontWeight: NSFont.Weight = .medium

    /// Chrome browser reference titlebar puts the sidebar toggle about 24pt to
    /// the trailing side of the zoom button, sharing the traffic-light baseline.
    /// Wink owns the traffic-light buttons (see `installOwnedTrafficLights`) and
    /// places its toggle relative to the owned zoom button's frame.
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

    static func trafficLightIdentifier(for type: NSWindow.ButtonType) -> NSUserInterfaceItemIdentifier {
        switch type {
        case .closeButton: return NSUserInterfaceItemIdentifier("WinkSettingsTitlebarCloseLight")
        case .miniaturizeButton: return NSUserInterfaceItemIdentifier("WinkSettingsTitlebarMiniaturizeLight")
        case .zoomButton: return NSUserInterfaceItemIdentifier("WinkSettingsTitlebarZoomLight")
        default: return NSUserInterfaceItemIdentifier("WinkSettingsTitlebarLight")
        }
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
///   4. Hide the three AppKit-placed traffic-light buttons and replace them
///      with fresh instances from `NSWindow.standardWindowButton(_:for:)`
///      (Apple's factory API for "a new instance of a given standard window
///      button, sized appropriately for a given window style" — the caller
///      owns placement). The originals stay alive (just hidden) so
///      `performClose`/`performMiniaturize`/`performZoom`, the Mission
///      Control "unsaved changes" dot, and full-screen widget still track
///      real window state; Wink mirrors their `isEnabled` onto the owned
///      buttons every pass. This avoids PR #237's mistake of repositioning
///      the *live* AppKit-owned buttons via `setFrameOrigin`, which fights
///      `NSTitlebarView`'s own autolayout on every relayout pass and made the
///      buttons visibly jump (PR #239 reverted it) — a factory-created
///      button isn't in that autolayout at all, so there's nothing to fight.
///   5. Add Wink's own sidebar toggle and title beside the owned traffic
///      lights. Because Wink now owns every control in the row, all four
///      (lights, toggle, title) share one true centerline: the design row's
///      own midpoint (36pt / 2 = 18pt from the top), not AppKit's native
///      28pt-band center.
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

    /// Owned replacements for the AppKit close/miniaturize/zoom buttons,
    /// keyed by button type. Created once per window; positioned on the
    /// design centerline instead of AppKit's native-band center.
    private var ownedTrafficLights: [NSWindow.ButtonType: NSButton] = [:]
    /// The AppKit-native frame of each traffic-light button, captured once
    /// (before it's hidden) so the owned replacement can reuse the native
    /// x/width/height and only override y. Captured once because a hidden
    /// button's frame may no longer reflect AppKit's normal layout.
    private var trafficLightNativeFrames: [NSWindow.ButtonType: NSRect] = [:]
    /// Stable reference to each *true* AppKit-owned button, captured once
    /// before any owned clone exists. `window.standardWindowButton(_:)`
    /// does a live, type-based search of the titlebar's subviews — once a
    /// factory-vended clone of the same private button class is also in
    /// that hierarchy, the search can return the clone instead of the
    /// original (confirmed empirically: `isHidden` toggles landed on the
    /// clone, hiding it, because the "original" that later passes looked up
    /// was actually the clone). Re-querying by type after clones exist is
    /// unreliable, so every subsequent pass must use these cached instances.
    private var originalTrafficLights: [NSWindow.ButtonType: NSButton] = [:]

    func attach(to window: NSWindow) {
        guard self.window !== window else {
            applyAll()
            return
        }
        observers.removeAll()
        ownedTrafficLights.removeAll()
        trafficLightNativeFrames.removeAll()
        originalTrafficLights.removeAll()

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
        installOwnedTrafficLights(in: window, titlebarView: titlebarView)
        installOrUpdateTitlebarChrome(in: titlebarView)
        // NSTitlebarView's own layout can re-show its canonical buttons as a
        // side effect of *any* pass that adds/resizes sibling subviews (seen
        // empirically: hiding them earlier in this same method didn't stick
        // once installOrUpdateTitlebarChrome touched the hairline/toggle/
        // title subviews below). Re-assert hidden last, after every other
        // subview mutation in this pass, so we always get the final word.
        reassertTrafficLightsHidden()
    }

    private func reassertTrafficLightsHidden() {
        for (type, original) in originalTrafficLights {
            guard ownedTrafficLights[type] != nil, !original.isHidden else { continue }
            original.isHidden = true
        }
    }

    /// Hides the AppKit-placed close/miniaturize/zoom buttons and maintains
    /// fresh replacements from `NSWindow.standardWindowButton(_:for:)` on the
    /// design centerline. See the type-level doc comment (step 4) for why
    /// this is safer than repositioning the live buttons.
    private func installOwnedTrafficLights(in window: NSWindow, titlebarView: NSView) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        // AppKit can rebuild NSTitlebarView itself (observed after the
        // window becomes key) without replacing the NSWindow — the same
        // condition installOrUpdateTitlebarChrome below detects for its own
        // subviews. A cache keyed only by button type doesn't notice its
        // views went stale on the old host, so it would silently keep
        // returning orphaned, invisible clones forever. Check the same
        // condition here (before installOrUpdateTitlebarChrome updates
        // chromeHostView for this pass) and drop the cache so fresh clones
        // get created on the new host.
        if chromeHostView !== titlebarView {
            ownedTrafficLights.removeAll()
            trafficLightNativeFrames.removeAll()
            originalTrafficLights.removeAll()
        }

        // Capture the native frame *and a stable reference to the true
        // AppKit button* once, before any clone exists. This must happen
        // before hiding/cloning below: `window.standardWindowButton(_:)`
        // does a live, type-based search of the titlebar's subviews, and
        // once a factory-vended clone of the same private button class is
        // also present, that search can return the clone instead of the
        // original — confirmed empirically (a later pass's "original" was
        // actually the clone, so this code hid the clone it had just made
        // visible). Every subsequent read must go through
        // `originalTrafficLights`, never back through
        // `window.standardWindowButton(_:)`.
        if trafficLightNativeFrames.isEmpty {
            for type in types {
                guard let original = window.standardWindowButton(type), !original.isHidden else { continue }
                trafficLightNativeFrames[type] = original.frame
                originalTrafficLights[type] = original
            }
        }

        let centerY = chromeBaselineCenterY(in: titlebarView)

        for (index, type) in types.enumerated() {
            guard let original = originalTrafficLights[type] else { continue }
            if !original.isHidden { original.isHidden = true }

            guard let nativeFrame = trafficLightNativeFrames[type] else { continue }

            let owned = ownedTrafficLights[type] ?? {
                let button = NSWindow.standardWindowButton(type, for: window.styleMask)
                button?.identifier = SettingsTitlebarLayout.trafficLightIdentifier(for: type)
                // A button vended by this factory isn't the window's
                // *registered* close/miniaturize/zoom button, so its own
                // NSButtonCell mouse-tracking doesn't reliably send
                // target/action on a live mouse click — confirmed both by
                // manual testing (clicks landed but performClose/performZoom
                // never fired) and by Apple Developer Forums precedent on
                // this exact API ("may be difficult to impossible to hack
                // those buttons... the window is doing something"). A click
                // gesture recognizer uses a separate, independent event path
                // that doesn't depend on that internal mouse-tracking, so
                // it's the reliable way to dispatch a live click.
                //
                // VoiceOver and Full Keyboard Access don't go through mouse
                // tracking OR gesture recognizers at all — they invoke
                // NSControl.performClick(_:) (directly, or via the default
                // accessibilityPerformPress() implementation), which sends
                // the action straight to target/action without the broken
                // tracking loop in between. So target/action still needs to
                // be set on the button itself for those paths to work, even
                // though it's not the reliable path for a live mouse click.
                button?.target = window
                button?.action = Self.trafficLightAction(for: type)
                if let button {
                    titlebarView.addSubview(button)
                    button.addGestureRecognizer(
                        NSClickGestureRecognizer(target: self, action: #selector(ownedTrafficLightClicked(_:)))
                    )
                }
                return button
            }()
            guard let owned else { continue }
            ownedTrafficLights[type] = owned

            if owned.isEnabled != original.isEnabled {
                owned.isEnabled = original.isEnabled
            }

            // x comes from the design's own 16px-padding/12px-dot/8px-gap
            // spec, not nativeFrame.minX (AppKit's native ~13pt inset) —
            // measured on the packaged app, that native inset put the
            // cluster ~8.5pt left of what chrome.jsx/primitives.jsx specify,
            // and mainwindow.jsx composes the traffic lights and the
            // sidebar's icon column on the same x-axis, so the gap between
            // them is part of the design, not free for AppKit to decide.
            let designCenterX = SettingsTitlebarLayout.trafficLightLeadingPadding
                + SettingsTitlebarLayout.trafficLightDotSize / 2
                + CGFloat(index) * (SettingsTitlebarLayout.trafficLightDotSize + SettingsTitlebarLayout.trafficLightDotGap)
            let ownedFrame = NSRect(
                x: designCenterX - nativeFrame.width / 2,
                y: centerY - nativeFrame.height / 2,
                width: nativeFrame.width,
                height: nativeFrame.height
            )
            if owned.frame != ownedFrame {
                owned.frame = ownedFrame
            }
        }
    }

    @objc private func ownedTrafficLightClicked(_ recognizer: NSClickGestureRecognizer) {
        guard let button = recognizer.view as? NSButton, button.isEnabled, let window else { return }
        switch button.identifier {
        case SettingsTitlebarLayout.trafficLightIdentifier(for: .closeButton):
            window.performClose(nil)
        case SettingsTitlebarLayout.trafficLightIdentifier(for: .miniaturizeButton):
            window.performMiniaturize(nil)
        case SettingsTitlebarLayout.trafficLightIdentifier(for: .zoomButton):
            window.performZoom(nil)
        default:
            break
        }
    }

    /// Selector for the button's own target/action — used by VoiceOver /
    /// Full Keyboard Access activation (`performClick(_:)` /
    /// `accessibilityPerformPress()`), not by live mouse clicks (see
    /// `ownedTrafficLightClicked`).
    private static func trafficLightAction(for type: NSWindow.ButtonType) -> Selector {
        switch type {
        case .closeButton: return #selector(NSWindow.performClose(_:))
        case .miniaturizeButton: return #selector(NSWindow.performMiniaturize(_:))
        default: return #selector(NSWindow.performZoom(_:))
        }
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
            button.toolTip = String(localized: "Toggle Sidebar", bundle: WinkResourceBundle.bundle)
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
    /// control, expressed in `titlebarView`'s own coordinate space (origin
    /// at the native 28pt band's bottom edge, i.e. 8pt above the true bottom
    /// of the full 36pt design row). Wink owns every control on this row —
    /// including the traffic lights, via `installOwnedTrafficLights` — so
    /// this can finally be the design row's own midpoint (18pt from the top)
    /// instead of AppKit's native-band center: `titlebarView.bounds.height`
    /// is the native band height (28pt); subtracting the design row's half
    /// height (18pt) converts "18pt from the row's top" into this view's
    /// bottom-up coordinate space.
    private func chromeBaselineCenterY(in titlebarView: NSView) -> CGFloat {
        titlebarView.bounds.height - SettingsTitlebarLayout.height / 2
    }

    private func removeInstalledChrome(from hostView: NSView) {
        let identifiers = [
            SettingsTitlebarLayout.backgroundIdentifier,
            SettingsTitlebarLayout.hairlineIdentifier,
            SettingsTitlebarLayout.sidebarToggleIdentifier,
            SettingsTitlebarLayout.titleIdentifier,
            SettingsTitlebarLayout.trafficLightIdentifier(for: .closeButton),
            SettingsTitlebarLayout.trafficLightIdentifier(for: .miniaturizeButton),
            SettingsTitlebarLayout.trafficLightIdentifier(for: .zoomButton),
        ]
        for subview in hostView.subviews where subview.identifier.map(identifiers.contains) == true {
            subview.removeFromSuperview()
        }
    }

    private static func sidebarToggleImage() -> NSImage? {
        let toggleSidebarDescription = String(localized: "Toggle Sidebar", bundle: WinkResourceBundle.bundle)
        let image = NSImage(
            systemSymbolName: SettingsTitlebarLayout.sidebarToggleSymbolName,
            accessibilityDescription: toggleSidebarDescription
        ) ?? NSImage(
            systemSymbolName: SettingsTitlebarLayout.sidebarToggleFallbackSymbolName,
            accessibilityDescription: toggleSidebarDescription
        )
        return image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: SettingsTitlebarLayout.toggleIconPointSize, weight: .regular)
        )
    }

    /// The toggle sits `toggleGapFromZoomButton` past the button cluster's
    /// trailing edge (in reading direction), on the shared baseline. Anchors
    /// on Wink's *owned* zoom button (not the hidden AppKit original) since
    /// that's the one actually visible on the design centerline. A titled
    /// window always carries a zoom button alongside its close button, so
    /// `nil` (leave the current frame untouched) is a defensive fallback, not
    /// a reachable layout state.
    private func sidebarToggleFrame(in titlebarView: NSView) -> NSRect? {
        guard let window,
              let zoomButton = ownedTrafficLights[.zoomButton] else {
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

/// Derives titlebar chrome colors from the shared `WinkPalette` tokens
/// instead of keeping a second, hand-copied set of constants — the
/// hand-copied set had drifted from the design source (light-mode hairline
/// alpha, dark-mode text tint) once already.
private enum SettingsTitlebarColors {
    static func chromeBackground(for appearance: NSAppearance) -> NSColor {
        NSColor(tokens(for: appearance).chromeBg)
    }

    static func hairline(for appearance: NSAppearance) -> NSColor {
        NSColor(tokens(for: appearance).chromeBorder)
    }

    static func textPrimary(for appearance: NSAppearance) -> NSColor {
        NSColor(tokens(for: appearance).textPrimary)
    }

    static func textSecondary(for appearance: NSAppearance) -> NSColor {
        NSColor(tokens(for: appearance).textSecondary)
    }

    private static func tokens(for appearance: NSAppearance) -> WinkPalette.Tokens {
        isDark(appearance) ? WinkPalette.dark : WinkPalette.light
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

private struct SettingsCommands: Commands {
    @Environment(\.openSettings) private var openSettings
    let settingsLauncher: SettingsLauncher

    var body: some Commands {
        let _ = installOpenSettingsHandler()

        CommandGroup(replacing: .appSettings) {
            Button(String(localized: "Settings…", bundle: WinkResourceBundle.bundle)) {
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
