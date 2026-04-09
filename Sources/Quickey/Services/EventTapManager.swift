import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "EventTapManager")

private extension CGEventFlags {
    /// Strips the Caps Lock toggle bit that leaks through hidutil remapping.
    var strippingCapsLock: CGEventFlags {
        var f = self; f.remove(.maskAlphaShift); return f
    }
}

/// Caps Lock hardware may fire keyDown+keyUp within this window on a single
/// physical press (toggle quirk). Nanoseconds (CGEvent.timestamp unit, per CGEventTypes.h).
private let hyperKeyToggleQuirkThresholdNs: UInt64 = 80_000_000

struct EventTapDiagnosticsSnapshot: Equatable, Sendable {
    let reason: CGEventType
    let disableCount: Int
    let lastEventType: CGEventType?
    let lastKeyCode: CGKeyCode?
    let lastModifierFlags: UInt
    let lastShortcutWasSwallowed: Bool
    let lastHyperInjected: Bool
    let registeredShortcutCount: Int
    let hyperKeyEnabled: Bool
    let hyperKeyHeld: Bool

    var logMessage: String {
        let lastEvent = lastEventType.map { String($0.rawValue) } ?? "nil"
        let lastKey = lastKeyCode.map { String($0) } ?? "nil"
        return "EVENT TAP DIAGNOSTICS: reason=\(reason.rawValue), disableCount=\(disableCount), lastEvent=\(lastEvent), lastKeyCode=\(lastKey), lastModifiers=\(lastModifierFlags), lastShortcutWasSwallowed=\(lastShortcutWasSwallowed), lastHyperInjected=\(lastHyperInjected), registeredShortcutCount=\(registeredShortcutCount), hyperKeyEnabled=\(hyperKeyEnabled), hyperKeyHeld=\(hyperKeyHeld)"
    }
}

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
        let diagnosticSnapshot = box.captureDisableSnapshot(reason: type)
        logger.warning("EVENT TAP DISABLED by system (reason: \(type.rawValue), count: \(diagnosticSnapshot.disableCount)), re-enabling")
        box.onTapDisabled?(diagnosticSnapshot)

        box.reenableTapIfNeeded()

        if type == .tapDisabledByTimeout {
            let threadName = Thread.current.name ?? "bg-runloop"
            let now = CFAbsoluteTimeGetCurrent()
            let (action, lifecycleSnapshot) = box.recordTimeoutAndDecide(at: now, threadIdentity: threadName)

            if action == .fullRecreation || action == .markDegraded {
                box.onRecoveryNeeded?(action, lifecycleSnapshot)
            }
        }
        return Unmanaged.passUnretained(event)

    case .keyDown:
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isAutorepeat {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let eventTimestamp = event.timestamp

        let (swallow, injectHyper) = box.withLock { () -> (Bool, Bool) in
            if box._hyperKeyEnabled && keyCode == HyperKeyService.f19KeyCode {
                box._isHyperHeld = true
                box._hyperKeyDownTimestamp = eventTimestamp
                box._f19ReceivedViaKeyDown = true
                return (true, false)
            }
            let hyper = box._isHyperHeld

            var currentFlags = event.flags.strippingCapsLock
            if hyper {
                currentFlags = currentFlags.union([.maskControl, .maskAlternate, .maskShift, .maskCommand])
            }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(currentFlags.rawValue))
            let keyPress = KeyPress(
                keyCode: keyCode,
                modifiers: KeyMatcher.normalizedFlags(from: flags)
            )
            let shouldSwallow = box._registeredShortcuts.contains(keyPress)
            // Clear deferred keyUp state on any non-F19 keyDown. The current
            // keystroke still sees hyper=true (captured above), but subsequent
            // keystrokes will not have Hyper injected.
            if hyper && box._hyperKeyUpDeferred {
                box._isHyperHeld = false
                box._hyperKeyUpDeferred = false
            }
            return (shouldSwallow, hyper)
        }

        #if DEBUG
        // Near-miss diagnostic: log when keyCode matches a registered shortcut
        // but modifiers differ (e.g. spurious numericPad/help/undocumented bits).
        if !swallow && !injectHyper {
            let rawFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let rawDeviceIndep = rawFlags.intersection(.deviceIndependentFlagsMask).rawValue
            let normalized = KeyMatcher.normalizedFlags(from: rawFlags).rawValue
            if rawDeviceIndep != normalized {
                let hasKeyCodeMatch = box.withLock {
                    box._registeredShortcuts.contains { $0.keyCode == keyCode }
                }
                if hasKeyCodeMatch {
                    DispatchQueue.global(qos: .utility).async {
                        DiagnosticLog.log("NEAR_MISS: keyCode=\(keyCode) rawDeviceIndep=\(rawDeviceIndep) normalized=\(normalized) delta=\(rawDeviceIndep ^ normalized)")
                    }
                }
            }
        }
        #endif

        if swallow && keyCode == HyperKeyService.f19KeyCode {
            let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            box.recordObservedEvent(
                type: .keyDown,
                keyCode: keyCode,
                modifierFlags: KeyMatcher.normalizedFlags(from: modifierFlags),
                swallowed: true,
                injectedHyper: false
            )
            DispatchQueue.global(qos: .utility).async {
                DiagnosticLog.log("HYPER_F19_DOWN: keyCode=\(keyCode) flags=\(modifierFlags.rawValue) ts=\(eventTimestamp)")
            }
            return nil
        }

        if injectHyper {
            event.flags = event.flags.strippingCapsLock
                .union([.maskControl, .maskAlternate, .maskShift, .maskCommand])
            let resultFlags = event.flags.rawValue
            DispatchQueue.global(qos: .utility).async {
                DiagnosticLog.log("HYPER_INJECT: keyCode=\(keyCode) resultFlags=\(resultFlags) matched=\(swallow)")
            }
        }

        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let keyPress = KeyPress(
            keyCode: keyCode,
            modifiers: KeyMatcher.normalizedFlags(from: flags)
        )
        box.recordObservedEvent(
            type: .keyDown,
            keyCode: keyCode,
            modifierFlags: keyPress.modifiers,
            swallowed: swallow,
            injectedHyper: injectHyper
        )

        if swallow {
            let seq = box.incrementAndGetSwallowSequence()
            DispatchQueue.global(qos: .utility).async {
                DiagnosticLog.log(
                    eventTapSwallowLogMessage(
                        seq: seq,
                        keyCode: keyCode,
                        modifiers: keyPress.modifiers,
                        eventTimestamp: eventTimestamp,
                        isAutorepeat: isAutorepeat,
                        hyperInjected: injectHyper
                    )
                )
            }
            box.onKeyPress?(keyPress)
            return nil
        }
        return Unmanaged.passUnretained(event)

    case .keyUp:
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let swallowUp = box.withLock { () -> Bool in
            if box._hyperKeyEnabled && keyCode == HyperKeyService.f19KeyCode {
                // Caps Lock hardware may generate instant keyDown+keyUp on a single
                // physical press (toggle quirk). If keyUp arrives within 80ms of
                // keyDown, keep _isHyperHeld true — it will be cleared when the next
                // non-F19 keyDown is processed or by a later "real" keyUp.
                let elapsed = event.timestamp - box._hyperKeyDownTimestamp
                if elapsed > hyperKeyToggleQuirkThresholdNs {
                    box._isHyperHeld = false
                    box._hyperKeyUpDeferred = false
                } else {
                    box._hyperKeyUpDeferred = true
                }
                return true
            }
            return false
        }
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        if swallowUp {
            let elapsed = event.timestamp - box.withLock({ box._hyperKeyDownTimestamp })
            let deferred = box.withLock({ box._hyperKeyUpDeferred })
            DispatchQueue.global(qos: .utility).async {
                DiagnosticLog.log("HYPER_F19_UP: keyCode=\(keyCode) elapsed=\(elapsed) deferred=\(deferred)")
            }
        }
        box.recordObservedEvent(
            type: .keyUp,
            keyCode: keyCode,
            modifierFlags: KeyMatcher.normalizedFlags(from: modifierFlags),
            swallowed: swallowUp,
            injectedHyper: false
        )
        return swallowUp ? nil : Unmanaged.passUnretained(event)

    case .flagsChanged:
        // Caps Lock remapped to F19 via hidutil may still generate flagsChanged
        // instead of keyDown/keyUp on some macOS versions. Handle it here so the
        // Hyper key works regardless of which event type the system produces.
        let flagsKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flagsRaw = KeyMatcher.normalizedFlags(
            from: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        )
        let hasCapsLock = event.flags.contains(.maskAlphaShift)
        let swallowFlags = box.withLock { () -> Bool in
            guard box._hyperKeyEnabled && flagsKeyCode == HyperKeyService.f19KeyCode else {
                return false
            }
            // If the keyDown/keyUp path has already handled F19, defer to that
            // path to avoid double-toggling _isHyperHeld.
            if box._f19ReceivedViaKeyDown {
                return true
            }
            // Detect press vs release by observing the capsLock flag TRANSITION,
            // not its absolute value. This handles the case where Caps Lock was
            // already toggled ON before Hyper was enabled (which would invert
            // the absolute flag semantics).
            let changed = hasCapsLock != box._prevCapsLockFlag
            box._prevCapsLockFlag = hasCapsLock
            if changed {
                box._isHyperHeld = !box._isHyperHeld
            }
            return true
        }
        if swallowFlags {
            box.recordObservedEvent(
                type: .flagsChanged,
                keyCode: flagsKeyCode,
                modifierFlags: flagsRaw,
                swallowed: true,
                injectedHyper: false
            )
            DispatchQueue.global(qos: .utility).async {
                DiagnosticLog.log("HYPER_FLAGS_CHANGED: keyCode=\(flagsKeyCode) held=\(hasCapsLock)")
            }
            return nil
        }
        box.recordObservedEvent(
            type: .flagsChanged,
            keyCode: flagsKeyCode,
            modifierFlags: flagsRaw,
            swallowed: false,
            injectedHyper: false
        )
        return Unmanaged.passUnretained(event)

    default:
        return Unmanaged.passUnretained(event)
    }
}

