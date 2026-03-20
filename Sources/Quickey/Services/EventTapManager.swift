import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "EventTapManager")

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
    private var backgroundThread: BackgroundRunLoopThread?

    /// Debounce: minimum interval between triggers for the same shortcut (seconds).
    private let debounceInterval: TimeInterval = 0.2  // 200ms
    private var lastTriggerTime: CFAbsoluteTime = 0
    private var lastTriggerKeyPress: KeyPress?

    var isRunning: Bool { eventTap != nil }

    func start(onKeyPress: @escaping ShortcutHandler) {
        if isRunning {
            self.onKeyPress = onKeyPress
            return
        }

        self.onKeyPress = onKeyPress

        // Create dedicated background thread for the event tap RunLoop
        let thread = BackgroundRunLoopThread()
        thread.start()
        backgroundThread = thread

        let mask = (1 << CGEventType.keyDown.rawValue)
                  | (1 << CGEventType.keyUp.rawValue)
                  | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            let box = Unmanaged<EventTapBox>.fromOpaque(userInfo!).takeUnretainedValue()

            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                logger.warning("EVENT TAP DISABLED by system (reason: \(type.rawValue)), re-enabling")
                DiagnosticLog.log("EVENT TAP DISABLED by system (reason: \(type.rawValue)), re-enabling")
                if let tap = box.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)

            case .keyDown:
                // Minimal work in callback: extract key info, filter autorepeat, then async dispatch
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                    return Unmanaged.passUnretained(event)
                }
                let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

                // Hyper Key: intercept F19 keyDown → mark held, swallow event
                if box.hyperKeyEnabled && keyCode == HyperKeyService.f19KeyCode {
                    box.isHyperHeld = true
                    return nil
                }

                // Hyper Key: inject ⌃⌥⇧⌘ into the event when Hyper is held
                if box.isHyperHeld {
                    event.flags = event.flags.union([.maskControl, .maskAlternate, .maskShift, .maskCommand])
                }

                let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
                let keyPress = KeyPress(
                    keyCode: keyCode,
                    modifiers: flags.intersection(.deviceIndependentFlagsMask)
                )

                // Dispatch to main thread for handling (AX calls, SkyLight, etc.)
                DispatchQueue.main.async {
                    box.manager.handleAsync(keyPress)
                }

                // For defaultTap mode: check if this key+modifier combo is registered
                // We must decide synchronously whether to swallow the event.
                // Use the box's registered shortcuts set for a fast O(1) lookup.
                if box.registeredShortcuts.contains(keyPress) {
                    return nil  // swallow the event
                }
                return Unmanaged.passUnretained(event)

            case .keyUp:
                // Hyper Key: intercept F19 keyUp → clear held state, swallow event
                if box.hyperKeyEnabled {
                    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                    if keyCode == HyperKeyService.f19KeyCode {
                        box.isHyperHeld = false
                        return nil
                    }
                }
                return Unmanaged.passUnretained(event)

            case .flagsChanged:
                return Unmanaged.passUnretained(event)

            default:
                return Unmanaged.passUnretained(event)
            }
        }

        let box = EventTapBox(manager: self)
        // Pre-populate registered shortcuts for synchronous swallow decision
        box.registeredShortcuts = registeredKeyPresses
        let retained = Unmanaged.passRetained(box)
        let userInfo = UnsafeMutableRawPointer(retained.toOpaque())

        #if DEBUG
        logger.debug("tapCreate: AXIsProcessTrusted=\(AXIsProcessTrusted()), CGPreflightListenEventAccess=\(CGPreflightListenEventAccess()), trying .defaultTap")
        #endif
        var tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: userInfo
        )
        if tap == nil {
            logger.info("tapCreate: .defaultTap failed, trying .listenOnly")
            DiagnosticLog.log("tapCreate: .defaultTap failed, trying .listenOnly")
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
            backgroundThread?.cancel()
            backgroundThread = nil
            logger.error("tapCreate: BOTH .defaultTap and .listenOnly failed — ensure Accessibility permission is granted in System Settings > Privacy & Security > Accessibility")
            DiagnosticLog.log("tapCreate: BOTH .defaultTap and .listenOnly failed")
            return
        }
        logger.info("tapCreate: SUCCESS, tap created")
        DiagnosticLog.log("tapCreate: SUCCESS, tap created")

        retainedBox = retained
        box.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        // Add source to background thread's RunLoop instead of main RunLoop
        thread.addSource(source!)

        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        logger.info("Event tap started (background thread)")
        DiagnosticLog.log("Event tap started (background thread)")
    }

    func stop() {
        guard isRunning else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let thread = backgroundThread {
            thread.removeSource(source)
        }
        backgroundThread?.cancel()
        backgroundThread = nil
        retainedBox?.release()
        retainedBox = nil
        eventTap = nil
        runLoopSource = nil
        onKeyPress = nil
        lastTriggerTime = 0
        lastTriggerKeyPress = nil
        logger.info("Event tap stopped")
        DiagnosticLog.log("Event tap stopped")
    }

    /// Update the set of registered shortcuts for synchronous event swallowing.
    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {
        registeredKeyPresses = keyPresses
        if let box = retainedBox?.takeUnretainedValue() {
            box.registeredShortcuts = keyPresses
        }
    }

    private var registeredKeyPresses: Set<KeyPress> = []

    /// Enable or disable Hyper Key (F19) interception in the event tap callback.
    func setHyperKeyEnabled(_ enabled: Bool) {
        if let box = retainedBox?.takeUnretainedValue() {
            box.hyperKeyEnabled = enabled
            if !enabled { box.isHyperHeld = false }
        }
    }

    /// Called on main thread from async dispatch. Applies debounce then calls handler.
    private func handleAsync(_ keyPress: KeyPress) {
        let now = CFAbsoluteTimeGetCurrent()

        // Debounce: skip if same key press within debounceInterval
        if keyPress == lastTriggerKeyPress,
           now - lastTriggerTime < debounceInterval {
            #if DEBUG
            logger.debug("Debounce: skipping duplicate keyPress within \(self.debounceInterval)s")
            #endif
            return
        }

        lastTriggerTime = now
        lastTriggerKeyPress = keyPress

        _ = onKeyPress?(keyPress)
    }
}

