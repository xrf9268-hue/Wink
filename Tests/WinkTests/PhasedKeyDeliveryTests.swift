import AppKit
import Carbon.HIToolbox
import Testing
@testable import Wink

// MARK: - Event-tap route

@Suite("Phased key delivery — event tap")
struct PhasedKeyDeliveryEventTapTests {
    @Test
    func phasedChordDownIsSwallowedAndDeliveredOnPhasedChannelOnly() async {
        let keyPress = KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command])
        let box = EventTapBox()
        box.registeredShortcuts = [keyPress]
        box.phasedChords = [keyPress]
        nonisolated(unsafe) var legacyDeliveries: [KeyPress] = []
        box.onKeyPress = { legacyDeliveries.append($0) }

        let event = makeKeyEvent(keyPress.keyCode, modifiers: keyPress.modifiers, keyDown: true)
        let delivered: (KeyPress, KeyEventPhase) = await withCheckedContinuation { continuation in
            box.setPhasedKeyObserver { deliveredKeyPress, phase in
                continuation.resume(returning: (deliveredKeyPress, phase))
            }
            let result = handleEventTapEvent(type: .keyDown, event: event, box: box)
            #expect(result == nil, "phased chord down must still be swallowed")
        }

        #expect(delivered.0 == keyPress)
        #expect(delivered.1 == .down)
        #expect(legacyDeliveries.isEmpty, "phased chords must bypass onKeyPress")
    }

    @Test
    func phasedChordUpIsSwallowedAndDeliveredAsUp() async {
        let keyPress = KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command])
        let box = EventTapBox()
        box.registeredShortcuts = [keyPress]
        box.phasedChords = [keyPress]

        let event = makeKeyEvent(keyPress.keyCode, modifiers: keyPress.modifiers, keyDown: false)
        let delivered: (KeyPress, KeyEventPhase) = await withCheckedContinuation { continuation in
            box.setPhasedKeyObserver { deliveredKeyPress, phase in
                continuation.resume(returning: (deliveredKeyPress, phase))
            }
            let result = handleEventTapEvent(type: .keyUp, event: event, box: box)
            #expect(result == nil, "phased chord up must be swallowed")
        }

        #expect(delivered.0 == keyPress)
        #expect(delivered.1 == .up)
    }

    @Test
    func nonPhasedRegisteredChordUpPassesThroughUnswallowed() {
        let keyPress = KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command])
        let box = EventTapBox()
        box.registeredShortcuts = [keyPress]
        // No phased chords: the pre-existing contract — only F19's keyUp is
        // ever swallowed — must be preserved bit-for-bit.
        nonisolated(unsafe) var phasedDeliveries = 0
        box.setPhasedKeyObserver { _, _ in phasedDeliveries += 1 }

        let event = makeKeyEvent(keyPress.keyCode, modifiers: keyPress.modifiers, keyDown: false)
        let result = handleEventTapEvent(type: .keyUp, event: event, box: box)

        #expect(result != nil, "non-phased keyUp must pass through to the frontmost app")
        #expect(phasedDeliveries == 0)
    }

    @Test
    func hyperHeldPhasedChordUpMatchesViaModifierUnionRecomputation() async {
        // A Hyper chord's keyUp arrives with plain flags while F19 is still
        // held; identity must be recomputed with the same modifier union as
        // the down edge or the up edge never matches.
        let hyperChord = KeyPress(
            keyCode: CGKeyCode(kVK_ANSI_K),
            modifiers: KeyMatcher.normalizedFlags(
                from: [.control, .option, .shift, .command]
            )
        )
        let box = EventTapBox()
        box.registeredShortcuts = [hyperChord]
        box.phasedChords = [hyperChord]
        box.hyperKeyEnabled = true
        box.isHyperHeld = true

        let event = makeKeyEvent(hyperChord.keyCode, modifiers: [], keyDown: false)
        let delivered: (KeyPress, KeyEventPhase) = await withCheckedContinuation { continuation in
            box.setPhasedKeyObserver { deliveredKeyPress, phase in
                continuation.resume(returning: (deliveredKeyPress, phase))
            }
            let result = handleEventTapEvent(type: .keyUp, event: event, box: box)
            #expect(result == nil)
        }

        #expect(delivered.0 == hyperChord)
        #expect(delivered.1 == .up)
    }

    @Test
    func downThenUpArriveInOrderOnThePhasedChannel() async {
        // Ordering is the reason the phased channel hops through the main
        // dispatch queue instead of per-event Tasks: an up overtaking its
        // down would make a gesture consumer toggle and then open the hold
        // UI from the same physical press.
        let keyPress = KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command])
        let box = EventTapBox()
        box.registeredShortcuts = [keyPress]
        box.phasedChords = [keyPress]

        let phases: [KeyEventPhase] = await withCheckedContinuation { continuation in
            nonisolated(unsafe) var received: [KeyEventPhase] = []
            box.setPhasedKeyObserver { _, phase in
                received.append(phase)
                if received.count == 2 {
                    continuation.resume(returning: received)
                }
            }
            let down = makeKeyEvent(keyPress.keyCode, modifiers: keyPress.modifiers, keyDown: true)
            let up = makeKeyEvent(keyPress.keyCode, modifiers: keyPress.modifiers, keyDown: false)
            #expect(handleEventTapEvent(type: .keyDown, event: down, box: box) == nil)
            #expect(handleEventTapEvent(type: .keyUp, event: up, box: box) == nil)
        }

        #expect(phases == [.down, .up])
    }

    private func makeKeyEvent(
        _ keyCode: CGKeyCode,
        modifiers: NSEvent.ModifierFlags,
        keyDown: Bool
    ) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: keyDown
        )!
        event.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        return event
    }
}

