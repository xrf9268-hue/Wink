import AppKit
import Carbon.HIToolbox
import Testing
@testable import Wink

@Suite("CarbonHotKeyProvider")
struct CarbonHotKeyProviderTests {
    @Test @MainActor
    func functionTrackerSeedsOnlyTheCurrentPhysicalFunctionKeyState() {
        let tapClient = RecordingFunctionModifierEventTapClient()
        var physicalFunctionKeyPressed = true
        var currentTimestamp: CGEventTimestamp = 100_000_000
        let tracker = CGEventTapFunctionModifierStateTracker(
            systemState: FunctionModifierSystemStateClient(
                isPhysicalFunctionKeyPressed: { physicalFunctionKeyPressed },
                currentEventTimestamp: { currentTimestamp }
            ),
            tapClient: tapClient.client
        )

        #expect(tracker.start())
        tapClient.sessions.last?.recordFunctionRowKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            timestamp: 101_000_000
        )
        #expect(tracker.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 101_500_000
        ))

        tracker.stop()
        physicalFunctionKeyPressed = false
        currentTimestamp = 200_000_000
        #expect(tracker.start())
        tapClient.sessions.last?.recordFunctionRowKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            timestamp: 201_000_000
        )
        #expect(!tracker.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 201_500_000
        ))
        tracker.stop()
    }

    @Test @MainActor
    func functionTrackerFailsClosedAndRetriesAfterTapCreationFailure() {
        let tapClient = RecordingFunctionModifierEventTapClient(startSucceeds: false)
        let tracker = CGEventTapFunctionModifierStateTracker(
            systemState: FunctionModifierSystemStateClient(
                isPhysicalFunctionKeyPressed: { false }
            ),
            tapClient: tapClient.client
        )

        #expect(!tracker.start())

        tapClient.startSucceeds = true
        #expect(tracker.start())
        #expect(tapClient.startCount == 2)
        tracker.stop()
        #expect(tapClient.sessions.last?.stopCount == 1)
    }

    @Test @MainActor
    func functionTrackerDoesNotOverwriteATransitionObservedWhileTheTapStarts() {
        let tapClient = RecordingFunctionModifierEventTapClient()
        tapClient.functionTransitionObservedOnStart = false
        let tracker = CGEventTapFunctionModifierStateTracker(
            systemState: FunctionModifierSystemStateClient(
                isPhysicalFunctionKeyPressed: { true }
            ),
            tapClient: tapClient.client
        )

        #expect(tracker.start())
        tapClient.sessions.last?.recordFunctionRowKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            timestamp: 100_000_000
        )
        #expect(!tracker.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 100_500_000
        ))
        tracker.stop()
    }

    @Test @MainActor
    func functionTrackerFailsClosedWhenInputMonitoringIsRevoked() throws {
        let tapClient = RecordingFunctionModifierEventTapClient()
        let tracker = CGEventTapFunctionModifierStateTracker(
            systemState: FunctionModifierSystemStateClient(
                isPhysicalFunctionKeyPressed: { true }
            ),
            tapClient: tapClient.client
        )

        #expect(tracker.start())
        let session = try #require(tapClient.sessions.last)
        session.recordFunctionRowKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            timestamp: 100_000_000
        )
        #expect(tracker.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 100_500_000
        ))
        session.recordFunctionRowKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            timestamp: 101_000_000
        )

        tapClient.inputMonitoringGranted = false
        #expect(!tracker.start())
        #expect(!tracker.isReady)
        #expect(!tracker.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 101_500_000
        ))
        #expect(session.stopCount == 1)
    }

    @Test @MainActor
    func functionTrackerUsesTheFunctionStateAtTheFunctionRowKeyDown() throws {
        let tapClient = RecordingFunctionModifierEventTapClient()
        let tracker = CGEventTapFunctionModifierStateTracker(
            systemState: FunctionModifierSystemStateClient(
                isPhysicalFunctionKeyPressed: { false }
            ),
            tapClient: tapClient.client
        )

        #expect(tracker.start())
        let session = try #require(tapClient.sessions.last)
        session.recordFunctionTransition(isPressed: true, timestamp: 100_000_000)
        session.recordFunctionRowKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            timestamp: 150_000_000
        )
        session.recordFunctionTransition(isPressed: false, timestamp: 151_000_000)

        #expect(tracker.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 150_720_542
        ))
        tracker.stop()
    }

    @Test @MainActor
    func functionTrackerRejectsFnPressedAfterTheFunctionRowKeyDown() throws {
        let tapClient = RecordingFunctionModifierEventTapClient()
        let tracker = CGEventTapFunctionModifierStateTracker(
            systemState: FunctionModifierSystemStateClient(
                isPhysicalFunctionKeyPressed: { false }
            ),
            tapClient: tapClient.client
        )

        #expect(tracker.start())
        let session = try #require(tapClient.sessions.last)
        session.recordFunctionRowKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            timestamp: 150_000_000
        )
        session.recordFunctionTransition(isPressed: true, timestamp: 200_000_000)

        #expect(!tracker.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 150_534_125
        ))
        tracker.stop()
    }

    @Test
    func functionModifierTapTracksOnlyPhysicalFnAndFailsClosedWhenDisabled() throws {
        let box = FunctionModifierTapBox()
        box.markActive()

        let f6 = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_F6),
            keyDown: true
        ))
        f6.type = .flagsChanged
        f6.flags = [.maskSecondaryFn]
        _ = handleFunctionModifierTapEvent(type: .flagsChanged, event: f6, box: box)
        #expect(!box.snapshot.isFunctionPressed)

        let fn = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Function),
            keyDown: true
        ))
        fn.type = .flagsChanged
        fn.flags = [.maskSecondaryFn]
        _ = handleFunctionModifierTapEvent(type: .flagsChanged, event: fn, box: box)
        #expect(box.snapshot.isFunctionPressed)

        let f6KeyDown = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_F6),
            keyDown: true
        ))
        f6KeyDown.timestamp = 150_000_000
        _ = handleFunctionModifierTapEvent(type: .keyDown, event: f6KeyDown, box: box)
        #expect(box.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 150_720_542
        ))

        f6KeyDown.timestamp = 160_000_000
        _ = handleFunctionModifierTapEvent(type: .keyDown, event: f6KeyDown, box: box)

        _ = handleFunctionModifierTapEvent(type: .tapDisabledByUserInput, event: fn, box: box)
        #expect(!box.snapshot.isActive)
        #expect(!box.snapshot.isFunctionPressed)
        #expect(!box.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 160_720_542
        ))
    }

    @Test
    func functionRowKeyDownSnapshotsFnStateForTheDelayedCarbonCallback() {
        let box = FunctionModifierTapBox()
        box.markActive()

        box.recordFunctionTransition(isPressed: true, timestamp: 100_000_000)
        #expect(box.recordFunctionRowKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            timestamp: 150_000_000
        ))
        box.recordFunctionTransition(isPressed: false, timestamp: 151_000_000)

        #expect(!box.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F5),
            carbonTimestamp: 150_720_542
        ))
        #expect(box.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 150_720_542
        ))
        #expect(!box.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 150_720_542
        ))
    }

    @Test
    func laterFnDownCannotAuthorizeAnEarlierBareFunctionRowKeyDown() {
        let box = FunctionModifierTapBox()
        box.markActive()

        #expect(!box.recordFunctionRowKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            timestamp: 200_000_000
        ))
        box.recordFunctionTransition(isPressed: true, timestamp: 201_000_000)

        #expect(!box.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 200_534_125
        ))
    }

    @Test
    func functionFlagOnFunctionRowKeyDownDoesNotReplacePhysicalFnObservation() throws {
        let box = FunctionModifierTapBox()
        box.markActive()
        let f6 = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_F6),
            keyDown: true
        ))
        f6.flags = [.maskSecondaryFn]
        f6.timestamp = 300_000_000

        _ = handleFunctionModifierTapEvent(type: .keyDown, event: f6, box: box)

        #expect(!box.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 300_720_542
        ))
    }

    @Test
    func functionRowAutorepeatCannotCreateAConsumableObservation() throws {
        let box = FunctionModifierTapBox()
        box.markActive()
        box.recordFunctionTransition(isPressed: true, timestamp: 350_000_000)
        let f6 = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_F6),
            keyDown: true
        ))
        f6.timestamp = 400_000_000
        f6.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        _ = handleFunctionModifierTapEvent(type: .keyDown, event: f6, box: box)

        #expect(!box.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 400_720_542
        ))
    }

    @Test
    func staleFunctionRowKeyDownObservationFailsClosed() {
        let box = FunctionModifierTapBox()
        box.markActive()
        box.recordFunctionTransition(isPressed: true, timestamp: 100_000_000)
        box.recordFunctionRowKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            timestamp: 150_000_000
        )

        #expect(!box.consumeFunctionModifiedKeyDown(
            keyCode: CGKeyCode(kVK_F6),
            carbonTimestamp: 200_000_001
        ))
    }

    @Test
    func carbonEventTimeConvertsToTheCGEventTimestampClock() {
        #expect(cgEventTimestamp(fromCarbonEventTime: 1.25) == 1_250_000_000)
        #expect(cgEventTimestamp(fromCarbonEventTime: 0) == 0)
        #expect(cgEventTimestamp(fromCarbonEventTime: .infinity) == 0)
    }

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
        #expect(!provider.inputMonitoringRequired)
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
        #expect(!provider.inputMonitoringRequired)
        provider.start { delivered.append($0) }
        defer { provider.stop() }

        let registration = try #require(registrar.registrations.first)
        #expect(modifierState.startCount == 0)
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
        #expect(provider.inputMonitoringRequired)
        provider.start { delivered.append($0) }

        let registration = try #require(registrar.registrations.first)
        provider.handleHotKeyEvent(
            identifier: registration.identifier,
            eventTimestamp: 123
        )
        #expect(delivered.isEmpty)
        #expect(modifierState.startCount == 1)

        modifierState.isFunctionPressed = true
        provider.handleHotKeyEvent(
            identifier: registration.identifier,
            eventTimestamp: 456
        )
        #expect(delivered == [shortcut])
        #expect(modifierState.requestedKeyCodes == [CGKeyCode(kVK_F6), CGKeyCode(kVK_F6)])
        #expect(modifierState.requestedEventTimestamps == [123, 456])

        provider.stop()
        #expect(modifierState.stopCount == 1)
    }

    @Test @MainActor
    func fnFunctionKeyRegistrationFailsClosedAndRetriesWhenTrackingIsUnavailable() throws {
        let registrar = RecordingCarbonHotKeyRegistrar()
        let modifierState = RecordingFunctionModifierStateTracker(
            isFunctionPressed: false,
            startSucceeds: false
        )
        let provider = CarbonHotKeyProvider(
            registrationClient: registrar.client,
            functionModifierStateTracker: modifierState
        )
        let shortcut = KeyPress(
            keyCode: CGKeyCode(kVK_F6),
            modifiers: [.function]
        )

        provider.updateRegisteredShortcuts([shortcut])
        provider.start { _ in }

        #expect(registrar.registrations.isEmpty)
        #expect(provider.registrationState.desiredShortcutCount == 1)
        #expect(provider.registrationState.registeredShortcutCount == 0)
        #expect(provider.registrationState.failures == [
            ShortcutCaptureRegistrationFailure(
                keyPress: shortcut,
                status: Int32(eventInternalErr)
            ),
        ])

        modifierState.startSucceeds = true
        provider.start { _ in }
        #expect(try #require(registrar.registrations.first).keyCode == UInt32(kVK_F6))
        #expect(provider.registrationState.allDesiredShortcutsRegistered)
        provider.stop()
    }

    @Test @MainActor
    func unavailableFunctionTrackingPreservesOrdinaryCarbonRegistrations() throws {
        let registrar = RecordingCarbonHotKeyRegistrar()
        let modifierState = RecordingFunctionModifierStateTracker(
            isFunctionPressed: false,
            startSucceeds: false
        )
        let provider = CarbonHotKeyProvider(
            registrationClient: registrar.client,
            functionModifierStateTracker: modifierState
        )
        let ordinaryShortcut = KeyPress(
            keyCode: CGKeyCode(kVK_ANSI_A),
            modifiers: [.command]
        )
        let functionShortcut = KeyPress(
            keyCode: CGKeyCode(kVK_F6),
            modifiers: [.function]
        )
        var delivered: [KeyPress] = []

        provider.updateRegisteredShortcuts([ordinaryShortcut, functionShortcut])
        provider.start { delivered.append($0) }

        #expect(registrar.registrations.count == 1)
        #expect(registrar.registrations.first?.keyCode == UInt32(kVK_ANSI_A))
        #expect(provider.registrationState.desiredShortcutCount == 2)
        #expect(provider.registrationState.registeredShortcutCount == 1)
        #expect(provider.registrationState.failures.map(\.keyPress) == [functionShortcut])
        registrar.deliver(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(cmdKey),
            to: provider
        )
        #expect(delivered == [ordinaryShortcut])

        modifierState.startSucceeds = true
        provider.start { _ in }

        #expect(registrar.registrations.count == 2)
        #expect(provider.registrationState.allDesiredShortcutsRegistered)
        provider.stop()
    }

    @Test @MainActor
    func handlerInstallFailureRollsBackSuccessfulRegistrationsAndRetriesCleanly() throws {
        let registrar = RecordingCarbonHotKeyRegistrar()
        let handlerFactory = RecordingCarbonHotKeyHandlerFactory(
            results: [Int32(eventInternalErr), nil]
        )
        let provider = CarbonHotKeyProvider(
            registrationClient: registrar.client,
            handlerFactory: handlerFactory.factory
        )
        let shortcut = KeyPress(
            keyCode: CGKeyCode(kVK_ANSI_A),
            modifiers: [.command]
        )
        var delivered: [KeyPress] = []

        provider.updateRegisteredShortcuts([shortcut])
        provider.start { delivered.append($0) }

        let failedIdentifier = try #require(registrar.attempts.first?.identifier)
        #expect(handlerFactory.installCount == 1)
        #expect(registrar.attempts.count == 1)
        #expect(registrar.registrations.isEmpty)
        #expect(registrar.unregisteredIdentifiers == [failedIdentifier])
        #expect(!provider.isRunning)
        #expect(provider.registrationState.desiredShortcutCount == 1)
        #expect(provider.registrationState.registeredShortcutCount == 0)
        #expect(provider.registrationState.handlerState == .installationFailed(
            status: Int32(eventInternalErr)
        ))

        provider.handleHotKeyEvent(identifier: failedIdentifier)
        #expect(delivered.isEmpty)

        provider.updateRegisteredShortcuts([shortcut])

        let recoveredRegistration = try #require(registrar.registrations.first)
        let recoveredSession = try #require(handlerFactory.sessions.first)
        #expect(handlerFactory.installCount == 2)
        #expect(registrar.attempts.count == 2)
        #expect(registrar.registrations.count == 1)
        #expect(recoveredRegistration.identifier != failedIdentifier)
        #expect(provider.isRunning)
        #expect(provider.registrationState.handlerState == .installed)
        #expect(provider.registrationState.allDesiredShortcutsRegistered)

        // The production coordinator calls update followed by start during a
        // retry. Once update recovered the complete set, start must only
        // replace the delivery closure rather than reconcile it a second time.
        provider.start { delivered.append($0) }
        #expect(registrar.attempts.count == 2)
        #expect(registrar.registrations.map(\.identifier) == [recoveredRegistration.identifier])

        recoveredSession.emit(identifier: recoveredRegistration.identifier)
        #expect(delivered == [shortcut])
        recoveredSession.emit(identifier: failedIdentifier)
        #expect(delivered == [shortcut])

        provider.stop()

        #expect(registrar.registrations.isEmpty)
        #expect(recoveredSession.stopCount == 1)
        #expect(provider.registrationState.handlerState == .notInstalled)
        #expect(provider.registrationState.failures.isEmpty)
        recoveredSession.emit(identifier: recoveredRegistration.identifier)
        #expect(delivered == [shortcut])

        provider.stop()
        #expect(recoveredSession.stopCount == 1)
    }

    @Test @MainActor
    func stopClearsHandlerInstallationFailure() {
        let registrar = RecordingCarbonHotKeyRegistrar()
        let handlerFactory = RecordingCarbonHotKeyHandlerFactory(
            results: [Int32(eventInternalErr)]
        )
        let provider = CarbonHotKeyProvider(
            registrationClient: registrar.client,
            handlerFactory: handlerFactory.factory
        )

        provider.updateRegisteredShortcuts([
            KeyPress(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: [.command]),
        ])
        provider.start { _ in }
        #expect(provider.registrationState.handlerState == .installationFailed(
            status: Int32(eventInternalErr)
        ))

        provider.stop()

        #expect(provider.registrationState.handlerState == .notInstalled)
        #expect(provider.registrationState.failures.isEmpty)
        #expect(registrar.registrations.isEmpty)
    }

    @Test @MainActor
    func coordinatorRecoveryRegistersTheIntendedSetOnlyOnce() {
        let registrar = RecordingCarbonHotKeyRegistrar()
        let handlerFactory = RecordingCarbonHotKeyHandlerFactory(
            results: [Int32(eventInternalErr), nil]
        )
        let provider = CarbonHotKeyProvider(
            registrationClient: registrar.client,
            handlerFactory: handlerFactory.factory
        )
        let coordinator = ShortcutCaptureCoordinator(
            standardProvider: provider,
            hyperProvider: NoopHyperCaptureProvider()
        )
        coordinator.updateShortcuts([
            AppShortcut(
                appName: "Test",
                bundleIdentifier: "com.example.test",
                keyEquivalent: "a",
                modifierFlags: ["command"]
            ),
        ])

        coordinator.start(inputMonitoringGranted: false) { _ in }
        #expect(registrar.attempts.count == 1)
        #expect(registrar.registrations.isEmpty)

        // Match ShortcutManager's not-ready poll sequence. Recovery happens in
        // the first update; every following unchanged sync must preserve it.
        coordinator.refreshInputMonitoring(granted: false)
        coordinator.setHyperKeyEnabled(false)
        coordinator.setCapturePaused(false)
        coordinator.start(inputMonitoringGranted: false) { _ in }

        #expect(handlerFactory.installCount == 2)
        #expect(registrar.attempts.count == 2)
        #expect(registrar.registrations.count == 1)
        let status = coordinator.status(
            accessibilityGranted: true,
            inputMonitoringGranted: false
        )
        #expect(status.carbonHotKeysRegistered)
        #expect(status.standardShortcutsReady)
        coordinator.stop()
    }
}

