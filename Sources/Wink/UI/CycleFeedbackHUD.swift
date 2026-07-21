import AppKit
import SwiftUI

struct CycleHUDPresentation: Equatable, Sendable {
    let bundleIdentifier: String
    let stepIndex: Int
    let windowCount: Int
    let windowTitle: String?
    /// Anchors the HUD to the display actually hosting the cycled window.
    let targetWindowID: CGWindowID
}

/// Transient, display-only feedback for window cycling: app icon plus
/// "2/5 · Window Title". Never takes key or main status, ignores the
/// mouse, joins all Spaces, and dismisses itself shortly after the last
/// cycle step (matching the gesture's idle expiry feel).
@MainActor
final class CycleFeedbackHUDController {
    static let shared = CycleFeedbackHUDController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<CycleHUDView>?
    private var dismissWork: DispatchWorkItem?
    private let dismissDelay: TimeInterval = 1.2

    func show(_ presentation: CycleHUDPresentation) {
        let view = CycleHUDView(presentation: presentation)
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.isFloatingPanel = true
            panel.level = .popUpMenu
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
            panel.contentView = hosting
            self.panel = panel
            self.hostingView = hosting
        }

        guard let panel, let hostingView else { return }
        let size = hostingView.fittingSize
        // NSScreen.main tracks THIS app's key window; a never-key LSUIElement
        // panel would always land on the menu-bar display. Anchor to the
        // display hosting the cycled window instead, via its CG bounds
        // (window geometry is not TCC-gated — only names/pixels are).
        let screen = Self.screen(forWindowID: presentation.targetWindowID)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + 140
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay, execute: work)
    }

    private static func screen(forWindowID windowID: CGWindowID) -> NSScreen? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let boundsDict = info.first?[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }
        // CG bounds are global top-left-origin; NSScreen frames are
        // bottom-left-origin. Convert the window's center point.
        let centerX = (boundsDict["X"] ?? 0) + (boundsDict["Width"] ?? 0) / 2
        let cgCenterY = (boundsDict["Y"] ?? 0) + (boundsDict["Height"] ?? 0) / 2
        guard let primary = NSScreen.screens.first else { return nil }
        let center = NSPoint(x: centerX, y: primary.frame.maxY - cgCenterY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    func hide() {
        dismissWork?.cancel()
        dismissWork = nil
        panel?.orderOut(nil)
    }
}

private struct CycleHUDView: View {
    let presentation: CycleHUDPresentation

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(bundleIdentifier: presentation.bundleIdentifier, size: 20)
            Text("\(presentation.stepIndex)/\(presentation.windowCount)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if let title = presentation.windowTitle, !title.isEmpty {
                Text("·")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}
