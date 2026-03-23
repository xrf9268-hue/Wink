import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "EventTapManager")

enum MatchedShortcutDelivery {
    static func makeHandler(
        _ handler: @escaping @MainActor @Sendable (KeyPress) -> Void
    ) -> @Sendable (KeyPress) -> Void {
        { keyPress in
            Task { @MainActor in
                handler(keyPress)
            }
        }
    }
}

@discardableResult
func handleEventTapEvent(
    type: CGEventType,
    event: CGEvent,
    box: EventTapBox
) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        logger.warning("EVENT TAP DISABLED by system (reason: \(type.rawValue)), re-enabling")
        DiagnosticLog.log("EVENT TAP DISABLED by system (reason: \(type.rawValue)), re-enabling")
        if let reenableTap = box.reenableTap {
            reenableTap()
        } else if let tap = box.tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)

    case .keyDown:
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        let (swallow, injectHyper) = box.withLock { () -> (Bool, Bool) in
            if box._hyperKeyEnabled && keyCode == HyperKeyService.f19KeyCode {
                box._isHyperHeld = true
                return (true, false)
            }
            let hyper = box._isHyperHeld

            var currentFlags = event.flags
            if hyper {
                currentFlags = currentFlags.union([.maskControl, .maskAlternate, .maskShift, .maskCommand])
            }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(currentFlags.rawValue))
            let keyPress = KeyPress(
                keyCode: keyCode,
                modifiers: flags.intersection(.deviceIndependentFlagsMask)
            )
            let shouldSwallow = box._registeredShortcuts.contains(keyPress)
            return (shouldSwallow, hyper)
        }

        if swallow && keyCode == HyperKeyService.f19KeyCode {
            return nil
        }

        if injectHyper {
            event.flags = event.flags.union([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        }

        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let keyPress = KeyPress(
            keyCode: keyCode,
            modifiers: flags.intersection(.deviceIndependentFlagsMask)
        )

        if swallow {
            box.onKeyPress?(keyPress)
            return nil
        }
        return Unmanaged.passUnretained(event)

    case .keyUp:
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let swallowUp = box.withLock { () -> Bool in
            if box._hyperKeyEnabled && keyCode == HyperKeyService.f19KeyCode {
                box._isHyperHeld = false
                return true
            }
            return false
        }
        return swallowUp ? nil : Unmanaged.passUnretained(event)

    case .flagsChanged:
        return Unmanaged.passUnretained(event)

    default:
        return Unmanaged.passUnretained(event)
    }
}

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    let box = Unmanaged<EventTapBox>.fromOpaque(userInfo!).takeUnretainedValue()
    return handleEventTapEvent(type: type, event: event, box: box)
}

@MainActor
final class EventTapManager: EventTapManaging {
    /// Returns `true` if the key press was handled and should be consumed (not passed to other apps).
    typealias ShortcutHandler = (KeyPress) -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedBox: Unmanaged<EventTapBox>?
    // internal for @testable access
    var onKeyPress: ShortcutHandler?
    private var backgroundThread: BackgroundRunLoopThread?

    /// Debounce: minimum interval between triggers for the same shortcut (seconds).
    private let debounceInterval: TimeInterval = 0.2  // 200ms
    private var lastTriggerTime: CFAbsoluteTime = 0
    private var lastTriggerKeyPress: KeyPress?

    var isRunning: Bool { eventTap != nil }

