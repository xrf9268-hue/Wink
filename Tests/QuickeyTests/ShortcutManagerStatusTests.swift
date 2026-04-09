import Carbon.HIToolbox
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
private final class FakeCaptureProvider: ShortcutCaptureProvider {
    var isRunning = false
    var startSucceeds = true
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var registeredShortcuts: Set<KeyPress> = []
    private var onKeyPress: (@MainActor @Sendable (KeyPress) -> Void)?

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        startCallCount += 1
        self.onKeyPress = onKeyPress
        isRunning = startSucceeds && !registeredShortcuts.isEmpty
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
        onKeyPress = nil
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {
        registeredShortcuts = keyPresses
        if keyPresses.isEmpty {
            isRunning = false
        }
    }

    func emit(_ keyPress: KeyPress) {
        onKeyPress?(keyPress)
    }
}

@MainActor
private final class FakeHyperCaptureProvider: HyperShortcutCaptureProvider {
    var isRunning = false
    var startSucceeds = true
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var registeredShortcuts: Set<KeyPress> = []
    private(set) var hyperKeyEnabled = false
    private var onKeyPress: (@MainActor @Sendable (KeyPress) -> Void)?

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        startCallCount += 1
        self.onKeyPress = onKeyPress
        isRunning = startSucceeds && !registeredShortcuts.isEmpty
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
        onKeyPress = nil
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {
        registeredShortcuts = keyPresses
        if keyPresses.isEmpty {
            isRunning = false
        }
    }

    func setHyperKeyEnabled(_ enabled: Bool) {
        hyperKeyEnabled = enabled
    }

    func emit(_ keyPress: KeyPress) {
        onKeyPress?(keyPress)
    }
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
    standardProvider: FakeCaptureProvider = FakeCaptureProvider(),
    hyperProvider: FakeHyperCaptureProvider = FakeHyperCaptureProvider(),
    diagnosticSink: @escaping @Sendable (String) -> Void = { _ in }
) -> (ShortcutManager, FakeCaptureProvider, FakeHyperCaptureProvider) {
    let coordinator = ShortcutCaptureCoordinator(
        standardProvider: standardProvider,
        hyperProvider: hyperProvider
    )
    let manager = ShortcutManager(
        shortcutStore: ShortcutStore(),
        persistenceService: PersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: coordinator,
        permissionService: permissionService,
        diagnosticClient: .init(log: diagnosticSink)
    )
    return (manager, standardProvider, hyperProvider)
}

private func standardShortcut() -> AppShortcut {
    AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )
}

private func hyperShortcut() -> AppShortcut {
    AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "option", "control", "shift"]
    )
}

@Test @MainActor
func captureStatusKeepsStandardShortcutsReadyWhenInputMonitoringIsMissing() {
    let (manager, standardProvider, hyperProvider) = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false)
    )
    manager.save(shortcuts: [standardShortcut()])
    manager.start()

    let status = manager.shortcutCaptureStatus()

    #expect(status.accessibilityGranted == true)
    #expect(status.inputMonitoringGranted == false)
    #expect(status.carbonHotKeysRegistered == true)
    #expect(status.eventTapActive == false)
    #expect(status.standardShortcutsReady == true)
    #expect(status.hyperShortcutsReady == true)
    #expect(standardProvider.startCallCount == 1)
    #expect(hyperProvider.startCallCount == 0)

    manager.stop()
}

@Test @MainActor
func hyperShortcutsNeedInputMonitoringAndDoNotStartEventTapWithoutIt() {
    let (manager, standardProvider, hyperProvider) = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false)
    )
    manager.save(shortcuts: [hyperShortcut()])
    manager.setHyperKeyEnabled(true)
    manager.start()

    let status = manager.shortcutCaptureStatus()

    #expect(status.carbonHotKeysRegistered == false)
    #expect(status.eventTapActive == false)
    #expect(status.standardShortcutsReady == true)
    #expect(status.hyperShortcutsReady == false)
    #expect(standardProvider.startCallCount == 0)
    #expect(hyperProvider.startCallCount == 0)

    manager.stop()
}

@Test @MainActor
func hyperRoutingFollowsHyperKeyToggle() {
    #expect(ShortcutCaptureRoute.route(for: hyperShortcut(), hyperKeyEnabled: false) == .standard)
    #expect(ShortcutCaptureRoute.route(for: hyperShortcut(), hyperKeyEnabled: true) == .hyper)
    #expect(ShortcutCaptureRoute.route(for: standardShortcut(), hyperKeyEnabled: true) == .standard)
}

