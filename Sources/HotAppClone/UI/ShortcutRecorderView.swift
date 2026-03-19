import AppKit
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var recordedShortcut: RecordedShortcut?
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.onCapture = { shortcut in
            recordedShortcut = shortcut
            isRecording = false
        }
        field.onRecordingChange = { recording in
            isRecording = recording
        }
        field.onCancel = {
            isRecording = false
        }
        return field
    }

    func updateNSView(_ nsView: RecorderField, context: Context) {
        nsView.updateRecordingState(isRecording: isRecording, shortcut: recordedShortcut)
    }
}

final class RecorderField: NSTextField {
    var onCapture: ((RecordedShortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    private let keySymbolMapper = KeySymbolMapper()
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isBordered = true
        isBezeled = true
        focusRingType = .default
        placeholderString = "Click to record shortcut"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateRecordingState(isRecording: Bool, shortcut: RecordedShortcut?) {
        self.isRecording = isRecording
        if isRecording {
            placeholderString = "Press shortcut (Esc to cancel)"
            stringValue = ""
            textColor = .controlAccentColor
        } else {
            placeholderString = "Click to record shortcut"
            stringValue = shortcut?.displayText ?? ""
            textColor = .labelColor
        }
    }

    override var acceptsFirstResponder: Bool { true }

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
            stringValue = "Requires at least one modifier (⌘⌥⌃⇧)"
            textColor = .systemOrange
            return
        }

        guard let keyEquivalent else {
            stringValue = "Unsupported key — try a letter, number, or F-key"
            textColor = .systemOrange
            return
        }

        let shortcut = RecordedShortcut(keyEquivalent: keyEquivalent, modifierFlags: modifiers)
        onCapture?(shortcut)
        stringValue = shortcut.displayText
        textColor = .labelColor
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