// MARK: - KeyPress Hashable conformance for Set lookup

extension EventTapManager.KeyPress: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }
}

// MARK: - Background RunLoop Thread

/// Dedicated thread with its own RunLoop for hosting the CGEvent tap.
/// Keeps the tap responsive even if the main thread is busy with UI work.
private final class BackgroundRunLoopThread: Thread {
    private var threadRunLoop: CFRunLoop?
    private let runLoopReady = DispatchSemaphore(value: 0)

    override func main() {
        threadRunLoop = CFRunLoopGetCurrent()
        runLoopReady.signal()
        // Keep the run loop alive with a dummy source
        let context = CFRunLoopSourceContext()
        var mutableContext = context
        let dummySource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &mutableContext)
        CFRunLoopAddSource(threadRunLoop, dummySource, .commonModes)
        CFRunLoopRun()
    }

    func addSource(_ source: CFRunLoopSource) {
        runLoopReady.wait()
        CFRunLoopAddSource(threadRunLoop, source, .commonModes)
        CFRunLoopWakeUp(threadRunLoop!)
    }

    func removeSource(_ source: CFRunLoopSource) {
        guard let rl = threadRunLoop else { return }
        CFRunLoopRemoveSource(rl, source, .commonModes)
    }

    override func cancel() {
        super.cancel()
        if let rl = threadRunLoop {
            CFRunLoopStop(rl)
        }
    }
}

// Boxes the EventTapManager reference for the C callback's userInfo pointer.
// Uses unowned to break the retain cycle with EventTapManager.retainedBox.
// Lifetime is explicitly managed: retained in start(), released in stop().
// Also holds the CFMachPort so the callback can re-enable a disabled tap.
private final class EventTapBox {
    unowned let manager: EventTapManager
    var tap: CFMachPort?
    /// Set of registered key presses for synchronous swallow decisions in the callback.
    var registeredShortcuts: Set<EventTapManager.KeyPress> = []
    /// Whether Hyper Key (Caps Lock → F19) interception is active.
    var hyperKeyEnabled: Bool = false
    /// Whether the Hyper Key (F19) is currently held down.
    var isHyperHeld: Bool = false

    init(manager: EventTapManager) {
        self.manager = manager
    }
}