@Test @MainActor
func permissionGainStartsStandardCaptureWhenAccessibilityBecomesAvailable() {
    let permissionService = MutablePermissionService(ax: true, input: false)
    let (manager, standardProvider, hyperProvider) = makeShortcutManager(
        permissionService: permissionService
    )
    manager.save(shortcuts: [standardShortcut()])

    manager.checkPermissionChange()

    #expect(standardProvider.startCallCount == 1)
    #expect(standardProvider.isRunning == true)
    #expect(hyperProvider.startCallCount == 0)
}

@Test @MainActor
func accessibilityLossStopsAllShortcutCapture() {
    let permissionService = MutablePermissionService(ax: false, input: false)
    let standardProvider = FakeCaptureProvider()
    let hyperProvider = FakeHyperCaptureProvider()
    standardProvider.isRunning = true
    hyperProvider.isRunning = true
    let coordinator = ShortcutCaptureCoordinator(
        standardProvider: standardProvider,
        hyperProvider: hyperProvider
    )
    let manager = ShortcutManager(
        shortcutStore: ShortcutStore(),
        persistenceService: PersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: coordinator,
        permissionService: permissionService,
        diagnosticClient: .live
    )

    manager.checkPermissionChange()

    #expect(standardProvider.stopCallCount == 1)
    #expect(hyperProvider.stopCallCount == 1)
    #expect(standardProvider.isRunning == false)
    #expect(hyperProvider.isRunning == false)
}

@Test @MainActor
func unchangedPermissionsDoNotResyncCaptureRepeatedly() {
    let permissionService = MutablePermissionService(ax: true, input: false)
    let (manager, standardProvider, hyperProvider) = makeShortcutManager(
        permissionService: permissionService
    )
    manager.save(shortcuts: [standardShortcut()])
    manager.start()

    let standardStartsAfterLaunch = standardProvider.startCallCount
    let hyperStartsAfterLaunch = hyperProvider.startCallCount

    manager.checkPermissionChange()

    #expect(standardProvider.startCallCount == standardStartsAfterLaunch)
    #expect(hyperProvider.startCallCount == hyperStartsAfterLaunch)
}

@Test @MainActor
func matchedShortcutEmitsTraceOnlyForMatchedKeys() {
    let diagnostics = DiagnosticCapture()
    let standardProvider = FakeCaptureProvider()
    let (manager, _, _) = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false),
        standardProvider: standardProvider,
        diagnosticSink: diagnostics.record
    )
    manager.save(shortcuts: [standardShortcut()])
    manager.start()

    standardProvider.emit(KeyPress(
        keyCode: UInt16(kVK_ANSI_S),
        modifiers: [.command, .shift]
    ))

    let logCountAfterMatch = diagnostics.messages.count
    standardProvider.emit(KeyPress(
        keyCode: UInt16(kVK_ANSI_A),
        modifiers: [.command]
    ))

    #expect(diagnostics.messages.contains { $0.contains("MATCHED: Safari - com.apple.Safari") })
    #expect(diagnostics.messages.contains { $0.contains("SHORTCUT_TRACE_DECISION event=matched bundle=com.apple.Safari") })
    #expect(diagnostics.messages.count == logCountAfterMatch)
}

@Test @MainActor
func missingStandardRegistrationEmitsCaptureBlockedDiagnostic() {
    let diagnostics = DiagnosticCapture()
    let standardProvider = FakeCaptureProvider()
    standardProvider.startSucceeds = false
    let (manager, _, _) = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false),
        standardProvider: standardProvider,
        diagnosticSink: diagnostics.record
    )
    manager.save(shortcuts: [standardShortcut()])

    manager.start()

    #expect(diagnostics.messages.contains {
        $0.contains("SHORTCUT_TRACE_BLOCKED")
            && $0.contains("reason=\"missing_registration_or_system_conflict\"")
            && $0.contains("route=standard")
    })
}

@Test @MainActor
func missingInputMonitoringEmitsHyperCaptureBlockedDiagnostic() {
    let diagnostics = DiagnosticCapture()
    let (manager, _, _) = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false),
        diagnosticSink: diagnostics.record
    )
    manager.save(shortcuts: [hyperShortcut()])
    manager.setHyperKeyEnabled(true)

    manager.start()

    #expect(diagnostics.messages.contains {
        $0.contains("SHORTCUT_TRACE_BLOCKED")
            && $0.contains("reason=\"input_monitoring_missing\"")
            && $0.contains("route=hyper")
    })
}

private final class DiagnosticCapture: @unchecked Sendable {
    private(set) var messages: [String] = []

    func record(_ message: String) {
        messages.append(message)
    }
}
