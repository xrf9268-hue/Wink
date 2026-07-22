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

/// Hyper (F19) hold-gesture phases observed by the tap callback, delivered
/// off the hot path for display-only consumers (the cheat-sheet HUD). An
/// idle hold emits `began` (repeated on autorepeat — consumers dedupe);
/// a consumed chord or the key release ends the gesture.
enum HyperHoldEvent: Equatable, Sendable {
    case began
    case chordConsumed
    case ended
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
            // Autorepeats pass through unswallowed (pre-existing contract) —
            // except for phased chords: a hold gesture's chord autorepeating
            // into the frontmost app would type into the very window the user
            // is holding to act on. Swallowed with no delivery; the arbiter's
            // in-flight gesture already owns the hold. The isEmpty guard
            // keeps the no-hold-shortcuts hot path at one lock acquisition.
            let repeatKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let swallowAutorepeat = box.withLock { () -> Bool in
                guard !box._phasedChords.isEmpty else { return false }
                var currentFlags = event.flags.strippingCapsLock
                if box._isHyperHeld {
                    currentFlags = currentFlags.union([.maskControl, .maskAlternate, .maskShift, .maskCommand])
                }
                let flags = NSEvent.ModifierFlags(rawValue: UInt(currentFlags.rawValue))
                let keyPress = KeyPress(
                    keyCode: repeatKeyCode,
                    modifiers: KeyMatcher.normalizedFlags(from: flags)
                )
                return box._phasedChords.contains(keyPress)
            }
            if swallowAutorepeat {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let eventTimestamp = event.timestamp

        let (swallow, injectHyper, phased) = box.withLock { () -> (Bool, Bool, Bool) in
            if box._hyperKeyEnabled && keyCode == HyperKeyService.f19KeyCode {
                box._isHyperHeld = true
                box._hyperKeyDownTimestamp = eventTimestamp
                box._f19ReceivedViaKeyDown = true
                return (true, false, false)
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
            let isPhased = shouldSwallow && box._phasedChords.contains(keyPress)
            // Clear deferred keyUp state on any non-F19 keyDown. The current
            // keystroke still sees hyper=true (captured above), but subsequent
            // keystrokes will not have Hyper injected.
            if hyper && box._hyperKeyUpDeferred {
                box._isHyperHeld = false
                box._hyperKeyUpDeferred = false
            }
            return (shouldSwallow, hyper, isPhased)
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
                    box._registeredKeyCodes.contains(keyCode)
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
            box.notifyHyperHoldEvent(.began)
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
            if injectHyper {
                box.notifyHyperHoldEvent(.chordConsumed)
            }
            if phased {
                // Phased chords bypass onKeyPress entirely: both edges travel
                // the FIFO phased channel so an up can never overtake its
                // down, and the 200ms same-chord debounce in handleAsync
                // (keyed on phase-less KeyPress) never eats the up edge.
                box.notifyPhasedKeyEvent(keyPress, .down)
            } else {
                box.onKeyPress?(keyPress)
            }
            return nil
        }
        return Unmanaged.passUnretained(event)

    case .keyUp:
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let (swallowUp, phasedUpKeyPress) = box.withLock { () -> (Bool, KeyPress?) in
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
                return (true, nil)
            }
            guard !box._phasedChords.isEmpty else { return (false, nil) }
            // Stateless recomputation of the chord identity, mirroring the
            // keyDown match (same Hyper-union + normalization). Best-effort by
            // design: releasing modifiers (or F19) before the key changes the
            // identity and the up passes through — the gesture consumer's
            // deadline fallback owns that case. No down/up pairing state is
            // kept because interleaved holds would make it lie.
            var currentFlags = event.flags.strippingCapsLock
            if box._isHyperHeld {
                currentFlags = currentFlags.union([.maskControl, .maskAlternate, .maskShift, .maskCommand])
            }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(currentFlags.rawValue))
            let keyPress = KeyPress(
                keyCode: keyCode,
                modifiers: KeyMatcher.normalizedFlags(from: flags)
            )
            guard box._phasedChords.contains(keyPress) else { return (false, nil) }
            return (true, keyPress)
        }
        if let phasedUpKeyPress {
            box.notifyPhasedKeyEvent(phasedUpKeyPress, .up)
        }
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        if swallowUp {
            let elapsed = event.timestamp - box.withLock({ box._hyperKeyDownTimestamp })
            let deferred = box.withLock({ box._hyperKeyUpDeferred })
            DispatchQueue.global(qos: .utility).async {
                DiagnosticLog.log("HYPER_F19_UP: keyCode=\(keyCode) elapsed=\(elapsed) deferred=\(deferred)")
            }
            // Sent for the 80ms toggle-quirk case too: a tap (not a hold)
            // must cancel the consumer's hold timer.
            box.notifyHyperHoldEvent(.ended)
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
        var flagsHoldTransition: HyperHoldEvent?
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
                // This path performed the hold transition, so it owns the
                // observer notification (the keyDown/keyUp sites never ran).
                flagsHoldTransition = box._isHyperHeld ? .began : .ended
            }
            return true
        }
        if swallowFlags {
            if let flagsHoldTransition {
                box.notifyHyperHoldEvent(flagsHoldTransition)
            }
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
    /// Main-actor bound: delivery already hops to the main actor once in
    /// `MatchedShortcutDelivery`, so the handler runs there directly.
    typealias ShortcutHandler = @MainActor (KeyPress) -> Bool

    private let runtimeFactory: EventTapRuntimeFactory
    /// Stored so every generation's box (start and recovery recreation both
    /// route through `start()`) inherits the observer.
    private var hyperHoldObserver: (@Sendable (HyperHoldEvent) -> Void)?
    #if WINK_EVENT_TAP_FAULT_INJECTION
    private let validationDriver: EventTapFaultInjectionDriver?
    #endif
    private var owner: EventTapOwnedSession?
    private var generationCounter: UInt64 = 0
    private var ownershipLedger = EventTapOwnershipLedger()
    private(set) var lifecycleState: EventTapLifecycleState = .stopped
    // internal for @testable access
    var onKeyPress: ShortcutHandler?

    /// Debounce: minimum interval between triggers for the same shortcut (seconds).
    private let debounceInterval: TimeInterval = 0.2  // safety net behind Layer 1 autorepeat filter
    private var lastTriggerTime: CFAbsoluteTime = 0
    private var lastTriggerKeyPress: KeyPress?

    init(runtimeFactory: EventTapRuntimeFactory? = nil) {
        #if WINK_EVENT_TAP_FAULT_INJECTION
        if let runtimeFactory {
            self.runtimeFactory = runtimeFactory
            validationDriver = nil
        } else if let configuration = EventTapFaultInjectionConfiguration(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            let driver = EventTapFaultInjectionDriver(
                configuration: configuration,
                baseRuntimeFactory: .live
            )
            self.runtimeFactory = driver.runtimeFactory
            validationDriver = driver
        } else {
            self.runtimeFactory = .live
            validationDriver = nil
        }
        #else
        self.runtimeFactory = runtimeFactory ?? .live
        #endif
    }

    var isRunning: Bool {
        lifecycleState == .running
            && owner?.tap != nil
            && owner?.source != nil
            && owner?.thread.isAlive == true
    }

    var ownershipSnapshot: EventTapOwnershipSnapshot {
        ownershipLedger.snapshot(
            generation: owner?.generation ?? generationCounter,
            lifecycleState: lifecycleState,
            owner: owner,
            ready: isRunning
        )
    }

    func start(onKeyPress: @escaping ShortcutHandler) -> EventTapStartResult {
        #if WINK_EVENT_TAP_FAULT_INJECTION
        if validationDriver?.suppressFurtherStarts == true {
            DiagnosticLog.log("EVENT_TAP_FAULT_INJECTION event=post_scenario_restart_blocked")
            return .failedToCreateTap
        }
        #endif

        if isRunning {
            self.onKeyPress = onKeyPress
            return .started
        }

        if owner != nil || lifecycleState != .stopped {
            tearDownOwnedSession(finalState: .stopped, event: "start_preflight_teardown")
        }

        self.onKeyPress = onKeyPress

        generationCounter &+= 1
        let generation = generationCounter
        lifecycleState = .starting

        // Create dedicated background thread for the event tap RunLoop
        let thread = runtimeFactory.makeThread(generation)
        ownershipLedger.threadCreates += 1
        thread.start()

        let mask = (1 << CGEventType.keyDown.rawValue)
                  | (1 << CGEventType.keyUp.rawValue)
                  | (1 << CGEventType.flagsChanged.rawValue)

        let box = EventTapBox()
        box.setHyperHoldObserver(hyperHoldObserver)
        box.onKeyPress = MatchedShortcutDelivery.makeHandler { [weak self] keyPress in
            self?.handleAsync(keyPress, generation: generation)
        }
        box.onTapDisabled = { snapshot in
            DispatchQueue.global(qos: .utility).async {
                DiagnosticLog.log(snapshot.logMessage)
            }
        }
        box.onRecoveryNeeded = { [weak self] action, lifecycleSnapshot in
            Task { @MainActor in
                self?.handleRecoveryAction(
                    action,
                    snapshot: lifecycleSnapshot,
                    generation: generation
                )
            }
        }
        box.registeredShortcuts = registeredKeyPresses
        box.phasedChords = phasedKeyPresses
        box.setPhasedKeyObserver(wrappedPhasedObserver(generation: generation))
        box.setHyperKey(enabled: hyperKeyEnabled)
        ownershipLedger.boxCreates += 1
        let session = EventTapOwnedSession(
            generation: generation,
            thread: thread,
            box: box
        )
        owner = session
        let userInfo = session.userInfo
        let context = EventTapCreationContext(
            generation: generation,
            phase: .initial,
            attempt: 1
        )

        #if DEBUG
        logger.debug("tapCreate: AXIsProcessTrusted=\(AXIsProcessTrusted()), CGPreflightListenEventAccess=\(CGPreflightListenEventAccess()), trying .defaultTap")
        #endif
        guard let tap = runtimeFactory.makeTap(
            context,
            CGEventMask(mask),
            eventTapCallback,
            userInfo
        ) else {
            logger.error("tapCreate: .defaultTap failed — active event tap could not be created")
            DiagnosticLog.log("tapCreate: .defaultTap failed")
            tearDownOwnedSession(finalState: .stopped, event: "initial_tap_create_failed")
            return .failedToCreateTap
        }
        session.tap = tap
        ownershipLedger.tapCreates += 1
        logger.info("tapCreate: SUCCESS, tap created")
        DiagnosticLog.log("tapCreate: SUCCESS, tap created")

        box.installTap(tap)

        guard let source = runtimeFactory.makeSource(context, tap) else {
            logger.error("runLoopSourceCreate: failed for active event tap")
            DiagnosticLog.log("runLoopSourceCreate: failed for active event tap")
            tearDownOwnedSession(finalState: .stopped, event: "initial_source_create_failed")
            return .failedToCreateTap
        }
        session.source = source
        ownershipLedger.sourceCreates += 1

        // Add source to background thread's RunLoop instead of main RunLoop
        thread.addSource(source)

        runtimeFactory.setTapEnabled(tap, true)

        lifecycleState = .running
        emitLifecycleLog("EVENT_TAP_STARTED")
        emitOwnershipLog(event: "started")
        logger.info("Event tap started (background thread)")
        DiagnosticLog.log("Event tap started (background thread)")
        #if WINK_EVENT_TAP_FAULT_INJECTION
        validationDriver?.scheduleScenario(manager: self, handler: onKeyPress)
        #endif
        return .started
    }

    func stop() {
        let shouldLog = owner != nil || lifecycleState != .stopped
        tearDownOwnedSession(finalState: .stopped, event: "stop")
        if shouldLog {
            logger.info("Event tap stopped")
            DiagnosticLog.log("Event tap stopped")
        }
    }

    /// Update the set of registered shortcuts for synchronous event swallowing.
    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {
        registeredKeyPresses = keyPresses
        owner?.box.registeredShortcuts = keyPresses
    }

    /// Update the subset of registered chords delivered with phase through
    /// the phased observer (both edges swallowed) instead of `onKeyPress`.
    func updatePhasedChords(_ keyPresses: Set<KeyPress>) {
        phasedKeyPresses = keyPresses
        owner?.box.phasedChords = keyPresses
    }

    func setPhasedKeyObserver(_ observer: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?) {
        phasedKeyObserver = observer
        if let owner {
            owner.box.setPhasedKeyObserver(wrappedPhasedObserver(generation: owner.generation))
        }
    }

    /// Generation-bound wrapper, mirroring the ordinary path's
    /// `handleAsync(_:generation:)` guard: a phased event queued from the
    /// tap thread must be discarded if the provider stopped or the tap was
    /// recreated before the main queue drained it. Teardown clears the box's
    /// stored observer, but an already-captured closure in a queued block
    /// outlives that — the generation check is what actually revokes it.
    private func wrappedPhasedObserver(
        generation: UInt64
    ) -> (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)? {
        guard let phasedKeyObserver else { return nil }
        return { [weak self] keyPress, phase in
            guard let self,
                  self.owner?.generation == generation,
                  self.lifecycleState == .running else {
                self?.ownershipLedger.staleCallbacksDiscarded += 1
                self?.emitOwnershipLog(event: "stale_phased_callback_discarded")
                return
            }
            phasedKeyObserver(keyPress, phase)
        }
    }

    private var registeredKeyPresses: Set<KeyPress> = []
    private var phasedKeyPresses: Set<KeyPress> = []
    private var phasedKeyObserver: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?
    private var hyperKeyEnabled = false

    func setHyperHoldObserver(_ observer: (@Sendable (HyperHoldEvent) -> Void)?) {
        hyperHoldObserver = observer
        owner?.box.setHyperHoldObserver(observer)
    }

    /// Enable or disable Hyper Key (F19) interception in the event tap callback.
    func setHyperKeyEnabled(_ enabled: Bool) {
        hyperKeyEnabled = enabled
        owner?.box.setHyperKey(enabled: enabled)
    }

    /// Called on main thread from async dispatch. Applies debounce then calls handler.
    private func handleAsync(_ keyPress: KeyPress, generation: UInt64) {
        guard owner?.generation == generation, lifecycleState == .running else {
            ownershipLedger.staleCallbacksDiscarded += 1
            emitOwnershipLog(event: "stale_key_callback_discarded")
            return
        }
        ownershipLedger.keyCallbackDeliveries += 1
        handleAsync(keyPress)
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

    private func handleRecoveryAction(
        _ action: EventTapRecoveryAction,
        snapshot: EventTapLifecycleSnapshot,
        generation: UInt64
    ) {
        guard owner?.generation == generation else {
            ownershipLedger.staleCallbacksDiscarded += 1
            emitOwnershipLog(event: "stale_recovery_callback_discarded")
            return
        }

        switch action {
        case .reenableInPlace:
            emitLifecycleLog("EVENT_TAP_REENABLED", snapshot: snapshot)
        case .fullRecreation:
            // A burst can enqueue more timeout callbacks while the first
            // recreation is pending on the main actor. Only the threshold
            // crossing owns the recreation; later snapshots from that burst
            // become stale once the tracker is reset by a successful retry.
            guard lifecycleState == .running,
                  snapshot.rollingTimeoutCount == EventTapLifecycleTracker.timeoutsBeforeRecreation else {
                ownershipLedger.staleCallbacksDiscarded += 1
                emitOwnershipLog(event: "duplicate_recovery_callback_discarded")
                return
            }
            recreateEventTap(generation: generation)
        case .markDegraded:
            emitLifecycleLog("EVENT_TAP_DEGRADED", snapshot: snapshot)
            tearDownOwnedSession(finalState: .degraded, event: "callback_marked_degraded")
        }
    }

    /// Record a recreation failure through the current owner's tracker. The
    /// returned action must be executed by the caller; in particular, the
    /// first `.fullRecreation` is an actual retry rather than a log-only state.
    private func recordRecreationFailure(
        for session: EventTapOwnedSession
    ) -> (EventTapRecoveryAction, EventTapLifecycleSnapshot) {
        let now = runtimeFactory.now()
        let (action, snapshot) = session.box.recordRecreationFailureAndSnapshot(
            at: now,
            threadIdentity: session.thread.identity
        )
        emitLifecycleLog("EVENT_TAP_RECREATION_FAILED", snapshot: snapshot)
        emitOwnershipLog(event: "recreation_failed")
        return (action, snapshot)
    }

    /// Tear down and recreate the event tap on the existing background thread.
    /// Follows ordered sequence: remove source → disable/invalidate → release
    /// → create new tap → create new source → add source → enable.
    private func recreateEventTap(generation: UInt64) {
        guard let session = owner, session.generation == generation else {
            ownershipLedger.staleCallbacksDiscarded += 1
            emitOwnershipLog(event: "recreation_without_current_owner_discarded")
            return
        }

        lifecycleState = .recovering
        releaseTapAndSource(from: session)

        let mask = (1 << CGEventType.keyDown.rawValue)
                  | (1 << CGEventType.keyUp.rawValue)
                  | (1 << CGEventType.flagsChanged.rawValue)

        var attempt = 1
        while owner === session, lifecycleState == .recovering {
            let userInfo = session.userInfo
            let context = EventTapCreationContext(
                generation: generation,
                phase: .replacement,
                attempt: attempt
            )

            guard let newTap = runtimeFactory.makeTap(
                context,
                CGEventMask(mask),
                eventTapCallback,
                userInfo
            ) else {
                let (action, snapshot) = recordRecreationFailure(for: session)
                if action == .fullRecreation {
                    attempt += 1
                    continue
                }
                emitLifecycleLog("EVENT_TAP_DEGRADED", snapshot: snapshot)
                tearDownOwnedSession(finalState: .degraded, event: "replacement_tap_retry_limit")
                return
            }
            session.tap = newTap
            session.box.installTap(newTap)
            ownershipLedger.tapCreates += 1

            guard let newSource = runtimeFactory.makeSource(context, newTap) else {
                releaseTapAndSource(from: session)
                let (action, snapshot) = recordRecreationFailure(for: session)
                if action == .fullRecreation {
                    attempt += 1
                    continue
                }
                emitLifecycleLog("EVENT_TAP_DEGRADED", snapshot: snapshot)
                tearDownOwnedSession(finalState: .degraded, event: "replacement_source_retry_limit")
                return
            }
            session.source = newSource
            ownershipLedger.sourceCreates += 1
            session.thread.addSource(newSource)
            runtimeFactory.setTapEnabled(newTap, true)

            let snapshot = session.box.recordRecreationSuccessAndSnapshot(
                at: runtimeFactory.now(),
                threadIdentity: session.thread.identity
            )
            lifecycleState = .running
            emitLifecycleLog("EVENT_TAP_RECREATED", snapshot: snapshot)
            emitOwnershipLog(event: "recreated")
            return
        }
    }

    private func emitLifecycleLog(_ event: String, snapshot: EventTapLifecycleSnapshot? = nil) {
        let resolvedSnapshot: EventTapLifecycleSnapshot
        if let snapshot = snapshot {
            resolvedSnapshot = snapshot
        } else if let session = owner {
            resolvedSnapshot = session.box.captureLifecycleSnapshot(
                at: runtimeFactory.now(),
                threadIdentity: session.thread.identity
            )
        } else {
            return
        }
        let entry = EventTapLifecycleLogEntry(event: event, snapshot: resolvedSnapshot)
        logger.info("\(entry.logMessage)")
        DispatchQueue.global(qos: .utility).async {
            DiagnosticLog.log(entry.logMessage)
        }
    }

    private func releaseTapAndSource(from session: EventTapOwnedSession) {
        if let source = session.source {
            session.thread.removeSource(source)
            session.source = nil
            ownershipLedger.sourceReleases += 1
        }
        if let tap = session.tap {
            let clearedBoxTap = session.box.tearDownTap { ownedTap in
                runtimeFactory.setTapEnabled(ownedTap, false)
                runtimeFactory.invalidateTap(ownedTap)
            }
            if !clearedBoxTap {
                runtimeFactory.setTapEnabled(tap, false)
                runtimeFactory.invalidateTap(tap)
            }
            session.tap = nil
            ownershipLedger.tapReleases += 1
        }
    }

    /// Unconditionally tears down every resource owned by the current
    /// generation. This remains safe after partial creation and on repeated
    /// calls, so `stop()` never uses readiness as an ownership proxy.
    private func tearDownOwnedSession(
        finalState: EventTapLifecycleState,
        event: String
    ) {
        if let session = owner {
            releaseTapAndSource(from: session)
            session.thread.cancelAndWait()
            ownershipLedger.threadReleases += 1

            // The join above is the lifetime boundary: no tap callback can
            // still be reading these fields when session ownership is released.
            session.box.onKeyPress = nil
            session.box.setPhasedKeyObserver(nil)
            session.box.onTapDisabled = nil
            session.box.onRecoveryNeeded = nil
            session.box.reenableTap = nil
            ownershipLedger.boxReleases += 1
            owner = nil
        }

        onKeyPress = nil
        lastTriggerTime = 0
        lastTriggerKeyPress = nil
        lifecycleState = finalState
        emitOwnershipLog(event: event)
    }

    private func emitOwnershipLog(event: String) {
        let message = ownershipSnapshot.logMessage(event: event)
        logger.info("\(message)")
        DispatchQueue.global(qos: .utility).async {
            DiagnosticLog.log(message)
        }
    }

    #if WINK_EVENT_TAP_FAULT_INJECTION
    /// Validation-only timeout driver. It records decisions through the same
    /// EventTapBox tracker and dispatches through the same recovery closure as
    /// a real `.tapDisabledByTimeout` callback.
    func validationTriggerTimeoutThreshold() {
        guard let session = owner, lifecycleState == .running else { return }
        let startedAt = runtimeFactory.now()
        for offset in 0..<EventTapLifecycleTracker.timeoutsBeforeRecreation {
            session.box.reenableTapIfNeeded()
            let (action, snapshot) = session.box.recordTimeoutAndDecide(
                at: startedAt + Double(offset) / 1_000,
                threadIdentity: session.thread.identity
            )
            if action == .fullRecreation || action == .markDegraded {
                session.box.onRecoveryNeeded?(action, snapshot)
            }
        }
    }

    func validationCaptureStoppedGenerationProbe() -> EventTapStoppedGenerationProbe? {
        guard let session = owner,
              let keyCallback = session.box.onKeyPress,
              let recoveryCallback = session.box.onRecoveryNeeded else {
            return nil
        }
        let snapshot = EventTapLifecycleSnapshot(
            rollingTimeoutCount: EventTapLifecycleTracker.timeoutsBeforeRecreation,
            recreationFailureCount: 0,
            timeSinceLastTimeout: 0,
            lifecycleState: .recovering,
            recoveryMode: "recreated",
            threadIdentity: session.thread.identity,
            readinessState: "recovering"
        )
        return EventTapStoppedGenerationProbe(
            generation: session.generation,
            keyCallback: keyCallback,
            recoveryCallback: recoveryCallback,
            recoverySnapshot: snapshot
        )
    }

    var validationCurrentHyperKeyEnabled: Bool {
        owner?.box.hyperKeyEnabled == true
    }
    #endif
}

// MARK: - Background RunLoop Thread

/// Dedicated thread with its own RunLoop for hosting the CGEvent tap.
/// Keeps the tap responsive even if the main thread is busy with UI work.
/// Uses an NSCondition-based readiness mechanism instead of a one-shot semaphore
/// so that the same thread supports repeated add/remove/recreate cycles.
/// internal for @testable access
final class BackgroundRunLoopThread: Thread, EventTapRunLoopThread {
    private var threadRunLoop: CFRunLoop?
    private let readyCondition = NSCondition()
    private var isReady = false
    private var didExit = false
    private var recordedThreadID: UInt64?

    override func main() {
        readyCondition.lock()
        var currentThreadID: UInt64 = 0
        pthread_threadid_np(nil, &currentThreadID)
        recordedThreadID = currentThreadID
        threadRunLoop = CFRunLoopGetCurrent()
        isReady = true
        readyCondition.broadcast()
        readyCondition.unlock()
        // Keep the run loop alive with a dummy source
        let context = CFRunLoopSourceContext()
        var mutableContext = context
        let dummySource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &mutableContext)
        CFRunLoopAddSource(threadRunLoop, dummySource, .commonModes)
        // A cancel() issued before this point could not stop the run loop
        // (CFRunLoopStop on a non-running loop is a no-op), so don't enter it.
        if !isCancelled {
            CFRunLoopRun()
        }
        readyCondition.lock()
        didExit = true
        readyCondition.broadcast()
        readyCondition.unlock()
    }

    /// True once `main()` has returned past `CFRunLoopRun()`. Test seam for
    /// verifying `cancel()`'s join semantics.
    var hasExited: Bool {
        readyCondition.lock()
        defer { readyCondition.unlock() }
        return didExit
    }

    var identity: String {
        name ?? "event-tap-\(ObjectIdentifier(self))"
    }

    var threadID: UInt64? {
        readyCondition.lock()
        defer { readyCondition.unlock() }
        return recordedThreadID
    }

    var isAlive: Bool {
        readyCondition.lock()
        defer { readyCondition.unlock() }
        return isReady && !didExit
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

    /// Blocks until the thread can no longer touch the `EventTapBox`: either
    /// `main()` has returned, or the thread exited without ever running
    /// `main()` (Foundation skips `main()` when the cancelled flag wins the
    /// race against thread startup). Callers (`EventTapManager.stop()`) rely
    /// on this join to release the box only after no tap callback can still
    /// be executing on this thread.
    override func cancel() {
        super.cancel()
        readyCondition.lock()
        while !didExit {
            if isReady, let rl = threadRunLoop {
                // CFRunLoopStop is a no-op if it lands between the readiness
                // broadcast and CFRunLoopRun() actually starting, so re-issue
                // it every pass instead of waiting forever on a lost stop.
                CFRunLoopStop(rl)
            }
            if !readyCondition.wait(until: Date().addingTimeInterval(0.01)),
               isFinished {
                // Thread exited without running main() — nothing to join.
                break
            }
        }
        readyCondition.unlock()
    }

    func cancelAndWait() {
        cancel()
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

// Boxes the EventTapManager callback state for the C callback's userInfo
// pointer. EventTapOwnedSession strongly owns it until tap invalidation and the
// background-thread join have completed. Also holds the CFMachPort so the
// callback can re-enable a disabled tap.
//
// Thread safety: the tap, registered shortcuts, Hyper state, diagnostics, and
// lifecycle tracker are protected by an os_unfair_lock. Callback closures are
// installed before the tap is enabled and cleared only after the thread join.
final class EventTapBox: @unchecked Sendable {
    private var _tap: CFMachPort?
    var reenableTap: (@Sendable () -> Void)?
    /// Background-safe closure that hops to the main actor before invoking app logic.
    var onKeyPress: (@Sendable (KeyPress) -> Void)?
    /// Display-only observer. Written under the lock (it can be swapped
    /// after the tap is live); read via `notifyHyperHoldEvent`, which
    /// snapshots under the lock and invokes outside it.
    private var _onHyperHoldEvent: (@Sendable (HyperHoldEvent) -> Void)?

    func setHyperHoldObserver(_ observer: (@Sendable (HyperHoldEvent) -> Void)?) {
        withLock { _onHyperHoldEvent = observer }
    }

    func notifyHyperHoldEvent(_ event: HyperHoldEvent) {
        let observer = withLock { _onHyperHoldEvent }
        observer?(event)
    }

    /// Phased-chord observer. Written under the lock; snapshot-read like
    /// `_onHyperHoldEvent`. Invocation hops to the main queue *inside*
    /// `notifyPhasedKeyEvent` so down/up ordering is a box guarantee: the
    /// main dispatch queue is FIFO, sibling `Task`s are not.
    private var _onPhasedKeyEvent: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?

    func setPhasedKeyObserver(_ observer: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?) {
        withLock { _onPhasedKeyEvent = observer }
    }

    func notifyPhasedKeyEvent(_ keyPress: KeyPress, _ phase: KeyEventPhase) {
        let observer = withLock { _onPhasedKeyEvent }
        guard let observer else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                observer(keyPress, phase)
            }
        }
    }
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
    /// Side-index of just the registered keyCodes, kept in sync with
    /// `_registeredShortcuts`. Lets the DEBUG near-miss diagnostic stay O(1)
    /// on the event-tap callback thread without holding onto modifier data.
    fileprivate var _registeredKeyCodes: Set<CGKeyCode> = []
    /// Subset of `_registeredShortcuts` whose down AND up edges are swallowed
    /// and delivered via the phased observer instead of `onKeyPress`.
    /// Persists across tap recreation (the box outlives sessions) and is
    /// cleared with the rest of the delivery closures at teardown.
    fileprivate var _phasedChords: Set<KeyPress> = []
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
        set {
            let keyCodes = Set(newValue.lazy.map(\.keyCode))
            withLock {
                _registeredShortcuts = newValue
                _registeredKeyCodes = keyCodes
            }
        }
    }
    var phasedChords: Set<KeyPress> {
        get { withLock { _phasedChords } }
        set { withLock { _phasedChords = newValue } }
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
    func reenableTapIfNeeded(
        enableTap: (CFMachPort) -> Void = { tap in
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    ) {
        if let reenableTap = reenableTap {
            reenableTap()
        } else {
            withLock {
                if let tap = _tap {
                    enableTap(tap)
                }
            }
        }
    }

    func installTap(_ tap: CFMachPort) {
        withLock {
            _tap = tap
        }
    }

    /// Serializes invalidation with callback-side re-enable so teardown can
    /// never race an in-flight timeout callback's access to the owned tap.
    @discardableResult
    func tearDownTap(_ body: (CFMachPort) -> Void) -> Bool {
        let tap = withLock { () -> CFMachPort? in
            defer { _tap = nil }
            return _tap
        }
        guard let tap else { return false }
        // System calls stay outside the lock. Taking the tap waited for any
        // earlier re-enable to finish, and future re-enables now see nil.
        body(tap)
        return true
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
