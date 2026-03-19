import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os.log

private let logger = Logger(subsystem: "com.hotappclone", category: "EventTapManager")

@MainActor
final class EventTapManager {
    typealias ShortcutHandler = (KeyPress) -> Void

    struct KeyPress: Equatable {
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
                box.manager.handle(event: event)
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

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: userInfo
        ) else {
            retained.release()
            logger.error("Failed to create CGEvent tap — ensure Input Monitoring permission is granted in System Settings > Privacy & Security")
            return
        }

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

    private func handle(event: CGEvent) {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        onKeyPress?(KeyPress(keyCode: keyCode, modifiers: flags.intersection(NSEvent.ModifierFlags.deviceIndependentFlagsMask)))
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
