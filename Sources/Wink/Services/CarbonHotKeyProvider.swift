import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

private let carbonHotKeySignature: OSType = 0x514B4559 // 'QKEY'
private let carbonFunctionRowKeyCodes: Set<CGKeyCode> = [
    CGKeyCode(kVK_F1), CGKeyCode(kVK_F2), CGKeyCode(kVK_F3), CGKeyCode(kVK_F4),
    CGKeyCode(kVK_F5), CGKeyCode(kVK_F6), CGKeyCode(kVK_F7), CGKeyCode(kVK_F8),
    CGKeyCode(kVK_F9), CGKeyCode(kVK_F10), CGKeyCode(kVK_F11), CGKeyCode(kVK_F12),
    CGKeyCode(kVK_F13), CGKeyCode(kVK_F14), CGKeyCode(kVK_F15), CGKeyCode(kVK_F16),
    CGKeyCode(kVK_F17), CGKeyCode(kVK_F18), CGKeyCode(kVK_F19), CGKeyCode(kVK_F20),
]

@MainActor
struct CarbonHotKeyRegistrationClient {
    typealias Register = (
        _ keyCode: UInt32,
        _ modifiers: UInt32,
        _ hotKeyID: EventHotKeyID
    ) -> (status: OSStatus, hotKeyRef: EventHotKeyRef?)

    let register: Register
    let unregister: (EventHotKeyRef) -> Void

    static let live = CarbonHotKeyRegistrationClient(
        register: { keyCode, modifiers, hotKeyID in
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            return (status, hotKeyRef)
        },
        unregister: { hotKeyRef in
            UnregisterEventHotKey(hotKeyRef)
        }
    )
}

@MainActor
protocol FunctionModifierStateTracking: AnyObject {
    var isReady: Bool { get }

    func consumeFunctionModifiedKeyDown(
        keyCode: CGKeyCode,
        carbonTimestamp: CGEventTimestamp
    ) -> Bool
    func start() -> Bool
    func stop()
}

@MainActor
struct FunctionModifierSystemStateClient {
    let isPhysicalFunctionKeyPressed: () -> Bool
    let currentEventTimestamp: () -> CGEventTimestamp

    init(
        isPhysicalFunctionKeyPressed: @escaping () -> Bool,
        currentEventTimestamp: @escaping () -> CGEventTimestamp = {
            CGEventTimestamp(max(0, GetCurrentEventTime()) * 1_000_000_000)
        }
    ) {
        self.isPhysicalFunctionKeyPressed = isPhysicalFunctionKeyPressed
        self.currentEventTimestamp = currentEventTimestamp
    }

    static let live = FunctionModifierSystemStateClient(
        isPhysicalFunctionKeyPressed: {
            CGEventSource.keyState(
                .hidSystemState,
                key: CGKeyCode(kVK_Function)
            )
        }
    )
}

struct FunctionModifierTapSnapshot: Equatable, Sendable {
    let isActive: Bool
    let isFunctionPressed: Bool
    let lastTransitionTimestamp: CGEventTimestamp?
}

final class FunctionModifierTapBox: @unchecked Sendable {
    private struct FunctionRowKeyDownObservation: Sendable {
        let keyCode: CGKeyCode
        let timestamp: CGEventTimestamp
        let functionPressed: Bool
    }

    private static let maximumRetainedKeyDownObservations = 32
    // The live Carbon event followed its CG keyDown by less than 1 ms. Keep a
    // bounded 50 ms allowance for scheduling jitter, and consume each match so
    // an old observation cannot authorize a later Carbon callback.
    private static let carbonTimestampTolerance: CGEventTimestamp = 50_000_000

    private let lock = NSLock()
    private var isActive = false
    private var isFunctionPressed = false
    private var hasObservedTransition = false
    private var lastTransitionTimestamp: CGEventTimestamp?
    private var functionRowKeyDownObservations: [FunctionRowKeyDownObservation] = []
    private var tap: CFMachPort?

    var snapshot: FunctionModifierTapSnapshot {
        lock.withLock {
            FunctionModifierTapSnapshot(
                isActive: isActive,
                isFunctionPressed: isFunctionPressed,
                lastTransitionTimestamp: lastTransitionTimestamp
            )
        }
    }

