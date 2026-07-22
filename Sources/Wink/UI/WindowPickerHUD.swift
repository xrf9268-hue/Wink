import AppKit
import SwiftUI

/// Shared base for Wink's key-capable, non-activating HUD panels (#352's
/// window picker, #356's search palette): `.nonactivatingPanel` keeps Wink
/// from activating when the panel fronts, while the explicit `canBecomeKey`
/// override (borderless panels are never key by default) lets the panel
/// receive keyboard input directly — discrete arrow/Enter/Escape routing for
/// the window picker, real text input via the field editor for the search
/// palette (a focused `TextField` needs key status to get the field editor
/// at all). This is the TilesPanel pattern — deliberately NOT WhatsNewPanel,
/// whose `.titled` mask only avoids stealing focus at order-front time.
class KeyCapableHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
    }
}

/// Anchors a HUD panel centered on the screen holding the pointer — these
/// panels follow the user's attention, not a target window. Shared by the
/// window picker (#352) and the search palette (#356); the panel must
/// already be sized (`setContentSize`/`setFrame`) before calling this.
@MainActor
enum HUDPanelPlacement {
    static func centerOnPointerScreen(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screenFrame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        ))
    }
}

/// Window-picker-specific panel: same key-capable base as above, plus the
/// discrete `keyDown` routing the picker's arrow/Enter/Escape handling
/// needs (there's no focused text field here to dispatch through).
final class WindowPickerPanel: KeyCapableHUDPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true {
            super.keyDown(with: event)
        }
    }
}

/// Hold-to-show per-app window picker: icons + titles only, never
/// thumbnails (the #352 red line — Screen Recording stays off the
/// permission list). Lists one app's current-Space windows; arrows/Enter
/// focus one, Escape cancels, clicking a row commits it, and losing key
/// status (clicking elsewhere) dismisses with no side effects.
@MainActor
final class WindowPickerHUDController {
    private let onSessionStateChange: @MainActor (Bool) -> Void
    private let focusWindow: @MainActor (CGWindowID, WindowPickerSession) -> Bool

    private var panel: WindowPickerPanel?
    private var hosting: NSHostingView<WindowPickerView>?
    private var session: WindowPickerSession?
    private var selectionIndex = 0
    private var resignKeyObserver: NSObjectProtocol?

    init(
        onSessionStateChange: @escaping @MainActor (Bool) -> Void,
        focusWindow: @escaping @MainActor (CGWindowID, WindowPickerSession) -> Bool
    ) {
        self.onSessionStateChange = onSessionStateChange
        self.focusWindow = focusWindow
    }

    var isPresented: Bool { session != nil }

    func present(session: WindowPickerSession) {
        dismiss()
        self.session = session
        selectionIndex = 0
        onSessionStateChange(true)

        let panel = ensurePanel()
        renderContent()
        HUDPanelPlacement.centerOnPointerScreen(panel)
        panel.makeKeyAndOrderFront(nil)

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        guard session != nil else { return }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        session = nil
        panel?.orderOut(nil)
        onSessionStateChange(false)
    }

    private func commitSelection() {
        guard let session, session.items.indices.contains(selectionIndex) else {
            dismiss()
            return
        }
        let windowID = session.items[selectionIndex].windowID
        // Dismiss FIRST: the raise makes another app key, which fires the
        // resign-key observer; running the dismissal ourselves keeps the
        // session-state transition ordered before the focus side effects.
        let committed = session
        dismiss()
        _ = focusWindow(windowID, committed)
    }

    private func commitRow(windowID: CGWindowID) {
        guard let session else { return }
        let committed = session
        dismiss()
        _ = focusWindow(windowID, committed)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let session else { return false }
        switch event.keyCode {
        case 125: // down arrow
            selectionIndex = (selectionIndex + 1) % session.items.count
            renderContent()
            return true
        case 126: // up arrow
            selectionIndex = (selectionIndex - 1 + session.items.count) % session.items.count
            renderContent()
            return true
        case 36, 76: // return, keypad enter
            commitSelection()
            return true
        case 53: // escape
            dismiss()
            return true
        default:
            return false
        }
    }

    private func ensurePanel() -> WindowPickerPanel {
        if let panel {
            return panel
        }
        let panel = WindowPickerPanel()
        panel.onKeyDown = { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleKeyDown(event) ?? false
            }
        }
        self.panel = panel
        return panel
    }

    private func renderContent() {
        guard let session, let panel else { return }
        let view = WindowPickerView(
            session: session,
            selectionIndex: selectionIndex,
            onRowTap: { [weak self] windowID in
                self?.commitRow(windowID: windowID)
            }
        )
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            self.hosting = hosting
            panel.contentView = hosting
        }
        hosting?.layoutSubtreeIfNeeded()
        let size = hosting?.fittingSize ?? .zero
        panel.setContentSize(size)
    }
}

private struct WindowPickerView: View {
    let session: WindowPickerSession
    let selectionIndex: Int
    let onRowTap: (CGWindowID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                AppIconView(bundleIdentifier: session.bundleIdentifier, size: 16)
                Text(session.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            // Bounded height + scroll: an app with dozens of windows must
            // not produce a panel taller than the screen; the selected row
            // stays scrolled into view for keyboard navigation.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(session.items.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 8) {
                                Image(systemName: item.isMinimized ? "arrow.down.right.square" : "macwindow")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(item.title ?? String(localized: "Untitled Window", bundle: WinkResourceBundle.bundle))
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 12)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(index == selectionIndex ? Color.accentColor.opacity(0.25) : .clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onRowTap(item.windowID)
                            }
                            .id(index)
                        }
                    }
                }
                .frame(maxHeight: 460)
                .onAppear {
                    proxy.scrollTo(selectionIndex)
                }
                .onChange(of: selectionIndex) { _, newIndex in
                    proxy.scrollTo(newIndex)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 280, maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
