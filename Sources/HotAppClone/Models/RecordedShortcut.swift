import Foundation

struct RecordedShortcut: Equatable {
    var keyEquivalent: String
    var modifierFlags: [String]

    var isHyper: Bool {
        let normalized = Set(modifierFlags.map { $0.lowercased() })
        return normalized.isSuperset(of: ["command", "option", "control", "shift"])
    }

    var displayText: String {
        let modifiers = modifierFlags.map(Self.symbol(for:)).joined()
        return modifiers + keyEquivalent.uppercased()
    }

    private static func symbol(for modifier: String) -> String {
        switch modifier.lowercased() {
        case "command": return "⌘"
        case "option": return "⌥"
        case "control": return "⌃"
        case "shift": return "⇧"
        case "function": return "fn"
        default: return modifier
        }
    }
}

extension AppShortcut {
    var isHyper: Bool {
        let normalized = Set(modifierFlags.map { $0.lowercased() })
        return normalized.isSuperset(of: ["command", "option", "control", "shift"])
    }

    var displayText: String {
        let symbols = modifierFlags.map { mod -> String in
            switch mod.lowercased() {
            case "command": return "⌘"
            case "option": return "⌥"
            case "control": return "⌃"
            case "shift": return "⇧"
            case "function": return "fn"
            default: return mod
            }
        }.joined()
        return symbols + keyEquivalent.uppercased()
    }
}