// MARK: - Carbon route

@Suite("Phased key delivery — Carbon")
@MainActor
struct PhasedKeyDeliveryCarbonTests {
    @Test
    func phasedChordRoutesBothEdgesToPhasedObserver() throws {
        let registrar = RecordingCarbonHotKeyRegistrar()
        let handlerFactory = RecordingCarbonHotKeyHandlerFactory(results: [nil])
        let provider = CarbonHotKeyProvider(
            registrationClient: registrar.client,
            handlerFactory: handlerFactory.factory
        )
        let chord = KeyPress(keyCode: CGKeyCode(kVK_ANSI_B), modifiers: [.command, .shift])
        var legacyDeliveries: [KeyPress] = []
        var phasedDeliveries: [(KeyPress, KeyEventPhase)] = []

        provider.updateRegisteredShortcuts([chord])
        provider.updatePhasedChords([chord])
        provider.setPhasedKeyObserver { phasedDeliveries.append(($0, $1)) }
        provider.start { legacyDeliveries.append($0) }

        let identifier = try #require(registrar.registrations.first?.identifier)
        provider.handleHotKeyEvent(identifier: identifier, phase: .down)
        provider.handleHotKeyEvent(identifier: identifier, phase: .up)

        #expect(legacyDeliveries.isEmpty, "phased chords must bypass onKeyPress")
        #expect(phasedDeliveries.map(\.0) == [chord, chord])
        #expect(phasedDeliveries.map(\.1) == [.down, .up])
    }

    @Test
    func nonPhasedChordDropsReleasesAndKeepsDownDelivery() throws {
        let registrar = RecordingCarbonHotKeyRegistrar()
        let handlerFactory = RecordingCarbonHotKeyHandlerFactory(results: [nil])
        let provider = CarbonHotKeyProvider(
            registrationClient: registrar.client,
            handlerFactory: handlerFactory.factory
        )
        let chord = KeyPress(keyCode: CGKeyCode(kVK_ANSI_B), modifiers: [.command])
        var legacyDeliveries: [KeyPress] = []
        var phasedDeliveries = 0

        provider.updateRegisteredShortcuts([chord])
        provider.setPhasedKeyObserver { _, _ in phasedDeliveries += 1 }
        provider.start { legacyDeliveries.append($0) }

        let identifier = try #require(registrar.registrations.first?.identifier)
        // The released EventTypeSpec fires for every registered hotkey; the
        // provider must drop releases for chords without a hold action.
        provider.handleHotKeyEvent(identifier: identifier, phase: .up)
        provider.handleHotKeyEvent(identifier: identifier, phase: .down)

        #expect(legacyDeliveries == [chord])
        #expect(phasedDeliveries == 0)
    }
}

// MARK: - Coordinator plumbing

