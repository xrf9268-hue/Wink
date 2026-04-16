import AppKit
import Carbon.HIToolbox
import Foundation

private let carbonHotKeySignature: OSType = 0x514B4559 // 'QKEY'

private final class CarbonHotKeyCallbackBox {
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
    if let provider = box.provider {
        DispatchQueue.main.async {
            provider.handleHotKeyEvent(identifier: hotKeyID.id)
        }
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
    private var eventHandlerRef: EventHandlerRef?
    private var desiredShortcuts: Set<KeyPress> = []
    private var registrations: [UInt32: Registration] = [:]
    private var registrationFailures: [ShortcutCaptureRegistrationFailure] = []
    private var nextIdentifier: UInt32 = 1
    private var onKeyPress: (@MainActor @Sendable (KeyPress) -> Void)?

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
        onKeyPress = nil
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {
        desiredShortcuts = keyPresses
        guard onKeyPress != nil else { return }

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
        var hotKeyRef: EventHotKeyRef?
        let identifier = nextIdentifier
        nextIdentifier &+= 1
        let hotKeyID = EventHotKeyID(signature: carbonHotKeySignature, id: identifier)
        let status = RegisterEventHotKey(
            UInt32(keyPress.keyCode),
            carbonModifiers(from: keyPress.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

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
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll(keepingCapacity: true)
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    fileprivate func handleHotKeyEvent(identifier: UInt32) {
        guard let registration = registrations[identifier],
              let onKeyPress else {
            return
        }

        Task { @MainActor in
            onKeyPress(registration.keyPress)
        }
    }
}