    func markActive() {
        lock.withLock {
            isActive = true
            isFunctionPressed = false
            lastTransitionTimestamp = nil
            functionRowKeyDownObservations.removeAll(keepingCapacity: true)
        }
    }

    func setTap(_ tap: CFMachPort?) {
        lock.withLock {
            self.tap = tap
        }
    }

    func seedIfUnobserved(
        isPressed: Bool,
        timestamp: CGEventTimestamp
    ) {
        lock.withLock {
            guard isActive, !hasObservedTransition else { return }
            isFunctionPressed = isPressed
            lastTransitionTimestamp = timestamp
        }
    }

    func recordFunctionTransition(
        isPressed: Bool,
        timestamp: CGEventTimestamp
    ) {
        lock.withLock {
            guard isActive else { return }
            hasObservedTransition = true
            isFunctionPressed = isPressed
            lastTransitionTimestamp = timestamp
        }
    }

    @discardableResult
    func recordFunctionRowKeyDown(
        keyCode: CGKeyCode,
        timestamp: CGEventTimestamp
    ) -> Bool {
        lock.withLock {
            guard isActive, carbonFunctionRowKeyCodes.contains(keyCode) else {
                return false
            }
            let observation = FunctionRowKeyDownObservation(
                keyCode: keyCode,
                timestamp: timestamp,
                functionPressed: isFunctionPressed
            )
            functionRowKeyDownObservations.append(observation)
            if functionRowKeyDownObservations.count > Self.maximumRetainedKeyDownObservations {
                functionRowKeyDownObservations.removeFirst(
                    functionRowKeyDownObservations.count - Self.maximumRetainedKeyDownObservations
                )
            }
            return observation.functionPressed
        }
    }

    func consumeFunctionModifiedKeyDown(
        keyCode: CGKeyCode,
        carbonTimestamp: CGEventTimestamp
    ) -> Bool {
        lock.withLock {
            guard isActive,
                  let index = functionRowKeyDownObservations.lastIndex(where: { observation in
                      guard observation.keyCode == keyCode,
                            observation.timestamp <= carbonTimestamp else {
                          return false
                      }
                      return carbonTimestamp - observation.timestamp
                          <= Self.carbonTimestampTolerance
                  }) else {
                return false
            }
            return functionRowKeyDownObservations.remove(at: index).functionPressed
        }
    }

    func failClosed() {
        lock.withLock {
            isActive = false
            isFunctionPressed = false
            hasObservedTransition = false
            lastTransitionTimestamp = nil
            functionRowKeyDownObservations.removeAll(keepingCapacity: true)
        }
    }

    func failClosedAndAttemptRecovery() {
        let tap = lock.withLock { () -> CFMachPort? in
            isActive = false
            isFunctionPressed = false
            hasObservedTransition = false
            lastTransitionTimestamp = nil
            functionRowKeyDownObservations.removeAll(keepingCapacity: true)
            return self.tap
        }
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else { return }
        lock.withLock {
            isActive = true
        }
    }
}

@discardableResult
func handleFunctionModifierTapEvent(
    type: CGEventType,
    event: CGEvent,
    box: FunctionModifierTapBox
) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        box.failClosedAndAttemptRecovery()
        let message = "CARBON_FUNCTION_MODIFIER_TAP_DISABLED reason=\(type.rawValue) active=\(box.snapshot.isActive)"
        DispatchQueue.global(qos: .utility).async {
            DiagnosticLog.log(message)
        }
    case .flagsChanged:
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == CGKeyCode(kVK_Function) else {
            return Unmanaged.passUnretained(event)
        }
        let isPressed = event.flags.contains(.maskSecondaryFn)
        let timestamp = event.timestamp
        box.recordFunctionTransition(
            isPressed: isPressed,
            timestamp: timestamp
        )
        let message = "CARBON_FUNCTION_MODIFIER_CHANGED pressed=\(isPressed) timestamp=\(timestamp)"
        DispatchQueue.global(qos: .utility).async {
            DiagnosticLog.log(message)
        }
    case .keyDown:
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard carbonFunctionRowKeyCodes.contains(keyCode) else {
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return Unmanaged.passUnretained(event)
        }
        let timestamp = event.timestamp
        let functionPressed = box.recordFunctionRowKeyDown(
            keyCode: keyCode,
            timestamp: timestamp
        )
        let message = "CARBON_FUNCTION_ROW_KEY_DOWN keyCode=\(keyCode) functionPressed=\(functionPressed) timestamp=\(timestamp)"
        DispatchQueue.global(qos: .utility).async {
            DiagnosticLog.log(message)
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

private let functionModifierTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let box = Unmanaged<FunctionModifierTapBox>.fromOpaque(userInfo).takeUnretainedValue()
    return handleFunctionModifierTapEvent(type: type, event: event, box: box)
}