func eventTapSwallowLogMessage(
    seq: Int,
    keyCode: CGKeyCode,
    modifiers: NSEvent.ModifierFlags,
    eventTimestamp: UInt64,
    isAutorepeat: Bool,
    hyperInjected: Bool
) -> String {
    "EVENT_TAP_SWALLOW: seq=\(seq) keyCode=\(keyCode) modifiers=\(modifiers.rawValue) eventTimestamp=\(eventTimestamp) autorepeat=\(isAutorepeat) hyperInjected=\(hyperInjected)"
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
    private let debounceInterval: TimeInterval = 0.2  // safety net behind Layer 1 autorepeat filter
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
        box.onTapDisabled = { snapshot in
            DispatchQueue.global(qos: .utility).async {
                DiagnosticLog.log(snapshot.logMessage)
            }
        }
        box.onRecoveryNeeded = { [weak self] action, lifecycleSnapshot in
            Task { @MainActor in
                self?.handleRecoveryAction(action, snapshot: lifecycleSnapshot)
            }
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
        emitLifecycleLog("EVENT_TAP_STARTED")
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
            let elapsed = Int((now - lastTriggerTime) * 1000)
            DiagnosticLog.log("DEBOUNCE_BLOCKED: keyCode=\(keyPress.keyCode) elapsedMs=\(elapsed) limit=\(Int(debounceInterval * 1000))ms")
            return
        }

        let elapsed = lastTriggerTime > 0 ? Int((now - lastTriggerTime) * 1000) : -1
        DiagnosticLog.log("DEBOUNCE_PASSED: keyCode=\(keyPress.keyCode) elapsedMs=\(elapsed) sameKey=\(keyPress == lastTriggerKeyPress)")

        lastTriggerTime = now
        lastTriggerKeyPress = keyPress

        _ = onKeyPress?(keyPress)
    }

    // MARK: - Lifecycle recovery

    private func handleRecoveryAction(_ action: EventTapRecoveryAction, snapshot: EventTapLifecycleSnapshot) {
        switch action {
        case .reenableInPlace:
            emitLifecycleLog("EVENT_TAP_REENABLED", snapshot: snapshot)
        case .fullRecreation:
            recreateEventTap()
        case .markDegraded:
            // The decision was already recorded by the box's tracker in the
            // callback; just emit the log with the snapshot that was captured.
            emitLifecycleLog("EVENT_TAP_DEGRADED", snapshot: snapshot)
        }
    }

    /// Record a recreation failure through the box, emit logs, and escalate to
    /// degraded if the threshold is reached.
    private func recordRecreationFailure() {
        guard let box = retainedBox?.takeUnretainedValue() else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let (action, snapshot) = box.recordRecreationFailureAndSnapshot(at: now, threadIdentity: "main")
        emitLifecycleLog("EVENT_TAP_RECREATION_FAILED", snapshot: snapshot)
        if action == .markDegraded {
            emitLifecycleLog("EVENT_TAP_DEGRADED", snapshot: snapshot)
        }
    }

    /// Tear down and recreate the event tap on the existing background thread.
    /// Follows ordered sequence: remove source → disable/invalidate → release
    /// → create new tap → create new source → add source → enable.
    private func recreateEventTap() {
        guard let thread = backgroundThread else { return }

        if let source = runLoopSource {
            thread.removeSource(source)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
        // retainedBox is kept alive — the box is reused across recreation

        let mask = (1 << CGEventType.keyDown.rawValue)
                  | (1 << CGEventType.keyUp.rawValue)
                  | (1 << CGEventType.flagsChanged.rawValue)

        guard let box = retainedBox?.takeUnretainedValue() else {
            recordRecreationFailure()
            return
        }
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(box).toOpaque())

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: userInfo
        ) else {
            recordRecreationFailure()
            return
        }

        box.tap = newTap

        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            recordRecreationFailure()
            return
        }

        thread.addSource(newSource)
        CGEvent.tapEnable(tap: newTap, enable: true)

        eventTap = newTap
        runLoopSource = newSource

        let now = CFAbsoluteTimeGetCurrent()
        let snapshot = box.recordRecreationSuccessAndSnapshot(at: now, threadIdentity: "bg-runloop")
        emitLifecycleLog("EVENT_TAP_RECREATED", snapshot: snapshot)
    }

    private func emitLifecycleLog(_ event: String, snapshot: EventTapLifecycleSnapshot? = nil) {
        let resolvedSnapshot: EventTapLifecycleSnapshot
        if let snapshot = snapshot {
            resolvedSnapshot = snapshot
        } else if let box = retainedBox?.takeUnretainedValue() {
            resolvedSnapshot = box.captureLifecycleSnapshot(at: CFAbsoluteTimeGetCurrent(), threadIdentity: "main")
        } else {
            return
        }
        let entry = EventTapLifecycleLogEntry(event: event, snapshot: resolvedSnapshot)
        logger.info("\(entry.logMessage)")
        DispatchQueue.global(qos: .utility).async {
            DiagnosticLog.log(entry.logMessage)
        }
    }
}

