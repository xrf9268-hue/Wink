import Foundation
import CoreGraphics

// Deterministic key driver for Wink runtime validation.
// Every posted event has its flags set EXPLICITLY so nothing is inherited
// from the shared HID flags state (a stale secondaryFn bit silently breaks
// chord identity: KeyMatcher tracks .function as a real modifier).
//
//   winkkeys chord <keyCode> <holdMs>   F19 down -> key down -> hold -> key up -> F19 up
//   winkkeys f19 <holdMs>               F19 held alone for holdMs (cheat sheet / idle hold)
//   winkkeys key <keyCode> [holdMs]     plain key press
//   winkkeys chord-nokeyup <keyCode>    F19 down -> key down, then leave both down (lost-keyUp probe)
//   winkkeys release                    F19 up + safety-release of common keys
//   winkkeys type <text>                unicode string, one keyDown/Up per character
//
// Events post at .cghidEventTap so they traverse session event taps exactly
// like hardware input (same rationale as scripts/cgevent-helper).

let src = CGEventSource(stateID: .hidSystemState)
let F19: CGKeyCode = 80

func post(_ code: CGKeyCode, _ down: Bool, flags: CGEventFlags = []) {
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else {
        FileHandle.standardError.write("failed to create event \(code)\n".data(using: .utf8)!)
        exit(1)
    }
    e.flags = flags
    e.post(tap: .cghidEventTap)
}

func ms(_ n: Double) { usleep(UInt32(n * 1000)) }

let a = CommandLine.arguments
guard a.count >= 2 else { print("usage: winkkeys <chord|f19|key|chord-nokeyup|release|type> ..."); exit(1) }

switch a[1] {
case "chord":
    let code = CGKeyCode(a[2])!
    let hold = Double(a.count > 3 ? a[3] : "20")!
    // warm the event pipeline so lazy init is not charged to the measured span
    _ = CGEvent(keyboardEventSource: src, virtualKey: F19, keyDown: false)
    post(F19, true); ms(12)
    let tDown = Date()
    post(code, true); ms(hold)
    post(code, false)
    let downSpan = Date().timeIntervalSince(tDown) * 1000
    ms(12)
    post(F19, false)
    print(String(format: "chord keyCode=%d requestedHoldMs=%.0f actualKeyDownSpanMs=%.1f", code, hold, downSpan))
case "f19":
    let hold = Double(a[2])!
    post(F19, true); ms(hold); post(F19, false)
    print("f19 heldMs=\(hold)")
case "key":
    let code = CGKeyCode(a[2])!
    let hold = Double(a.count > 3 ? a[3] : "20")!
    post(code, true); ms(hold); post(code, false)
    print("key \(code)")
case "chord-modfirst":
    // Modifiers-first release: F19 goes up BEFORE the letter, so the letter's
    // up edge no longer carries the Hyper union and cannot be delivered as
    // the same phased chord — the real-world "lost keyUp" the arbiter must
    // resolve via its physical keyState probe.
    let code = CGKeyCode(a[2])!
    let hold = Double(a.count > 3 ? a[3] : "100")!
    post(F19, true); ms(12)
    post(code, true); ms(hold)
    post(F19, false); ms(30)
    post(code, false)
    print("chord-modfirst keyCode=\(code) letterHeldMs=\(hold + 30)")
case "chord-nokeyup":
    let code = CGKeyCode(a[2])!
    post(F19, true); ms(12); post(code, true)
    print("chord-nokeyup keyCode=\(code) — both edges left DOWN")
case "cooldown-probe":
    // #382 acceptance: hide an app with its shortcut, then commit the SAME app
    // from the palette inside the 400ms per-bundle toggle cooldown. One process
    // so the whole sequence fits the window; every F19 hold stays above the
    // 80ms Caps-Lock toggle-quirk threshold so no keystroke inherits Hyper.
    let appKey = CGKeyCode(a[2])!
    let trigKey = CGKeyCode(a[3])!
    let text = a[4]
    _ = CGEvent(keyboardEventSource: src, virtualKey: F19, keyDown: false)
    let t0 = Date()
    post(F19, true); ms(12)
    post(appKey, true)                       // hide dispatches here (non-phased)
    let tHide = Date()
    ms(25); post(appKey, false); ms(70); post(F19, false)
    post(F19, true); ms(12); post(trigKey, true); ms(20); post(trigKey, false); ms(65); post(F19, false)
    ms(35)
    for ch in text {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) else { continue }
        var buf = Array(String(ch).utf16); e.flags = []
        e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: &buf); e.post(tap: .cghidEventTap); ms(8)
        guard let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
        u.flags = []; u.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: &buf); u.post(tap: .cghidEventTap); ms(8)
    }
    ms(10)
    post(36, true); ms(20); post(36, false)   // Enter commits
    print(String(format: "cooldown-probe: hide->commit = %.0fms (cooldown window is 400ms), total=%.0fms",
                 Date().timeIntervalSince(tHide) * 1000, Date().timeIntervalSince(t0) * 1000))
case "stdchord":
    // Standard (non-Hyper) chord: control+option+command+<key>, exercising the
    // Carbon EventHotKey route rather than the interception tap.
    let code = CGKeyCode(a[2])!
    let f: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    post(59, true, flags: [.maskControl]); ms(10)
    post(58, true, flags: [.maskControl, .maskAlternate]); ms(10)
    post(55, true, flags: f); ms(10)
    post(code, true, flags: f); ms(30); post(code, false, flags: f); ms(10)
    post(55, false, flags: [.maskControl, .maskAlternate]); ms(8)
    post(58, false, flags: [.maskControl]); ms(8)
    post(59, false, flags: [])
    print("stdchord ctrl+opt+cmd+\(code)")
case "f19-repeat":
    // Emulates a REAL held key: the initial down, then autorepeat downs
    // (kCGKeyboardEventAutorepeat = 1) every repeatMs, then the up.
    let total = Double(a[2])!
    let every = Double(a.count > 3 ? a[3] : "40")!
    post(F19, true)
    var elapsed = 0.0
    while elapsed < total {
        ms(every); elapsed += every
        if let e = CGEvent(keyboardEventSource: src, virtualKey: F19, keyDown: true) {
            e.flags = []
            e.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            e.post(tap: .cghidEventTap)
        }
    }
    post(F19, false)
    print("f19-repeat totalMs=\(total) everyMs=\(every)")
case "click":
    // Left click at a global (top-left origin) point.
    let x = Double(a[2])!, y = Double(a[3])!
    let pt = CGPoint(x: x, y: y)
    if let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) {
        move.post(tap: .cghidEventTap)
    }
    ms(40)
    if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left) {
        down.post(tap: .cghidEventTap)
    }
    ms(50)
    if let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left) {
        up.post(tap: .cghidEventTap)
    }
    print("click \(x),\(y)")
case "release":
    post(F19, false)
    for c in [CGKeyCode(0), 1, 2, 3, 15, 17, 35, 49] { post(c, false) }
    print("released")
case "type":
    let text = a[2]
    for ch in text {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) else { continue }
        var buf = Array(String(ch).utf16)
        e.flags = []
        e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: &buf)
        e.post(tap: .cghidEventTap)
        ms(18)
        guard let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
        u.flags = []
        u.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: &buf)
        u.post(tap: .cghidEventTap)
        ms(18)
    }
    print("typed \(text)")
default:
    print("unknown: \(a[1])"); exit(1)
}