@Suite("Phased key delivery — coordinator")
@MainActor
struct PhasedKeyDeliveryCoordinatorTests {
    @Test
    func holdActionToggleWithUnchangedChordsStillPropagates() {
        // Toggling holdAction on an existing shortcut leaves the chord sets
        // identical; the coordinator's change guard must treat the phased
        // subset as its own propagation trigger.
        let standard = RecordingPhasedCaptureProvider()
        let hyper = RecordingPhasedHyperCaptureProvider()
        let coordinator = ShortcutCaptureCoordinator(
            standardProvider: standard,
            hyperProvider: hyper
        )
        let base = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command", "shift"]
        )
        coordinator.start(inputMonitoringGranted: true) { _ in }
        coordinator.updateShortcuts([base])
        #expect(standard.phasedChordsUpdates.last == [])

        var withHold = base
        withHold.holdAction = .windowPicker
        coordinator.updateShortcuts([withHold])

        #expect(standard.phasedChordsUpdates.last?.count == 1)

        coordinator.updateShortcuts([base])
        #expect(standard.phasedChordsUpdates.last == [])
    }

    @Test
    func phasedObserverReachesBothProviders() {
        let standard = RecordingPhasedCaptureProvider()
        let hyper = RecordingPhasedHyperCaptureProvider()
        let coordinator = ShortcutCaptureCoordinator(
            standardProvider: standard,
            hyperProvider: hyper
        )

        coordinator.setPhasedKeyObserver { _, _ in }

        #expect(standard.phasedObserverSetCount == 1)
        #expect(hyper.phasedObserverSetCount == 1)
    }
}

@MainActor
private final class RecordingPhasedCaptureProvider: ShortcutCaptureProvider {
    var isRunning = false
    var registrationState = ShortcutCaptureRegistrationState(
        desiredShortcutCount: 0,
        registeredShortcutCount: 0,
        failures: []
    )
    private(set) var phasedChordsUpdates: [Set<KeyPress>] = []
    private(set) var phasedObserverSetCount = 0

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {}

    func updatePhasedChords(_ keyPresses: Set<KeyPress>) {
        phasedChordsUpdates.append(keyPresses)
    }

    func setPhasedKeyObserver(_ observer: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?) {
        phasedObserverSetCount += 1
    }
}

@MainActor
private final class RecordingPhasedHyperCaptureProvider: HyperShortcutCaptureProvider {
    var isRunning = false
    var registrationState = ShortcutCaptureRegistrationState(
        desiredShortcutCount: 0,
        registeredShortcutCount: 0,
        failures: []
    )
    private(set) var phasedChordsUpdates: [Set<KeyPress>] = []
    private(set) var phasedObserverSetCount = 0

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {}

    func setHyperKeyEnabled(_ enabled: Bool) {}

    func updatePhasedChords(_ keyPresses: Set<KeyPress>) {
        phasedChordsUpdates.append(keyPresses)
    }

    func setPhasedKeyObserver(_ observer: (@MainActor @Sendable (KeyPress, KeyEventPhase) -> Void)?) {
        phasedObserverSetCount += 1
    }
}

// MARK: - Model

@Suite("AppShortcut holdAction codability")
struct HoldActionCodabilityTests {
    @Test
    func unknownHoldActionDecodesToNilInsteadOfQuarantiningTheFile() throws {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "appName": "Safari",
            "bundleIdentifier": "com.apple.Safari",
            "keyEquivalent": "s",
            "modifierFlags": ["command"],
            "isEnabled": true,
            "holdAction": "teleport"
        }
        """
        let shortcut = try JSONDecoder().decode(AppShortcut.self, from: Data(json.utf8))
        #expect(shortcut.holdAction == nil)
    }

    @Test
    func holdActionRoundTripsAndNilOmitsTheKey() throws {
        var shortcut = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
        let plainData = try JSONEncoder().encode(shortcut)
        let plainJSON = String(decoding: plainData, as: UTF8.self)
        #expect(!plainJSON.contains("holdAction"), "nil must omit the key so older builds read newer files")

        shortcut.holdAction = .windowPicker
        let decoded = try JSONDecoder().decode(
            AppShortcut.self,
            from: try JSONEncoder().encode(shortcut)
        )
        #expect(decoded.holdAction == .windowPicker)
    }
}