@MainActor
private final class RecordingCarbonHotKeyRegistrar {
    struct Registration {
        let keyCode: UInt32
        let modifiers: UInt32
        let identifier: UInt32
    }

    private(set) var attempts: [Registration] = []
    private(set) var registrations: [Registration] = []
    private(set) var unregisteredIdentifiers: [UInt32] = []

    lazy var client = CarbonHotKeyRegistrationClient(
        register: { [unowned self] keyCode, modifiers, hotKeyID in
            let registration = Registration(
                keyCode: keyCode,
                modifiers: modifiers,
                identifier: hotKeyID.id
            )
            attempts.append(registration)
            registrations.append(registration)
            return (noErr, OpaquePointer(bitPattern: Int(hotKeyID.id)))
        },
        unregister: { [unowned self] hotKeyRef in
            if let registration = registrations.first(where: {
                OpaquePointer(bitPattern: Int($0.identifier)) == hotKeyRef
            }) {
                unregisteredIdentifiers.append(registration.identifier)
            }
            registrations.removeAll {
                OpaquePointer(bitPattern: Int($0.identifier)) == hotKeyRef
            }
        }
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
private final class RecordingCarbonHotKeyHandlerFactory {
    private var results: [Int32?]
    private(set) var installCount = 0
    private(set) var sessions: [RecordingCarbonHotKeyHandlerSession] = []

    init(results: [Int32?]) {
        self.results = results
    }

    lazy var factory = CarbonHotKeyHandlerFactory { [unowned self] delivery in
        installCount += 1
        let result = results.isEmpty ? nil : results.removeFirst()
        if let status = result {
            return .failed(status)
        }

        let session = RecordingCarbonHotKeyHandlerSession(delivery: delivery)
        sessions.append(session)
        return .installed(session)
    }
}

@MainActor
private final class RecordingCarbonHotKeyHandlerSession: CarbonHotKeyHandlerSession {
    private let delivery: CarbonHotKeyDelivery
    private(set) var isLive = true
    private(set) var stopCount = 0

    init(delivery: @escaping CarbonHotKeyDelivery) {
        self.delivery = delivery
    }

    func stop() {
        guard isLive else { return }
        isLive = false
        stopCount += 1
    }

    func emit(identifier: UInt32, timestamp: CGEventTimestamp = .max) {
        delivery(identifier, timestamp)
    }
}

@MainActor
private final class NoopHyperCaptureProvider: HyperShortcutCaptureProvider {
    var isRunning = false
    var registrationState = ShortcutCaptureRegistrationState(
        desiredShortcutCount: 0,
        registeredShortcutCount: 0,
        failures: []
    )

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {}
    func stop() { isRunning = false }
    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {}
    func setHyperKeyEnabled(_ enabled: Bool) {}
}

@MainActor
private final class RecordingFunctionModifierStateTracker: FunctionModifierStateTracking {
    var isFunctionPressed: Bool
    var startSucceeds: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var requestedKeyCodes: [CGKeyCode] = []
    private(set) var requestedEventTimestamps: [CGEventTimestamp] = []

    init(isFunctionPressed: Bool, startSucceeds: Bool = true) {
        self.isFunctionPressed = isFunctionPressed
        self.startSucceeds = startSucceeds
    }

    var isReady: Bool {
        startSucceeds
    }

    func start() -> Bool {
        startCount += 1
        return startSucceeds
    }

    func consumeFunctionModifiedKeyDown(
        keyCode: CGKeyCode,
        carbonTimestamp: CGEventTimestamp
    ) -> Bool {
        requestedKeyCodes.append(keyCode)
        requestedEventTimestamps.append(carbonTimestamp)
        return isFunctionPressed
    }

    func stop() {
        stopCount += 1
    }
}

@MainActor
private final class RecordingFunctionModifierEventTapClient {
    var startSucceeds: Bool
    var inputMonitoringGranted = true
    var functionTransitionObservedOnStart: Bool?
    private(set) var startCount = 0
    private(set) var sessions: [RecordingFunctionModifierEventTapSession] = []

    init(startSucceeds: Bool = true) {
        self.startSucceeds = startSucceeds
    }

    lazy var client = FunctionModifierEventTapClient(
        inputMonitoringGranted: { [unowned self] in inputMonitoringGranted },
        start: { [unowned self] in
            startCount += 1
            guard startSucceeds else { return nil }

            let session = RecordingFunctionModifierEventTapSession()
            if let functionTransitionObservedOnStart {
                session.recordFunctionTransition(isPressed: functionTransitionObservedOnStart)
            }
            sessions.append(session)
            return session
        }
    )
}

private final class RecordingFunctionModifierEventTapSession: FunctionModifierEventTapSessionProtocol {
    private let box = FunctionModifierTapBox()
    private let lock = NSLock()
    private(set) var stopCount = 0

    init() {
        box.markActive()
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

    func recordFunctionTransition(
        isPressed: Bool,
        timestamp: CGEventTimestamp = .max
    ) {
        box.recordFunctionTransition(isPressed: isPressed, timestamp: timestamp)
    }

    func recordFunctionRowKeyDown(
        keyCode: CGKeyCode,
        timestamp: CGEventTimestamp
    ) {
        box.recordFunctionRowKeyDown(keyCode: keyCode, timestamp: timestamp)
    }

    func stop() {
        lock.withLock {
            stopCount += 1
        }
        box.failClosed()
    }
}
