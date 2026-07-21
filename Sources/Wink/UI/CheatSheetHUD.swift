import AppKit
import SwiftUI

struct CheatSheetRow: Equatable, Identifiable {
    let id: UUID
    let appName: String
    let bundleIdentifier: String
    let keyDisplay: String
}

/// Idle-hold Hyper cheat sheet: hold Caps Lock ≥600ms without pressing a
/// chord key and a display-only panel lists every enabled shortcut (icon,
/// name, keycap). Any consumed chord or the Hyper release hides it. The
/// timer runs on the main actor; hold events arrive from the tap thread
/// and hop here once.
@MainActor
final class CheatSheetHUDController {
    static let holdThreshold: TimeInterval = 0.6

    private let rowsProvider: @MainActor () -> [CheatSheetRow]
    private let isEnabled: @MainActor () -> Bool
    private let present: @MainActor ([CheatSheetRow]) -> Void
    private let dismiss: @MainActor () -> Void
    private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private var pendingHoldGeneration = 0
    private var holdTimerActive = false
    private(set) var isPresented = false

    init(
        rowsProvider: @escaping @MainActor () -> [CheatSheetRow],
        isEnabled: @escaping @MainActor () -> Bool,
        present: (@MainActor ([CheatSheetRow]) -> Void)? = nil,
        dismiss: (@MainActor () -> Void)? = nil,
        schedule: (@MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        self.rowsProvider = rowsProvider
        self.isEnabled = isEnabled
        self.present = present ?? { rows in
            CheatSheetPanelController.shared.show(rows: rows)
        }
        self.dismiss = dismiss ?? {
            CheatSheetPanelController.shared.hide()
        }
        self.schedule = schedule ?? { delay, operation in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    operation()
                }
            }
        }
    }

    /// Cancels any armed timer and dismisses a presented sheet. Used when
    /// configuration changes cut the gesture short with no `ended` event.
    func reset() {
        handle(.ended)
    }

    func handle(_ event: HyperHoldEvent) {
        switch event {
        case .began:
            // Autorepeat re-delivers began while held: one timer per gesture.
            guard isEnabled(), !holdTimerActive, !isPresented else { return }
            holdTimerActive = true
            pendingHoldGeneration += 1
            let generation = pendingHoldGeneration
            schedule(Self.holdThreshold) { [weak self] in
                guard let self,
                      self.holdTimerActive,
                      self.pendingHoldGeneration == generation,
                      // Re-checked at fire time: Hyper (or the sheet) may
                      // have been disabled mid-hold, and the tap clears its
                      // state without emitting `ended`.
                      self.isEnabled() else { return }
                self.holdTimerActive = false
                let rows = self.rowsProvider()
                guard !rows.isEmpty else { return }
                self.isPresented = true
                self.present(rows)
            }
        case .chordConsumed, .ended:
            holdTimerActive = false
            pendingHoldGeneration += 1
            if isPresented {
                isPresented = false
                dismiss()
            }
        }
    }
}

/// Display-only panel host, same never-key posture as the cycle HUD.
@MainActor
final class CheatSheetPanelController {
    static let shared = CheatSheetPanelController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<CheatSheetView>?

    func show(rows: [CheatSheetRow]) {
        let view = CheatSheetView(rows: rows)
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
        // Anchor to the display holding the pointer — the best available
        // attention proxy for a keyboard gesture with no target window.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct CheatSheetView: View {
    let rows: [CheatSheetRow]

    private var columns: [[CheatSheetRow]] {
        // Cap the panel height by flowing into columns of at most 9 rows.
        stride(from: 0, to: rows.count, by: 9).map {
            Array(rows[$0..<min($0 + 9, rows.count)])
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(column) { row in
                        HStack(spacing: 8) {
                            AppIconView(bundleIdentifier: row.bundleIdentifier, size: 18)
                            Text(row.appName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .frame(maxWidth: 140, alignment: .leading)
                            Spacer(minLength: 4)
                            Text(row.keyDisplay)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fixedSize()
    }
}
