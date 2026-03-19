import AppKit
import Carbon.HIToolbox

struct ShortcutTrigger: Hashable {
    let keyCode: CGKeyCode
    let modifierMask: UInt
}

struct KeyMatcher {
    func matches(_ keyPress: EventTapManager.KeyPress, shortcut: AppShortcut) -> Bool {
        trigger(for: keyPress) == trigger(for: shortcut)
    }

    func trigger(for keyPress: EventTapManager.KeyPress) -> ShortcutTrigger {
        let mask = keyPress.modifiers.intersection(NSEvent.ModifierFlags.deviceIndependentFlagsMask)
        return ShortcutTrigger(keyCode: keyPress.keyCode, modifierMask: normalizedMask(from: mask))
    }

    func trigger(for shortcut: AppShortcut) -> ShortcutTrigger {
        ShortcutTrigger(
            keyCode: keyCode(for: shortcut.keyEquivalent),
            modifierMask: normalizedMask(from: shortcut.modifierFlags)
        )
    }

    func buildIndex(for shortcuts: [AppShortcut]) -> [ShortcutTrigger: AppShortcut] {
        var index: [ShortcutTrigger: AppShortcut] = [:]
        index.reserveCapacity(shortcuts.count)
        for shortcut in shortcuts {
            index[trigger(for: shortcut)] = shortcut
        }
        return index
    }

    // MARK: - Key code mapping (shared data source for KeySymbolMapper reverse lookups)

    static let keyEquivalentToCode: [String: CGKeyCode] = [
        "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C),
        "d": CGKeyCode(kVK_ANSI_D), "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
        "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H), "i": CGKeyCode(kVK_ANSI_I),
        "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
        "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O),
        "p": CGKeyCode(kVK_ANSI_P), "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
        "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T), "u": CGKeyCode(kVK_ANSI_U),
        "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
        "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
        "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2),
        "3": CGKeyCode(kVK_ANSI_3), "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
        "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7), "8": CGKeyCode(kVK_ANSI_8),
        "9": CGKeyCode(kVK_ANSI_9),
        "space": CGKeyCode(kVK_Space), "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
        "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
        "tab": CGKeyCode(kVK_Tab), "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
        "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
        "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3),
        "f4": CGKeyCode(kVK_F4), "f5": CGKeyCode(kVK_F5), "f6": CGKeyCode(kVK_F6),
        "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8), "f9": CGKeyCode(kVK_F9),
        "f10": CGKeyCode(kVK_F10), "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12),
    ]

    static let codeToKeyEquivalent: [CGKeyCode: String] = {
        var reverse: [CGKeyCode: String] = [:]
        for (key, code) in keyEquivalentToCode {
            // Prefer canonical names (skip aliases like "enter", "esc", "backspace")
            if reverse[code] == nil || key.count < (reverse[code]?.count ?? Int.max) {
                reverse[code] = key
            }
        }
        return reverse
    }()

    private func keyCode(for keyEquivalent: String) -> CGKeyCode {
        Self.keyEquivalentToCode[keyEquivalent.lowercased()] ?? CGKeyCode(UInt16.max)
    }

    private func normalizedMask(from flags: NSEvent.ModifierFlags) -> UInt {
        var mask: UInt = 0
        if flags.contains(.command) { mask |= NSEvent.ModifierFlags.command.rawValue }
        if flags.contains(.option) { mask |= NSEvent.ModifierFlags.option.rawValue }
        if flags.contains(.control) { mask |= NSEvent.ModifierFlags.control.rawValue }
        if flags.contains(.shift) { mask |= NSEvent.ModifierFlags.shift.rawValue }
        if flags.contains(.function) { mask |= NSEvent.ModifierFlags.function.rawValue }
        return mask
    }

    private func normalizedMask(from modifiers: [String]) -> UInt {
        var mask: UInt = 0
        for mod in modifiers {
            switch mod.lowercased() {
            case "command": mask |= NSEvent.ModifierFlags.command.rawValue
            case "option": mask |= NSEvent.ModifierFlags.option.rawValue
            case "control": mask |= NSEvent.ModifierFlags.control.rawValue
            case "shift": mask |= NSEvent.ModifierFlags.shift.rawValue
            case "function": mask |= NSEvent.ModifierFlags.function.rawValue
            default: break
            }
        }
        return mask
    }
}
