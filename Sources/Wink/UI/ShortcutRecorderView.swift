import AppKit
import Foundation
import SwiftUI

/// The active-recording composer field. Renders the dashed accent-blue
/// control from tab-shortcuts.jsx:80-94 in SwiftUI, backed by an invisible
/// `RecorderField` (NSView) that owns keyboard capture.
struct ShortcutRecorderView: View {
    @Environment(\.winkPalette) private var palette

    @Binding var recordedShortcut: RecordedShortcut?
    @Binding var isRecording: Bool

    @State private var liveModifierLabels: [String] = []
    @State private var errorMessage: String?

    private var tint: Color {
        // Red, not amber: warn-amber now shares the brand accent hue, so an
        // amber error state would be indistinguishable from idle recording.
        errorMessage == nil ? palette.accent : palette.red
    }

    var body: some View {
        HStack(spacing: 6) {
            WinkIcon.record.image(size: 11)
                .foregroundStyle(tint)
            Text(errorMessage ?? String(localized: "Recording…", bundle: WinkResourceBundle.bundle))
                .font(WinkType.bodyText)
                .fontWeight(.medium)
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            if errorMessage == nil, !liveModifierLabels.isEmpty {
                ShortcutKeycapStrip(labels: liveModifierLabels, size: .small)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(palette.fieldBg)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    palette.accentBorderSoft,
                    style: StrokeStyle(lineWidth: 1, dash: ShortcutRecorderIdleField.dashPattern)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .background(
            RecorderKeyCaptureRepresentable(
                isRecording: isRecording,
                onCapture: { shortcut in
                    recordedShortcut = shortcut
                    isRecording = false
                },
                onRecordingChange: { recording in
                    isRecording = recording
                },
                onCancel: {
                    isRecording = false
                },
                onLiveModifiersChange: { modifiers in
                    liveModifierLabels = modifiers.map(ModifierFormatting.symbol(for:))
                },
                onErrorChange: { message in
                    errorMessage = message
                }
            )
        )
    }
}

private struct RecorderKeyCaptureRepresentable: NSViewRepresentable {
    let isRecording: Bool
    let onCapture: (RecordedShortcut) -> Void
    let onRecordingChange: (Bool) -> Void
    let onCancel: () -> Void
    let onLiveModifiersChange: ([String]) -> Void
    let onErrorChange: (String?) -> Void

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        updateCallbacks(on: field)
        return field
    }

    func updateNSView(_ nsView: RecorderField, context: Context) {
        updateCallbacks(on: nsView)
        nsView.updateRecordingState(isRecording: isRecording)
    }

    private func updateCallbacks(on field: RecorderField) {
        field.onCapture = onCapture
        field.onRecordingChange = onRecordingChange
        field.onCancel = onCancel
        field.onLiveModifiersChange = onLiveModifiersChange
        field.onErrorChange = onErrorChange
    }
}

/// Invisible key-capture surface for the recording composer. Owns no visible
/// chrome — `ShortcutRecorderView` draws the designed dashed control on top.
///
/// Capture is monitor-based, not responder-based (#417): SwiftUI never
/// routes first-responder status to a `.background` NSView (the settings
/// sidebar keeps `AXFocusedUIElement` throughout), and the SwiftUI content
/// drawn on top swallows clicks before they reach `mouseDown` here. So while
/// recording, a local `NSEvent` monitor owns the session: it captures chords
/// and swallows key-downs wherever keyboard focus sits, and cancels on a
/// click outside the field. The responder overrides remain as a harmless
/// fallback for the case where the field does end up first responder.
final class RecorderField: NSView {
    var onCapture: ((RecordedShortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onLiveModifiersChange: (([String]) -> Void)?
    var onErrorChange: ((String?) -> Void)?

    private let keySymbolMapper = KeySymbolMapper()
    private var isRecording = false
    private var sessionMonitor: Any?

    var isMonitoringForTesting: Bool { sessionMonitor != nil }

    override var acceptsFirstResponder: Bool { true }

    func updateRecordingState(isRecording: Bool) {
        self.isRecording = isRecording
        if isRecording {
            installSessionMonitorIfNeeded()
        } else {
            removeSessionMonitorIfNeeded()
            onLiveModifiersChange?([])
            onErrorChange?(nil)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // SwiftUI dismantles this view by detaching it from the window; the
        // monitor must not outlive it (its closure only holds `self` weakly,
        // but a leaked monitor would keep swallowing key-downs app-wide).
        if newWindow == nil {
            removeSessionMonitorIfNeeded()
            if isRecording {
                // Closing Settings (or switching tabs) mid-recording must
                // end the session: the editor's recording flag drives the
                // #417 dispatch gate in ShortcutManager, and a latched gate
                // with no live recorder would silently kill every shortcut.
                // Deferred a tick — this fires during view dismantling, and
                // the cancel writes SwiftUI state.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRecording else { return }
                    self.onCancel?()
                }
            }
        } else if isRecording {
            // Recording started before the view was attached (makeNSView →
            // updateNSView precedes window insertion on first swap-in).
            installSessionMonitorIfNeeded()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onRecordingChange?(true)
    }

    override func keyDown(with event: NSEvent) {
        // Normally unreachable while recording — the session monitor swallows
        // key-downs before dispatch — but kept as a fallback if the field is
        // first responder and the monitor is somehow absent.
        guard isRecording else { return }
        handleRecordingKeyDown(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        onLiveModifiersChange?(normalizedModifiers(from: event.modifierFlags))
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            onCancel?()
        }
        return super.resignFirstResponder()
    }

    // MARK: - Session monitor

    private func installSessionMonitorIfNeeded() {
        guard sessionMonitor == nil else { return }
        sessionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleMonitoredEvent(event)
        }
    }

    private func removeSessionMonitorIfNeeded() {
        if let sessionMonitor {
            NSEvent.removeMonitor(sessionMonitor)
            self.sessionMonitor = nil
        }
    }

    /// Routes one monitored event through the recording session. Returning
    /// `nil` swallows the event; returning it lets dispatch continue.
    /// Internal (not private) so tests can drive capture with synthesized
    /// `NSEvent`s — the monitor itself needs a running event loop.
    func handleMonitoredEvent(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }

        switch event.type {
        case .keyDown:
            // Swallow every key-down during recording: it is either the
            // captured chord or feedback about an invalid one. Letting it
            // through would double-dispatch into whatever holds focus
            // (typing into the filter field, moving the sidebar selection).
            handleRecordingKeyDown(event)
            return nil
        case .flagsChanged:
            onLiveModifiersChange?(normalizedModifiers(from: event.modifierFlags))
            return event
        case .leftMouseDown, .rightMouseDown:
            // A click anywhere outside the field ends the session — the
            // responder-based cancel (`resignFirstResponder`) never fires
            // when the field was never first responder. The click itself
            // passes through so the control the user aimed at still works.
            if !isInsideRecorder(event) {
                onCancel?()
            }
            return event
        default:
            return event
        }
    }

    private func handleRecordingKeyDown(_ event: NSEvent) {
        // Escape cancels recording
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        let modifiers = normalizedModifiers(from: event.modifierFlags)
        let keyEquivalent = keySymbolMapper.keyEquivalent(for: CGKeyCode(event.keyCode))

        if modifiers.isEmpty {
            onErrorChange?(String(localized: "Requires at least one modifier (⌘⌥⌃⇧)", bundle: WinkResourceBundle.bundle))
            return
        }

        guard let keyEquivalent else {
            onErrorChange?(String(localized: "Unsupported key — try a letter, number, or F-key", bundle: WinkResourceBundle.bundle))
            return
        }

        onErrorChange?(nil)
        onCapture?(RecordedShortcut(keyEquivalent: keyEquivalent, modifierFlags: modifiers))
    }

    private func isInsideRecorder(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    private func normalizedModifiers(from flags: NSEvent.ModifierFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.control) { result.append("control") }
        if flags.contains(.option) { result.append("option") }
        if flags.contains(.shift) { result.append("shift") }
        if flags.contains(.command) { result.append("command") }
        if flags.contains(.function) { result.append("function") }
        return result
    }
}
