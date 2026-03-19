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

    func start(onKeyPress: @escaping ShortcutHandler) {
        self.onKeyPress = onKeyPress
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard type == .keyDown else {
                return Unmanaged.passUnretained(event)
            }

            let manager = Unmanaged<EventTapBox>.fromOpaque(userInfo!).takeUnretainedValue().manager
            manager.handle(event: event)
            return Unmanaged.passUnretained(event)
        }

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

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
    }

    func stop() {
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
    }

    private func handle(event: CGEvent) {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        onKeyPress?(KeyPress(keyCode: keyCode, modifiers: flags.intersection(NSEvent.ModifierFlags.deviceIndependentFlagsMask)))
    }
}

private final class EventTapBox {
    let manager: EventTapManager

    init(manager: EventTapManager) {
        self.manager = manager
    }

    deinit {
        // intentionally empty; retained by the event tap userInfo lifecycle
    }
}
