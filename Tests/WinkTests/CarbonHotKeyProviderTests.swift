import AppKit
import Carbon.HIToolbox
import Testing
@testable import Wink

@Suite("CarbonHotKeyProvider")
struct CarbonHotKeyProviderTests {
    @Test @MainActor
    func existingModifierMasksReachTheCarbonRegistrationBoundaryUnchanged() {
        let registrar = RecordingCarbonHotKeyRegistrar()
        let provider = CarbonHotKeyProvider(registrationClient: registrar.client)
        let shortcuts: Set<KeyPress> = [
            KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command]),
            KeyPress(keyCode: CGKeyCode(kVK_ANSI_B), modifiers: [.option]),
            KeyPress(keyCode: CGKeyCode(kVK_ANSI_C), modifiers: [.control]),
            KeyPress(keyCode: CGKeyCode(kVK_ANSI_D), modifiers: [.shift]),
        ]

        provider.updateRegisteredShortcuts(shortcuts)
        provider.start { _ in }
        defer { provider.stop() }

        let modifiersByKeyCode = Dictionary(
            uniqueKeysWithValues: registrar.registrations.map { ($0.keyCode, $0.modifiers) }
        )
        #expect(modifiersByKeyCode[UInt32(kVK_ANSI_A)] == UInt32(cmdKey))
        #expect(modifiersByKeyCode[UInt32(kVK_ANSI_B)] == UInt32(optionKey))
        #expect(modifiersByKeyCode[UInt32(kVK_ANSI_C)] == UInt32(controlKey))
        #expect(modifiersByKeyCode[UInt32(kVK_ANSI_D)] == UInt32(shiftKey))
    }

    @Test @MainActor
    func registeredIdentifierDeliversTheOriginalKeyPress() throws {
        let registrar = RecordingCarbonHotKeyRegistrar()
        let provider = CarbonHotKeyProvider(registrationClient: registrar.client)
        let shortcut = KeyPress(
            keyCode: CGKeyCode(kVK_ANSI_A),
            modifiers: [.command]
        )
        var delivered: [KeyPress] = []

        provider.updateRegisteredShortcuts([shortcut])
        provider.start { delivered.append($0) }
        defer { provider.stop() }

        let registration = try #require(registrar.registrations.first)
        provider.handleHotKeyEvent(identifier: registration.identifier)

        #expect(delivered == [shortcut])
    }

    @Test @MainActor
    func functionShortcutRegistersWithFnAndBareKeyCannotDeliver() throws {
        let registrar = RecordingCarbonHotKeyRegistrar()
        let modifierState = RecordingFunctionModifierStateTracker(isFunctionPressed: true)
        let provider = CarbonHotKeyProvider(
            registrationClient: registrar.client,
            functionModifierStateTracker: modifierState
        )
        let shortcut = KeyPress(
            keyCode: CGKeyCode(kVK_ANSI_A),
            modifiers: [.function]
        )
        var delivered: [KeyPress] = []

        provider.updateRegisteredShortcuts([shortcut])
        provider.start { delivered.append($0) }
        defer { provider.stop() }

        let registration = try #require(registrar.registrations.first)
        #expect(registration.keyCode == UInt32(kVK_ANSI_A))
        #expect(registration.modifiers == UInt32(kEventKeyModifierFnMask))

        registrar.deliver(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: 0,
            to: provider
        )
        #expect(delivered.isEmpty)

        registrar.deliver(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(kEventKeyModifierFnMask),
            to: provider
        )
        #expect(delivered == [shortcut])
    }

    @Test @MainActor
    func carbonFnCallbackIsIgnoredUnlessThePhysicalFunctionModifierIsPressed() throws {
        let registrar = RecordingCarbonHotKeyRegistrar()
        let modifierState = RecordingFunctionModifierStateTracker(isFunctionPressed: false)
        let provider = CarbonHotKeyProvider(
            registrationClient: registrar.client,
            functionModifierStateTracker: modifierState
        )
        let shortcut = KeyPress(
            keyCode: CGKeyCode(kVK_F6),
            modifiers: [.function]
        )
        var delivered: [KeyPress] = []

        provider.updateRegisteredShortcuts([shortcut])
        provider.start { delivered.append($0) }

        let registration = try #require(registrar.registrations.first)
        provider.handleHotKeyEvent(identifier: registration.identifier)
        #expect(delivered.isEmpty)
        #expect(modifierState.startCount == 1)

        modifierState.isFunctionPressed = true
        provider.handleHotKeyEvent(identifier: registration.identifier)
        #expect(delivered == [shortcut])

        provider.stop()
        #expect(modifierState.stopCount == 1)
    }
}

@MainActor
private final class RecordingCarbonHotKeyRegistrar {
    struct Registration {
        let keyCode: UInt32
        let modifiers: UInt32
        let identifier: UInt32
    }

    private(set) var registrations: [Registration] = []

    lazy var client = CarbonHotKeyRegistrationClient(
        register: { [unowned self] keyCode, modifiers, hotKeyID in
            registrations.append(Registration(
                keyCode: keyCode,
                modifiers: modifiers,
                identifier: hotKeyID.id
            ))
            return (noErr, OpaquePointer(bitPattern: Int(hotKeyID.id)))
        },
        unregister: { _ in }
    )

    func deliver(
        keyCode: UInt32,
        modifiers: UInt32,
        to provider: CarbonHotKeyProvider
    ) {
        guard let registration = registrations.first(where: {
            $0.keyCode == keyCode && $0.modifiers == modifiers
        }) else {
            return
        }
        provider.handleHotKeyEvent(identifier: registration.identifier)
    }
}

@MainActor
private final class RecordingFunctionModifierStateTracker: FunctionModifierStateTracking {
    var isFunctionPressed: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(isFunctionPressed: Bool) {
        self.isFunctionPressed = isFunctionPressed
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}
