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
}

// MARK: - AppShortcut display extensions

extension AppShortcut {
    var isHyper: Bool { ModifierFormatting.isHyperCombo(modifierFlags) }
    var displayText: String { ModifierFormatting.displayText(modifierFlags: modifierFlags, keyEquivalent: keyEquivalent) }
}
