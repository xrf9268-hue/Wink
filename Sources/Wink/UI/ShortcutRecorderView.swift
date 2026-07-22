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
/// chrome — `ShortcutRecorderView` draws the designed dashed control on top —
/// but still needs real `NSView` first-responder status to receive
/// `keyDown`/`flagsChanged` events.
final class RecorderField: NSView {
    var onCapture: ((RecordedShortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onLiveModifiersChange: (([String]) -> Void)?
    var onErrorChange: ((String?) -> Void)?

    private let keySymbolMapper = KeySymbolMapper()
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    func updateRecordingState(isRecording: Bool) {
        self.isRecording = isRecording
        if !isRecording {
            onLiveModifiersChange?([])
            onErrorChange?(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onRecordingChange?(true)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }

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
