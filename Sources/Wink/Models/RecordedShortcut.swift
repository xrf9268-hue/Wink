import AppKit
import Foundation

// MARK: - Shared modifier helpers

enum ModifierFormatting {
    static let hyperModifiers: Set<String> = ["command", "option", "control", "shift"]

    static func symbol(for modifier: String) -> String {
        switch modifier.lowercased() {
        case "command": return "⌘"
        case "option": return "⌥"
        case "control": return "⌃"
        case "shift": return "⇧"
        case "function": return "fn"
        default: return modifier
        }
    }

    static func isHyperCombo(_ modifierFlags: [String]) -> Bool {
        Set(modifierFlags.map { $0.lowercased() }).isSuperset(of: hyperModifiers)
    }

    static func displayText(modifierFlags: [String], keyEquivalent: String) -> String {
        modifierFlags.map(symbol(for:)).joined() + keyEquivalent.uppercased()
    }
}

// MARK: - RecordedShortcut

struct RecordedShortcut: Equatable {
    var keyEquivalent: String
    var modifierFlags: [String]

    var isHyper: Bool { ModifierFormatting.isHyperCombo(modifierFlags) }
    var displayText: String { ModifierFormatting.displayText(modifierFlags: modifierFlags, keyEquivalent: keyEquivalent) }

    /// Chord identity → recorder value (#419). The modifier order matches
    /// `RecorderField.normalizedModifiers` so a rerouted capture is
    /// indistinguishable from a monitor-captured one. Returns nil for keys
    /// outside the recorder's contract (no `KeySymbolMapper` mapping) or a
    /// modifierless press — neither can name a bound chord.
    init?(keyPress: KeyPress) {
        guard let keyEquivalent = KeySymbolMapper().keyEquivalent(for: keyPress.keyCode) else {
            return nil
        }
        var modifiers: [String] = []
        let flags = keyPress.modifiers
        if flags.contains(.control) { modifiers.append("control") }
        if flags.contains(.option) { modifiers.append("option") }
        if flags.contains(.shift) { modifiers.append("shift") }
        if flags.contains(.command) { modifiers.append("command") }
        if flags.contains(.function) { modifiers.append("function") }
        guard !modifiers.isEmpty else { return nil }
        self.init(keyEquivalent: keyEquivalent, modifierFlags: modifiers)
    }

    init(keyEquivalent: String, modifierFlags: [String]) {
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
    }
}

// MARK: - AppShortcut display extensions

extension AppShortcut {
    var isHyper: Bool { ModifierFormatting.isHyperCombo(modifierFlags) }
    var displayText: String { ModifierFormatting.displayText(modifierFlags: modifierFlags, keyEquivalent: keyEquivalent) }
}