protocol FunctionModifierEventTapSessionProtocol: AnyObject {
    var isActive: Bool { get }

    func seedIfUnobserved(isPressed: Bool, timestamp: CGEventTimestamp)
    func consumeFunctionModifiedKeyDown(
        keyCode: CGKeyCode,
        carbonTimestamp: CGEventTimestamp
    ) -> Bool
    func stop()
}

final class FunctionModifierEventTapSession: FunctionModifierEventTapSessionProtocol {
    private let box: FunctionModifierTapBox
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var backgroundThread: BackgroundRunLoopThread?
    private var retainedBox: Unmanaged<FunctionModifierTapBox>?

    private init(
        box: FunctionModifierTapBox,
        eventTap: CFMachPort,
        runLoopSource: CFRunLoopSource,
        backgroundThread: BackgroundRunLoopThread,
        retainedBox: Unmanaged<FunctionModifierTapBox>
    ) {
        self.box = box
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        self.backgroundThread = backgroundThread
        self.retainedBox = retainedBox
    }

    static func make() -> FunctionModifierEventTapSession? {
        guard CGPreflightListenEventAccess() else {
            DiagnosticLog.log("CARBON_FUNCTION_MODIFIER_TAP_CREATE_FAILED reason=input_monitoring_unavailable")
            return nil
        }

        let thread = BackgroundRunLoopThread()
        thread.name = "Wink Function Modifier Event Tap"
        thread.start()

        let box = FunctionModifierTapBox()
        let retainedBox = Unmanaged.passRetained(box)
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue)
                | (1 << CGEventType.keyDown.rawValue)
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: functionModifierTapCallback,
            userInfo: UnsafeMutableRawPointer(retainedBox.toOpaque())
        ) else {
            retainedBox.release()
            thread.cancel()
            DiagnosticLog.log("CARBON_FUNCTION_MODIFIER_TAP_CREATE_FAILED reason=tap_create")
            return nil
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            retainedBox.release()
            thread.cancel()
            DiagnosticLog.log("CARBON_FUNCTION_MODIFIER_TAP_CREATE_FAILED reason=run_loop_source")
            return nil
        }

        box.setTap(tap)
        box.markActive()
        thread.addSource(source)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            box.failClosed()
            box.setTap(nil)
            thread.removeSource(source)
            CFMachPortInvalidate(tap)
            thread.cancel()
            retainedBox.release()
            DiagnosticLog.log("CARBON_FUNCTION_MODIFIER_TAP_CREATE_FAILED reason=tap_enable")
            return nil
        }

        DiagnosticLog.log("CARBON_FUNCTION_MODIFIER_TAP_STARTED")
        return FunctionModifierEventTapSession(
            box: box,
            eventTap: tap,
            runLoopSource: source,
            backgroundThread: thread,
            retainedBox: retainedBox
        )
    }

    var isActive: Bool {
        box.snapshot.isActive
    }

    func seedIfUnobserved(
        isPressed: Bool,
        timestamp: CGEventTimestamp
    ) {
        box.seedIfUnobserved(isPressed: isPressed, timestamp: timestamp)
    }

    func consumeFunctionModifiedKeyDown(
        keyCode: CGKeyCode,
        carbonTimestamp: CGEventTimestamp
    ) -> Bool {
        box.consumeFunctionModifiedKeyDown(
            keyCode: keyCode,
            carbonTimestamp: carbonTimestamp
        )
    }

    func stop() {
        guard eventTap != nil || retainedBox != nil else { return }

        box.failClosed()
        box.setTap(nil)
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let thread = backgroundThread {
            thread.removeSource(source)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        backgroundThread?.cancel()
        backgroundThread = nil
        retainedBox?.release()
        retainedBox = nil
        eventTap = nil
        runLoopSource = nil
        DiagnosticLog.log("CARBON_FUNCTION_MODIFIER_TAP_STOPPED")
    }
}