// MARK: - Background RunLoop Thread

/// Dedicated thread with its own RunLoop for hosting the CGEvent tap.
/// Keeps the tap responsive even if the main thread is busy with UI work.
/// Uses an NSCondition-based readiness mechanism instead of a one-shot semaphore
/// so that the same thread supports repeated add/remove/recreate cycles.
private final class BackgroundRunLoopThread: Thread {
    private var threadRunLoop: CFRunLoop?
    private let readyCondition = NSCondition()
    private var isReady = false

    override func main() {
        readyCondition.lock()
        threadRunLoop = CFRunLoopGetCurrent()
        isReady = true
        readyCondition.broadcast()
        readyCondition.unlock()
        // Keep the run loop alive with a dummy source
        let context = CFRunLoopSourceContext()
        var mutableContext = context
        let dummySource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &mutableContext)
        CFRunLoopAddSource(threadRunLoop, dummySource, .commonModes)
        CFRunLoopRun()
    }

    /// Wait for the run loop to become ready and return it.
    /// Safe to call repeatedly — returns immediately after the first readiness signal.
    var runLoop: CFRunLoop? {
        readyCondition.lock()
        defer { readyCondition.unlock() }
        while !isReady {
            readyCondition.wait()
        }
        return threadRunLoop
    }

    func addSource(_ source: CFRunLoopSource) {
        guard let rl = runLoop else { return }
        CFRunLoopAddSource(rl, source, .commonModes)
        CFRunLoopWakeUp(rl)
    }

    func removeSource(_ source: CFRunLoopSource) {
        guard let rl = runLoop else { return }
        CFRunLoopRemoveSource(rl, source, .commonModes)
    }

    override func cancel() {
        super.cancel()
        readyCondition.lock()
        let rl = threadRunLoop
        readyCondition.unlock()
        if let rl = rl {
            CFRunLoopStop(rl)
        }
    }
}

