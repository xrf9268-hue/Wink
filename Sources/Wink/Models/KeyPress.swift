import AppKit

struct KeyPress: Equatable, Hashable, Sendable {
    let keyCode: CGKeyCode
    let modifiers: NSEvent.ModifierFlags

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }
}

/// Which edge of a physical chord press a delivered event describes.
///
/// `KeyPress` itself stays pure chord identity (registration sets, the
/// trigger index, and the tap-route debounce all key on it); phase travels
/// alongside only on the phased-delivery channel for hold-capable chords.
/// Folding phase into `KeyPress` equality would either break registered-set
/// matching (up-phase lookups miss down-phase entries) or let the 200ms
/// same-chord debounce silently eat every `.up` event.
enum KeyEventPhase: Sendable {
    case down
    case up
}