@MainActor
struct FunctionModifierEventTapClient {
    let inputMonitoringGranted: () -> Bool
    let start: () -> (any FunctionModifierEventTapSessionProtocol)?

    static let live = FunctionModifierEventTapClient(
        inputMonitoringGranted: { CGPreflightListenEventAccess() },
        start: { FunctionModifierEventTapSession.make() }
    )
}

@MainActor
final class CGEventTapFunctionModifierStateTracker: FunctionModifierStateTracking {
    private let systemState: FunctionModifierSystemStateClient
    private let tapClient: FunctionModifierEventTapClient
    private var session: (any FunctionModifierEventTapSessionProtocol)?

    init(
        systemState: FunctionModifierSystemStateClient = .live,
        tapClient: FunctionModifierEventTapClient = .live
    ) {
        self.systemState = systemState
        self.tapClient = tapClient
    }

    var isReady: Bool {
        session?.isActive == true
    }

    func consumeFunctionModifiedKeyDown(
        keyCode: CGKeyCode,
        carbonTimestamp: CGEventTimestamp
    ) -> Bool {
        session?.consumeFunctionModifiedKeyDown(
            keyCode: keyCode,
            carbonTimestamp: carbonTimestamp
        ) == true
    }

    func start() -> Bool {
        guard tapClient.inputMonitoringGranted() else {
            stop()
            return false
        }

        if isReady {
            return true
        }

        stop()
        guard let session = tapClient.start() else {
            return false
        }
        self.session = session

        session.seedIfUnobserved(
            isPressed: systemState.isPhysicalFunctionKeyPressed(),
            timestamp: systemState.currentEventTimestamp()
        )

        return session.isActive
    }

    func stop() {
        session?.stop()
        session = nil
    }
}

typealias CarbonHotKeyDelivery = @MainActor @Sendable (
    _ identifier: UInt32,
    _ eventTimestamp: CGEventTimestamp
) -> Void

private final class CarbonHotKeyCallbackBox: @unchecked Sendable {
    let delivery: CarbonHotKeyDelivery

    init(delivery: @escaping CarbonHotKeyDelivery) {
        self.delivery = delivery
    }
}

private func carbonHotKeyCallbackImpl(
    eventRef: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let eventRef, let userData else {
        return noErr
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        OSType(kEventParamDirectObject),
        OSType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == carbonHotKeySignature else {
        return noErr
    }
    let eventTimestamp = cgEventTimestamp(
        fromCarbonEventTime: GetEventTime(eventRef)
    )

    let box = Unmanaged<CarbonHotKeyCallbackBox>.fromOpaque(userData).takeUnretainedValue()
    // Carbon hotkey events installed on GetApplicationEventTarget() are delivered
    // on the main thread, so isolation can be asserted without an async hop.
    MainActor.assumeIsolated {
        box.delivery(hotKeyID.id, eventTimestamp)
    }
    return noErr
}

private let carbonHotKeyCallback: EventHandlerUPP = { _, eventRef, userData in
    carbonHotKeyCallbackImpl(eventRef: eventRef, userData: userData)
}

@MainActor
protocol CarbonHotKeyHandlerSession: AnyObject {
    var isLive: Bool { get }
    func stop()
}

enum CarbonHotKeyHandlerInstallResult {
    case installed(any CarbonHotKeyHandlerSession)
    case failed(Int32)
}

@MainActor
struct CarbonHotKeyHandlerFactory {
    let install: (@escaping CarbonHotKeyDelivery) -> CarbonHotKeyHandlerInstallResult

    static let live = CarbonHotKeyHandlerFactory { delivery in
        let box = Unmanaged.passRetained(CarbonHotKeyCallbackBox(delivery: delivery))
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        var eventHandlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyCallback,
            1,
            &spec,
            UnsafeMutableRawPointer(box.toOpaque()),
            &eventHandlerRef
        )

        guard status == noErr, let eventHandlerRef else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
            }
            box.release()
            return .failed(status == noErr ? Int32(eventInternalErr) : status)
        }

        return .installed(LiveCarbonHotKeyHandlerSession(
            eventHandlerRef: eventHandlerRef,
            callbackBox: box
        ))
    }
}