// MARK: - Event Tap Lifecycle Tracker

enum EventTapLifecycleState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case disabledBySystem
    case recovering
    case degraded
}

enum EventTapRecoveryAction: Equatable, Sendable {
    case reenableInPlace
    case fullRecreation
    case markDegraded
}

struct EventTapLifecycleSnapshot: Equatable, Sendable {
    let rollingTimeoutCount: Int
    let recreationFailureCount: Int
    let timeSinceLastTimeout: CFAbsoluteTime?
    let lifecycleState: EventTapLifecycleState
    let recoveryMode: String
    let threadIdentity: String
    let readinessState: String
}

struct EventTapLifecycleLogEntry: Equatable, Sendable {
    let event: String
    let snapshot: EventTapLifecycleSnapshot

    var logMessage: String {
        var parts = [event]
        parts.append("rollingTimeoutCount=\(snapshot.rollingTimeoutCount)")
        if let elapsed = snapshot.timeSinceLastTimeout {
            parts.append("timeSinceLastTimeout=\(String(format: "%.3f", elapsed))s")
        } else {
            parts.append("timeSinceLastTimeout=nil")
        }
        parts.append("recoveryMode=\(snapshot.recoveryMode)")
        parts.append("threadIdentity=\(snapshot.threadIdentity)")
        parts.append("readinessState=\(snapshot.readinessState)")
        return parts.joined(separator: " ")
    }
}

