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

@MainActor
private final class FakeEventTapManager: EventTapManaging {
    var isRunning: Bool = false
    private let startResult: EventTapStartResult

    init(startResult: EventTapStartResult = .started) {
        self.startResult = startResult
    }

    func start(onKeyPress: @escaping (KeyPress) -> Bool) -> EventTapStartResult {
        if startResult == .started {
            isRunning = true
        }
        return startResult
    }

    func stop() {
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
