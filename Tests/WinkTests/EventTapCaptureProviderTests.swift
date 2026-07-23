import AppKit
import Carbon.HIToolbox
import Testing
@testable import Wink

@MainActor
private final class FakeEventTapManager: EventTapManaging {
    private(set) var isRunning = false
    private(set) var registeredShortcuts: Set<KeyPress> = []
    private(set) var setHyperEnabledCalls: [(enabled: Bool, whileRunning: Bool)] = []
    private(set) var setHyperReleaseDeferralSuppressedCalls: [(suppressed: Bool, whileRunning: Bool)] = []

    func start(onKeyPress: @escaping @MainActor (KeyPress) -> Bool) -> EventTapStartResult {
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

    func setHyperReleaseDeferralSuppressed(_ suppressed: Bool) {
        setHyperReleaseDeferralSuppressedCalls.append((suppressed: suppressed, whileRunning: isRunning))
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

@Test @MainActor
func pendingHyperReleaseDeferralSuppressionIsReappliedAfterEventTapStarts() {
    // #385: a panel session can suppress the release deferral before the
    // provider has an underlying running tap (e.g. immediately after a
    // stop/start cycle); the suppression must survive to be replayed once
    // the tap is actually running, same shape as pendingHyperKeyEnabled.
    let manager = FakeEventTapManager()
    let provider = EventTapCaptureProvider(manager: manager)

    provider.setHyperReleaseDeferralSuppressed(true)

    #expect(manager.setHyperReleaseDeferralSuppressedCalls.count == 1)
    #expect(manager.setHyperReleaseDeferralSuppressedCalls[0].suppressed == true)
    #expect(manager.setHyperReleaseDeferralSuppressedCalls[0].whileRunning == false)

    provider.start { _ in }

    #expect(manager.isRunning == true)
    #expect(
        manager.setHyperReleaseDeferralSuppressedCalls.contains(where: { $0.suppressed == true && $0.whileRunning }),
        "Suppression should be replayed after the event tap is running."
    )
}