struct EventTapLifecycleTracker: Sendable {
    private(set) var lifecycleState: EventTapLifecycleState = .running
    private(set) var rollingTimeoutCount: Int = 0
    private(set) var recreationFailureCount: Int = 0

    private var firstTimeoutInWindow: CFAbsoluteTime?
    private var lastTimeoutTime: CFAbsoluteTime?
    private var firstRecreationFailureInWindow: CFAbsoluteTime?
    private var lastRecoveryMode: String = "none"

    static let timeoutsBeforeRecreation = 3
    static let timeoutWindowSeconds: CFAbsoluteTime = 30
    static let recreationFailuresBeforeDegraded = 2
    static let recreationWindowSeconds: CFAbsoluteTime = 120

    mutating func recordTimeout(at now: CFAbsoluteTime) -> EventTapRecoveryAction {
        // Reset window if expired
        if let firstTime = firstTimeoutInWindow, now - firstTime > Self.timeoutWindowSeconds {
            rollingTimeoutCount = 0
            firstTimeoutInWindow = nil
        }

        rollingTimeoutCount += 1
        lastTimeoutTime = now
        if firstTimeoutInWindow == nil { firstTimeoutInWindow = now }

        if rollingTimeoutCount >= Self.timeoutsBeforeRecreation {
            lifecycleState = .recovering
            lastRecoveryMode = "recreated"
            return .fullRecreation
        }

        lifecycleState = .disabledBySystem
        lastRecoveryMode = "in_place"
        return .reenableInPlace
    }

