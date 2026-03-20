import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os.log

private let logger = Logger(subsystem: "com.quickey.app", category: "EventTapManager")

@MainActor
final class EventTapManager {
    /// Returns `true` if the key press was handled and should be consumed (not passed to other apps).
    typealias ShortcutHandler = (KeyPress) -> Bool

    struct KeyPress: Equatable, Sendable {
        let keyCode: CGKeyCode
        let modifiers: NSEvent.ModifierFlags
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedBox: Unmanaged<EventTapBox>?
    private var onKeyPress: ShortcutHandler?

    var isRunning: Bool { eventTap != nil }

    func start(onKeyPress: @escaping ShortcutHandler) {
        if isRunning {
            self.onKeyPress = onKeyPress
            return
        }

        self.onKeyPress = onKeyPress

        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            let box = Unmanaged<EventTapBox>.fromOpaque(userInfo!).takeUnretainedValue()

            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // macOS disabled the tap (slow callback or user input flood).
                // Re-enable it immediately via the stored CFMachPort.
                logger.warning("Event tap disabled by system (reason: \(type.rawValue)), re-enabling")
                if let tap = box.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)

            case .keyDown:
                let consumed = box.manager.handle(event: event)
                if consumed {
                    // Swallow the event so it doesn't reach the focused app
                    return nil
                }
                return Unmanaged.passUnretained(event)

            default:
                return Unmanaged.passUnretained(event)
            }
        }

        // EventTapBox uses unowned reference to avoid retain cycle:
        // EventTapManager → retainedBox → EventTapBox → manager (unowned)
        // Lifecycle: retainedBox is released in stop(), which always runs
        // before EventTapManager is deallocated.
        let box = EventTapBox(manager: self)
        let retained = Unmanaged.passRetained(box)
        let userInfo = UnsafeMutableRawPointer(retained.toOpaque())

        ShortcutManager.debugLog("tapCreate: AXIsProcessTrusted=\(AXIsProcessTrusted()), CGPreflightListenEventAccess=\(CGPreflightListenEventAccess()), trying .defaultTap")
        var tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: userInfo
        )
        if tap == nil {
            ShortcutManager.debugLog("tapCreate: .defaultTap failed, trying .listenOnly")
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: userInfo
            )
        }
        guard let tap else {
            retained.release()
            ShortcutManager.debugLog("tapCreate: BOTH .defaultTap and .listenOnly failed")
            logger.error("Failed to create CGEvent tap — ensure Accessibility permission is granted in System Settings > Privacy & Security > Accessibility")
            return
        }
        ShortcutManager.debugLog("tapCreate: SUCCESS, tap created")

        retainedBox = retained
        box.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        logger.info("Event tap started")
    }

    func stop() {
        guard isRunning else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        retainedBox?.release()
        retainedBox = nil
        eventTap = nil
        runLoopSource = nil
        onKeyPress = nil
        logger.info("Event tap stopped")
    }

    /// Returns `true` if the key press matched a shortcut and should be consumed.
    private func handle(event: CGEvent) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        return onKeyPress?(KeyPress(keyCode: keyCode, modifiers: flags.intersection(NSEvent.ModifierFlags.deviceIndependentFlagsMask))) ?? false
    }
}

// Boxes the EventTapManager reference for the C callback's userInfo pointer.
// Uses unowned to break the retain cycle with EventTapManager.retainedBox.
// Lifetime is explicitly managed: retained in start(), released in stop().
// Also holds the CFMachPort so the callback can re-enable a disabled tap.
private final class EventTapBox {
    unowned let manager: EventTapManager
    var tap: CFMachPort?

    init(manager: EventTapManager) {
        self.manager = manager
    }
}