@MainActor
private final class LiveCarbonHotKeyHandlerSession: CarbonHotKeyHandlerSession {
    private var eventHandlerRef: EventHandlerRef?
    private var callbackBox: Unmanaged<CarbonHotKeyCallbackBox>?

    init(
        eventHandlerRef: EventHandlerRef,
        callbackBox: Unmanaged<CarbonHotKeyCallbackBox>
    ) {
        self.eventHandlerRef = eventHandlerRef
        self.callbackBox = callbackBox
    }

    var isLive: Bool {
        eventHandlerRef != nil && callbackBox != nil
    }

    func stop() {
        guard eventHandlerRef != nil || callbackBox != nil else { return }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        callbackBox?.release()
        callbackBox = nil
    }
}

func cgEventTimestamp(fromCarbonEventTime eventTime: EventTime) -> CGEventTimestamp {
    // Carbon EventTime is seconds since boot; CGEventTimestamp is roughly
    // nanoseconds since startup. Both definitions come from the macOS SDK.
    guard eventTime.isFinite, eventTime > 0 else { return 0 }
    return CGEventTimestamp(eventTime * 1_000_000_000)
}

@MainActor
final class CarbonHotKeyProvider: ShortcutCaptureProvider {
    private struct Registration {
        let keyPress: KeyPress
        let ref: EventHotKeyRef
    }

    private let registrationClient: CarbonHotKeyRegistrationClient
    private let handlerFactory: CarbonHotKeyHandlerFactory
    private let functionModifierStateTracker: any FunctionModifierStateTracking
    private var handlerSession: (any CarbonHotKeyHandlerSession)?
    private var handlerFailureStatus: Int32?
    private var handlerGeneration: UInt64 = 0
    private var desiredShortcuts: Set<KeyPress> = []
    private var registrations: [UInt32: Registration] = [:]
    private var registrationFailures: [ShortcutCaptureRegistrationFailure] = []
    private var functionModifierTrackingAvailable = true
    private var nextIdentifier: UInt32 = 1
    private var onKeyPress: (@MainActor @Sendable (KeyPress) -> Void)?

    init(
        registrationClient: CarbonHotKeyRegistrationClient = .live,
        handlerFactory: CarbonHotKeyHandlerFactory? = nil,
        functionModifierStateTracker: any FunctionModifierStateTracking = CGEventTapFunctionModifierStateTracker()
    ) {
        self.registrationClient = registrationClient
        self.handlerFactory = handlerFactory ?? Self.defaultHandlerFactory()
        self.functionModifierStateTracker = functionModifierStateTracker
    }

    private static func defaultHandlerFactory() -> CarbonHotKeyHandlerFactory {
        #if WINK_CARBON_HANDLER_FAULT_INJECTION
        if let configuration = CarbonHandlerFaultInjectionConfiguration(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            return CarbonHandlerFaultInjectionDriver(
                configuration: configuration,
                baseFactory: .live
            ).factory
        }
        #endif
        return .live
    }

    var isRunning: Bool {
        handlerSession?.isLive == true && !registrations.isEmpty
    }

    var inputMonitoringRequired: Bool {
        desiredShortcuts.contains(where: requiresFunctionModifierStateTracking)
    }

