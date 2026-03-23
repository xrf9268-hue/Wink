import Foundation
import Testing
@testable import Quickey

private struct FakePermissionService: PermissionServicing {
    let ax: Bool
    let input: Bool

    func isTrusted() -> Bool {
        ax && input
    }

    func isAccessibilityTrusted() -> Bool {
        ax
    }

    func isInputMonitoringTrusted() -> Bool {
        input
    }

    @discardableResult
    func requestIfNeeded(prompt: Bool) -> Bool {
        isTrusted()
    }
}

private final class MutablePermissionService: @unchecked Sendable, PermissionServicing {
    var ax: Bool
    var input: Bool

    init(ax: Bool, input: Bool) {
        self.ax = ax
        self.input = input
    }

    func isTrusted() -> Bool {
        ax && input
    }

    func isAccessibilityTrusted() -> Bool {
        ax
    }

    func isInputMonitoringTrusted() -> Bool {
        input
    }

    @discardableResult
    func requestIfNeeded(prompt: Bool) -> Bool {
        isTrusted()
    }
}

@MainActor
private final class FakeEventTapManager: EventTapManaging {
    var isRunning: Bool = false
    private let startResult: EventTapStartResult
    private(set) var startCallCount: Int = 0
    private(set) var stopCallCount: Int = 0

    init(startResult: EventTapStartResult = .started) {
        self.startResult = startResult
    }

    func start(onKeyPress: @escaping (KeyPress) -> Bool) -> EventTapStartResult {
        startCallCount += 1
        if startResult == .started {
            isRunning = true
        }
        return startResult
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {}

    func setHyperKeyEnabled(_ enabled: Bool) {}
}

@MainActor
private struct FakeAppSwitcher: AppSwitching {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut) -> Bool {
        true
    }
}

@MainActor
private func makeShortcutManager(
    permissionService: some PermissionServicing,
    eventTapManager: some EventTapManaging
) -> ShortcutManager {
    ShortcutManager(
        shortcutStore: ShortcutStore(),
        persistenceService: PersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        eventTapManager: eventTapManager,
        permissionService: permissionService
    )
}

@Test @MainActor
func captureStatusShowsInputMonitoringMissingSeparately() {
    let manager = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false),
        eventTapManager: FakeEventTapManager()
    )

    let status = manager.shortcutCaptureStatus()

    #expect(status.accessibilityGranted == true)
    #expect(status.inputMonitoringGranted == false)
    #expect(status.ready == false)
}

@Test @MainActor
func failedActiveTapDoesNotReportReady() {
    let tap = FakeEventTapManager(startResult: .failedToCreateTap)
    let manager = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: true),
        eventTapManager: tap
    )

    manager.start()
    let status = manager.shortcutCaptureStatus()

    #expect(status.eventTapActive == false)
    #expect(status.ready == false)

    manager.stop()
}

@Test @MainActor
func permissionGainStartsEventTapWhenNotRunning() {
    let permissionService = MutablePermissionService(ax: true, input: true)
    let eventTapManager = FakeEventTapManager()
    let manager = makeShortcutManager(
        permissionService: permissionService,
        eventTapManager: eventTapManager
    )

    manager.checkPermissionChange()

    #expect(eventTapManager.startCallCount == 1)
    #expect(eventTapManager.isRunning == true)
}

@Test @MainActor
func permissionLossStopsRunningEventTap() {
    let permissionService = MutablePermissionService(ax: false, input: false)
    let eventTapManager = FakeEventTapManager()
    eventTapManager.isRunning = true
    let manager = makeShortcutManager(
        permissionService: permissionService,
        eventTapManager: eventTapManager
    )

    manager.checkPermissionChange()

    #expect(eventTapManager.stopCallCount == 1)
    #expect(eventTapManager.isRunning == false)
}
