import AppKit

struct KeyPress: Equatable, Hashable, Sendable {
    let keyCode: CGKeyCode
    let modifiers: NSEvent.ModifierFlags

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }
}