    var registrationState: ShortcutCaptureRegistrationState {
        let trackingReady = !inputMonitoringRequired || functionModifierStateTracker.isReady
        let registeredShortcutCount = trackingReady
            ? registrations.count
            : registrations.values.lazy.filter {
                !self.requiresFunctionModifierStateTracking($0.keyPress)
            }.count
        var failures = registrationFailures
        if !trackingReady {
            failures.append(contentsOf: registrations.values.compactMap { registration in
                guard requiresFunctionModifierStateTracking(registration.keyPress),
                      !failures.contains(where: { $0.keyPress == registration.keyPress }) else {
                    return nil
                }
                return ShortcutCaptureRegistrationFailure(
                    keyPress: registration.keyPress,
                    status: Int32(eventInternalErr)
                )
            })
        }
        return ShortcutCaptureRegistrationState(
            desiredShortcutCount: desiredShortcuts.count,
            registeredShortcutCount: registeredShortcutCount,
            handlerState: handlerState,
            failures: failures.sorted {
                if $0.keyPress.keyCode == $1.keyPress.keyCode {
                    return $0.keyPress.modifiers.rawValue < $1.keyPress.modifiers.rawValue
                }
                return $0.keyPress.keyCode < $1.keyPress.keyCode
            }
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        self.onKeyPress = onKeyPress
        synchronizeFunctionModifierTracking()
        guard !desiredShortcuts.isEmpty else {
            unregisterAll()
            registrationFailures = []
            removeHandlerIfNeeded()
            return
        }

        synchronizeRegistrations()
    }

    func stop() {
        onKeyPress = nil
        handlerGeneration &+= 1
        unregisterAll()
        registrationFailures = []
        removeHandlerIfNeeded(invalidateCallbacks: false)
        functionModifierStateTracker.stop()
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {
        desiredShortcuts = keyPresses
        guard onKeyPress != nil else { return }

        synchronizeFunctionModifierTracking()

        if desiredShortcuts.isEmpty {
            unregisterAll()
            registrationFailures = []
            removeHandlerIfNeeded()
            return
        }

        synchronizeRegistrations()
    }

    private var handlerState: ShortcutCaptureHandlerState {
        if handlerSession?.isLive == true {
            return .installed
        }
        if let handlerFailureStatus {
            return .installationFailed(status: handlerFailureStatus)
        }
        return .notInstalled
    }

    private func synchronizeRegistrations() {
        let handlerInstalled = installHandlerIfNeeded()
        let summary = reregisterShortcuts()
        let rolledBackRegistrationCount: Int
        if handlerInstalled {
            rolledBackRegistrationCount = 0
        } else {
            rolledBackRegistrationCount = registrations.count
            unregisterAll()
        }
        let state = handlerState
        DiagnosticLog.log(
            "CARBON_HOTKEY_SYNC handlerState=\(state.diagnosticName) handlerStatus=\(state.failureStatus.map(String.init) ?? "none") desired=\(desiredShortcuts.count) lowLevelAttempts=\(summary.attempts) lowLevelSuccesses=\(summary.successes) active=\(registrations.count) rolledBack=\(rolledBackRegistrationCount)"
        )
    }

    @discardableResult
    private func installHandlerIfNeeded() -> Bool {
        if handlerSession?.isLive == true {
            handlerFailureStatus = nil
            return true
        }

        handlerSession?.stop()
        handlerSession = nil
        handlerGeneration &+= 1
        let generation = handlerGeneration
        let result = handlerFactory.install { [weak self] identifier, eventTimestamp in
            guard let self, self.handlerGeneration == generation else { return }
            self.handleHotKeyEvent(
                identifier: identifier,
                eventTimestamp: eventTimestamp
            )
        }

        switch result {
        case .installed(let session) where session.isLive:
            handlerSession = session
            handlerFailureStatus = nil
            DiagnosticLog.log(
                "CARBON_HOTKEY_HANDLER_INSTALL state=installed status=0 generation=\(generation)"
            )
            return true
        case .installed(let session):
            session.stop()
            handlerFailureStatus = Int32(eventInternalErr)
        case .failed(let status):
            handlerFailureStatus = status
        }

        DiagnosticLog.log(
            "CARBON_HOTKEY_HANDLER_INSTALL state=installation_failed status=\(handlerFailureStatus ?? Int32(eventInternalErr)) generation=\(generation)"
        )
        return false
    }

    private func removeHandlerIfNeeded(invalidateCallbacks: Bool = true) {
        if invalidateCallbacks {
            handlerGeneration &+= 1
        }
        handlerSession?.stop()
        handlerSession = nil
        handlerFailureStatus = nil
    }

    private func reregisterShortcuts() -> (attempts: Int, successes: Int) {
        unregisterAll()
        registrationFailures = []
        var attempts = 0
        var successes = 0

        let sortedShortcuts = desiredShortcuts.sorted {
            if $0.keyCode == $1.keyCode {
                return $0.modifiers.rawValue < $1.modifiers.rawValue
            }
            return $0.keyCode < $1.keyCode
        }

        for keyPress in sortedShortcuts {
            let result = register(keyPress)
            attempts += result.attempted ? 1 : 0
            successes += result.registered ? 1 : 0
        }
        return (attempts, successes)
    }

    private func register(_ keyPress: KeyPress) -> (attempted: Bool, registered: Bool) {
        if requiresFunctionModifierStateTracking(keyPress),
           !functionModifierTrackingAvailable {
            registrationFailures.append(ShortcutCaptureRegistrationFailure(
                keyPress: keyPress,
                status: Int32(eventInternalErr)
            ))
            DiagnosticLog.log(
                "CARBON_HOTKEY_REGISTER_FAILED status=\(eventInternalErr) keyCode=\(keyPress.keyCode) reason=function_modifier_tracking_unavailable"
            )
            return (false, false)
        }

        let identifier = nextIdentifier
        nextIdentifier &+= 1
        let hotKeyID = EventHotKeyID(signature: carbonHotKeySignature, id: identifier)
        let result = registrationClient.register(
            UInt32(keyPress.keyCode),
            carbonModifiers(from: keyPress.modifiers),
            hotKeyID
        )
        let status = result.status
        let hotKeyRef = result.hotKeyRef

        guard status == noErr, let hotKeyRef else {
            registrationFailures.append(ShortcutCaptureRegistrationFailure(
                keyPress: keyPress,
                status: status
            ))
            DiagnosticLog.log(
                "CARBON_HOTKEY_REGISTER_FAILED status=\(status) keyCode=\(keyPress.keyCode) modifiers=\(keyPress.modifiers.rawValue)"
            )
            return (true, false)
        }

        registrations[identifier] = Registration(keyPress: keyPress, ref: hotKeyRef)
        return (true, true)
    }

    private func unregisterAll() {
        for registration in registrations.values {
            registrationClient.unregister(registration.ref)
        }
        registrations.removeAll(keepingCapacity: true)
    }

    private func synchronizeFunctionModifierTracking() {
        if desiredShortcuts.contains(where: requiresFunctionModifierStateTracking) {
            functionModifierTrackingAvailable = functionModifierStateTracker.start()
        } else {
            functionModifierStateTracker.stop()
            functionModifierTrackingAvailable = true
        }
    }

    private func requiresFunctionModifierStateTracking(_ keyPress: KeyPress) -> Bool {
        keyPress.modifiers.contains(.function)
            && carbonFunctionRowKeyCodes.contains(keyPress.keyCode)
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.function) { modifiers |= UInt32(kEventKeyModifierFnMask) }
        return modifiers
    }

    func handleHotKeyEvent(
        identifier: UInt32,
        eventTimestamp: CGEventTimestamp = .max
    ) {
        guard handlerSession?.isLive == true,
              let registration = registrations[identifier],
              let onKeyPress else {
            return
        }

        if requiresFunctionModifierStateTracking(registration.keyPress) {
            guard functionModifierStateTracker.isReady else {
                DiagnosticLog.log(
                    "CARBON_HOTKEY_IGNORED keyCode=\(registration.keyPress.keyCode) reason=function_modifier_tracking_unavailable"
                )
                return
            }
            guard functionModifierStateTracker.consumeFunctionModifiedKeyDown(
                keyCode: registration.keyPress.keyCode,
                carbonTimestamp: eventTimestamp
            ) else {
                DiagnosticLog.log(
                    "CARBON_HOTKEY_IGNORED keyCode=\(registration.keyPress.keyCode) reason=function_modifier_not_pressed eventTimestamp=\(eventTimestamp)"
                )
                return
            }
            DiagnosticLog.log(
                "CARBON_HOTKEY_ACCEPTED keyCode=\(registration.keyPress.keyCode) eventTimestamp=\(eventTimestamp)"
            )
        }
        onKeyPress(registration.keyPress)
    }
}