    mutating func recordRecreationSuccess(at now: CFAbsoluteTime) {
        rollingTimeoutCount = 0
        firstTimeoutInWindow = nil
        recreationFailureCount = 0
        firstRecreationFailureInWindow = nil
        lifecycleState = .running
        lastRecoveryMode = "recreated"
    }

    @discardableResult
    mutating func recordRecreationFailure(at now: CFAbsoluteTime) -> EventTapRecoveryAction {
        // Reset failure window if expired
        if let firstTime = firstRecreationFailureInWindow, now - firstTime > Self.recreationWindowSeconds {
            recreationFailureCount = 0
            firstRecreationFailureInWindow = nil
        }

        recreationFailureCount += 1
        if firstRecreationFailureInWindow == nil { firstRecreationFailureInWindow = now }

        if recreationFailureCount >= Self.recreationFailuresBeforeDegraded {
            lifecycleState = .degraded
            return .markDegraded
        }

        return .fullRecreation
    }

    func captureSnapshot(at now: CFAbsoluteTime, threadIdentity: String) -> EventTapLifecycleSnapshot {
        let timeSince: CFAbsoluteTime? = lastTimeoutTime.map { now - $0 }
        let readiness: String
        switch lifecycleState {
        case .running: readiness = "ready"
        case .degraded: readiness = "degraded"
        case .recovering: readiness = "recovering"
        case .disabledBySystem: readiness = "disabled"
        case .stopped: readiness = "stopped"
        case .starting: readiness = "starting"
        }
        return EventTapLifecycleSnapshot(
            rollingTimeoutCount: rollingTimeoutCount,
            recreationFailureCount: recreationFailureCount,
            timeSinceLastTimeout: timeSince,
            lifecycleState: lifecycleState,
            recoveryMode: lastRecoveryMode,
            threadIdentity: threadIdentity,
            readinessState: readiness
        )
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
    /// Background-safe closure for asynchronous timeout diagnostics.
    var onTapDisabled: (@Sendable (EventTapDiagnosticsSnapshot) -> Void)?
    /// Background-safe closure dispatched when the lifecycle tracker decides
    /// recreation or degraded handling is needed. Must not block the callback.
    var onRecoveryNeeded: (@Sendable (EventTapRecoveryAction, EventTapLifecycleSnapshot) -> Void)?

    // MARK: - Lock-protected shared state

    private var lock = os_unfair_lock()
    // fileprivate so the C callback (defined in EventTapManager.start) can
    // access them inside withLock critical sections.
    fileprivate var _registeredShortcuts: Set<KeyPress> = []
    fileprivate var _hyperKeyEnabled: Bool = false
    fileprivate var _isHyperHeld: Bool = false
    /// CGEvent.timestamp (nanoseconds since startup) of the most recent F19
    /// keyDown, used to detect Caps Lock's instant keyDown+keyUp toggle quirk.
    fileprivate var _hyperKeyDownTimestamp: UInt64 = 0
    /// When true, an instant F19 keyUp was ignored; the next non-F19 keyDown
    /// should clear _isHyperHeld regardless of whether the combo is registered.
    fileprivate var _hyperKeyUpDeferred: Bool = false
    /// True once F19 has been received via keyDown; prevents the flagsChanged
    /// handler from double-toggling _isHyperHeld.
    fileprivate var _f19ReceivedViaKeyDown: Bool = false
    /// Tracks the last observed capsLock flag state so the flagsChanged handler
    /// can detect transitions (edge) rather than relying on absolute level.
    fileprivate var _prevCapsLockFlag: Bool = false
    fileprivate var _disableCount: Int = 0
    fileprivate var _lastEventType: CGEventType?
    fileprivate var _lastKeyCode: CGKeyCode?
    fileprivate var _lastModifierFlags: UInt = 0
    fileprivate var _lastShortcutWasSwallowed: Bool = false
    fileprivate var _lastHyperInjected: Bool = false
    fileprivate var _lifecycleTracker = EventTapLifecycleTracker()

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
            if !enabled {
                _isHyperHeld = false
                _hyperKeyUpDeferred = false
                _hyperKeyDownTimestamp = 0
                _f19ReceivedViaKeyDown = false
            }
            _prevCapsLockFlag = false
        }
    }

    func recordObservedEvent(
        type: CGEventType,
        keyCode: CGKeyCode?,
        modifierFlags: NSEvent.ModifierFlags,
        swallowed: Bool,
        injectedHyper: Bool
    ) {
        withLock {
            _lastEventType = type
            _lastKeyCode = keyCode
            _lastModifierFlags = modifierFlags.rawValue
            _lastShortcutWasSwallowed = swallowed
            _lastHyperInjected = injectedHyper
        }
    }

    func captureDisableSnapshot(reason: CGEventType) -> EventTapDiagnosticsSnapshot {
        withLock {
            _disableCount += 1
            return EventTapDiagnosticsSnapshot(
                reason: reason,
                disableCount: _disableCount,
                lastEventType: _lastEventType,
                lastKeyCode: _lastKeyCode,
                lastModifierFlags: _lastModifierFlags,
                lastShortcutWasSwallowed: _lastShortcutWasSwallowed,
                lastHyperInjected: _lastHyperInjected,
                registeredShortcutCount: _registeredShortcuts.count,
                hyperKeyEnabled: _hyperKeyEnabled,
                hyperKeyHeld: _isHyperHeld
            )
        }
    }

    /// Re-enable the tap using the custom closure or the tap reference directly.
    func reenableTapIfNeeded() {
        if let reenableTap = reenableTap {
            reenableTap()
        } else if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Record a timeout event and return the recovery action decided by the
    /// lifecycle tracker. Safe to call from the callback thread under the lock.
    func recordTimeoutAndDecide(at now: CFAbsoluteTime, threadIdentity: String) -> (EventTapRecoveryAction, EventTapLifecycleSnapshot) {
        withLock {
            let action = _lifecycleTracker.recordTimeout(at: now)
            let snapshot = _lifecycleTracker.captureSnapshot(at: now, threadIdentity: threadIdentity)
            return (action, snapshot)
        }
    }

    /// Record a recreation failure and return a snapshot. Thread-safe.
    func recordRecreationFailureAndSnapshot(at now: CFAbsoluteTime, threadIdentity: String) -> (EventTapRecoveryAction, EventTapLifecycleSnapshot) {
        withLock {
            let action = _lifecycleTracker.recordRecreationFailure(at: now)
            let snapshot = _lifecycleTracker.captureSnapshot(at: now, threadIdentity: threadIdentity)
            return (action, snapshot)
        }
    }

    /// Record a successful recreation. Thread-safe.
    func recordRecreationSuccessAndSnapshot(at now: CFAbsoluteTime, threadIdentity: String) -> EventTapLifecycleSnapshot {
        withLock {
            _lifecycleTracker.recordRecreationSuccess(at: now)
            return _lifecycleTracker.captureSnapshot(at: now, threadIdentity: threadIdentity)
        }
    }

    /// Capture a lifecycle snapshot without mutating state. Thread-safe.
    func captureLifecycleSnapshot(at now: CFAbsoluteTime, threadIdentity: String) -> EventTapLifecycleSnapshot {
        withLock {
            _lifecycleTracker.captureSnapshot(at: now, threadIdentity: threadIdentity)
        }
    }

    fileprivate var _swallowSequence: Int = 0

    /// Atomically increment and return a swallow sequence number for diagnostics.
    func incrementAndGetSwallowSequence() -> Int {
        withLock {
            _swallowSequence += 1
            return _swallowSequence
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
