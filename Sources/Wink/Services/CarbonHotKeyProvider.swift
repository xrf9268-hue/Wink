import AppKit
import Carbon.HIToolbox
import Foundation

private let carbonHotKeySignature: OSType = 0x514B4559 // 'QKEY'

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
    var isFunctionPressed: Bool { get }

    func start()
    func stop()
}

@MainActor
private final class AppKitFunctionModifierStateTracker: FunctionModifierStateTracking {
    private(set) var isFunctionPressed = false
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // AppKit monitor callbacks are delivered on the main thread.
            MainActor.assumeIsolated {
                self?.update(with: event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.update(with: event)
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        isFunctionPressed = false
    }

    private func update(with event: NSEvent) {
        guard event.keyCode == UInt16(kVK_Function) else { return }
        isFunctionPressed = event.modifierFlags.contains(.function)
    }
}

private final class CarbonHotKeyCallbackBox: @unchecked Sendable {
    // weak reference reads are atomic; provider is set once in init and never mutated.
    weak var provider: CarbonHotKeyProvider?

    init(provider: CarbonHotKeyProvider) {
        self.provider = provider
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

    let box = Unmanaged<CarbonHotKeyCallbackBox>.fromOpaque(userData).takeUnretainedValue()
    // Carbon hotkey events installed on GetApplicationEventTarget() are delivered
    // on the main thread, so isolation can be asserted without an async hop.
    MainActor.assumeIsolated {
        box.provider?.handleHotKeyEvent(identifier: hotKeyID.id)
    }
    return noErr
}

private let carbonHotKeyCallback: EventHandlerUPP = { _, eventRef, userData in
    carbonHotKeyCallbackImpl(eventRef: eventRef, userData: userData)
}

@MainActor
final class CarbonHotKeyProvider: ShortcutCaptureProvider {
    private struct Registration {
        let keyPress: KeyPress
        let ref: EventHotKeyRef
    }

    private var callbackBox: Unmanaged<CarbonHotKeyCallbackBox>?
    private let registrationClient: CarbonHotKeyRegistrationClient
    private let functionModifierStateTracker: any FunctionModifierStateTracking
    private var eventHandlerRef: EventHandlerRef?
    private var desiredShortcuts: Set<KeyPress> = []
    private var registrations: [UInt32: Registration] = [:]
    private var registrationFailures: [ShortcutCaptureRegistrationFailure] = []
    private var nextIdentifier: UInt32 = 1
    private var onKeyPress: (@MainActor @Sendable (KeyPress) -> Void)?

    init(
        registrationClient: CarbonHotKeyRegistrationClient = .live,
        functionModifierStateTracker: any FunctionModifierStateTracking = AppKitFunctionModifierStateTracker()
    ) {
        self.registrationClient = registrationClient
        self.functionModifierStateTracker = functionModifierStateTracker
    }

    var isRunning: Bool {
        !registrations.isEmpty
    }

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: desiredShortcuts.count,
            registeredShortcutCount: registrations.count,
            failures: registrationFailures.sorted {
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

        installHandlerIfNeeded()
        reregisterShortcuts()
    }

    func stop() {
        unregisterAll()
        removeHandlerIfNeeded()
        functionModifierStateTracker.stop()
        onKeyPress = nil
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

        installHandlerIfNeeded()
        reregisterShortcuts()
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        let box = Unmanaged.passRetained(CarbonHotKeyCallbackBox(provider: self))
        callbackBox = box
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyCallback,
            1,
            &spec,
            UnsafeMutableRawPointer(box.toOpaque()),
            &eventHandlerRef
        )

        guard status == noErr else {
            callbackBox?.release()
            callbackBox = nil
            eventHandlerRef = nil
            DiagnosticLog.log("CARBON_HOTKEY_HANDLER_INSTALL_FAILED status=\(status)")
            return
        }
    }

    private func removeHandlerIfNeeded() {
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        callbackBox?.release()
        callbackBox = nil
    }

    private func reregisterShortcuts() {
        unregisterAll()
        registrationFailures = []

        let sortedShortcuts = desiredShortcuts.sorted {
            if $0.keyCode == $1.keyCode {
                return $0.modifiers.rawValue < $1.modifiers.rawValue
            }
            return $0.keyCode < $1.keyCode
        }

        for keyPress in sortedShortcuts {
            register(keyPress)
        }
    }

    private func register(_ keyPress: KeyPress) {
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
            return
        }

        registrations[identifier] = Registration(keyPress: keyPress, ref: hotKeyRef)
    }

    private func unregisterAll() {
        for registration in registrations.values {
            registrationClient.unregister(registration.ref)
        }
        registrations.removeAll(keepingCapacity: true)
    }

    private func synchronizeFunctionModifierTracking() {
        if desiredShortcuts.contains(where: { $0.modifiers.contains(.function) }) {
            functionModifierStateTracker.start()
        } else {
            functionModifierStateTracker.stop()
        }
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

    func handleHotKeyEvent(identifier: UInt32) {
        guard let registration = registrations[identifier],
              let onKeyPress else {
            return
        }

        if registration.keyPress.modifiers.contains(.function),
           !functionModifierStateTracker.isFunctionPressed {
            DiagnosticLog.log(
                "CARBON_HOTKEY_IGNORED keyCode=\(registration.keyPress.keyCode) reason=function_modifier_not_pressed"
            )
            return
        }
        onKeyPress(registration.keyPress)
    }
}