    func start(onKeyPress: @escaping ShortcutHandler) -> EventTapStartResult {
        if isRunning {
            self.onKeyPress = onKeyPress
            return .started
        }

        self.onKeyPress = onKeyPress

        // Create dedicated background thread for the event tap RunLoop
        let thread = BackgroundRunLoopThread()
        thread.start()
        backgroundThread = thread

        let mask = (1 << CGEventType.keyDown.rawValue)
                  | (1 << CGEventType.keyUp.rawValue)
                  | (1 << CGEventType.flagsChanged.rawValue)

        let box = EventTapBox()
        box.onKeyPress = MatchedShortcutDelivery.makeHandler { [weak self] keyPress in
            self?.handleAsync(keyPress)
        }
        box.registeredShortcuts = registeredKeyPresses
        let retained = Unmanaged.passRetained(box)
        let userInfo = UnsafeMutableRawPointer(retained.toOpaque())

        #if DEBUG
        logger.debug("tapCreate: AXIsProcessTrusted=\(AXIsProcessTrusted()), CGPreflightListenEventAccess=\(CGPreflightListenEventAccess()), trying .defaultTap")
        #endif
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: userInfo
        ) else {
            retained.release()
            backgroundThread?.cancel()
            backgroundThread = nil
            logger.error("tapCreate: .defaultTap failed — active event tap could not be created")
            DiagnosticLog.log("tapCreate: .defaultTap failed")
            return .failedToCreateTap
        }
        logger.info("tapCreate: SUCCESS, tap created")
        DiagnosticLog.log("tapCreate: SUCCESS, tap created")

        box.tap = tap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            retained.release()
            backgroundThread?.cancel()
            backgroundThread = nil
            logger.error("runLoopSourceCreate: failed for active event tap")
            DiagnosticLog.log("runLoopSourceCreate: failed for active event tap")
            return .failedToCreateTap
        }

        // Add source to background thread's RunLoop instead of main RunLoop
        thread.addSource(source)

        CGEvent.tapEnable(tap: tap, enable: true)

        retainedBox = retained
        eventTap = tap
        runLoopSource = source
        logger.info("Event tap started (background thread)")
        DiagnosticLog.log("Event tap started (background thread)")
        return .started
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
            box.setHyperKey(enabled: enabled)
        }
    }

    /// Called on main thread from async dispatch. Applies debounce then calls handler.
    func handleAsync(_ keyPress: KeyPress) {
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
// Lifetime is explicitly managed: retained in start(), released in stop().
// Also holds the CFMachPort so the callback can re-enable a disabled tap.
//
// Thread safety: `tap` and `onKeyPress` are written before the event tap is
// enabled and only read from the callback — no lock needed.
// `registeredShortcuts`, `hyperKeyEnabled`, and `isHyperHeld` are read from
// the background callback thread and written from the main thread, so they
// are protected by an os_unfair_lock.
final class EventTapBox {
    var tap: CFMachPort?
    var reenableTap: (@Sendable () -> Void)?
    /// Background-safe closure that hops to the main actor before invoking app logic.
    var onKeyPress: (@Sendable (KeyPress) -> Void)?

    // MARK: - Lock-protected shared state

    private var lock = os_unfair_lock()
    // fileprivate so the C callback (defined in EventTapManager.start) can
    // access them inside withLock critical sections.
    fileprivate var _registeredShortcuts: Set<KeyPress> = []
    fileprivate var _hyperKeyEnabled: Bool = false
    fileprivate var _isHyperHeld: Bool = false

    var registeredShortcuts: Set<KeyPress> {
        get { withLock { _registeredShortcuts } }
        set { withLock { _registeredShortcuts = newValue } }
    }
    var hyperKeyEnabled: Bool {
        get { withLock { _hyperKeyEnabled } }
        set { withLock { _hyperKeyEnabled = newValue } }
    }
    var isHyperHeld: Bool {
        get { withLock { _isHyperHeld } }
        set { withLock { _isHyperHeld = newValue } }
    }

    /// Atomically update hyperKeyEnabled and clear isHyperHeld when disabling.
    func setHyperKey(enabled: Bool) {
        withLock {
            _hyperKeyEnabled = enabled
            if !enabled { _isHyperHeld = false }
        }
    }

    /// Execute `body` while holding the lock. Internal so the C callback can
    /// batch multiple reads/writes into a single critical section.
    func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}
