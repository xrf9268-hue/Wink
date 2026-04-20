import AppKit
import Carbon.HIToolbox
import Testing
@testable import Wink

@MainActor
private final class FakeEventTapManager: EventTapManaging {
    private(set) var isRunning = false
    private(set) var registeredShortcuts: Set<KeyPress> = []
    private(set) var setHyperEnabledCalls: [(enabled: Bool, whileRunning: Bool)] = []

    func start(onKeyPress: @escaping (KeyPress) -> Bool) -> EventTapStartResult {
        isRunning = true
        return .started
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {
        registeredShortcuts = keyPresses
    }

    func setHyperKeyEnabled(_ enabled: Bool) {
        setHyperEnabledCalls.append((enabled: enabled, whileRunning: isRunning))
    }
}

@Test @MainActor
func pendingHyperEnableIsReappliedAfterEventTapStarts() {
    let manager = FakeEventTapManager()
    let provider = EventTapCaptureProvider(manager: manager)
    let hyperShortcut = KeyPress(
        keyCode: CGKeyCode(kVK_ANSI_A),
        modifiers: [.command, .option, .control, .shift]
    )

    provider.updateRegisteredShortcuts([hyperShortcut])
    provider.setHyperKeyEnabled(true)

    #expect(manager.setHyperEnabledCalls.count == 1)
    #expect(manager.setHyperEnabledCalls[0].enabled == true)
    #expect(manager.setHyperEnabledCalls[0].whileRunning == false)

    provider.start { _ in }

    #expect(manager.isRunning == true)
    #expect(
        manager.setHyperEnabledCalls.contains(where: { $0.enabled == true && $0.whileRunning }),
        "Hyper enable should be replayed after the event tap is running."
    )
}
