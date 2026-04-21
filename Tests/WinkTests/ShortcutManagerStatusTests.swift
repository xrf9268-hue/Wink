import Carbon.HIToolbox
import Foundation
import Testing
@testable import Wink

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
    func requestIfNeeded(prompt: Bool, inputMonitoringRequired: Bool) -> Bool {
        ax && (!inputMonitoringRequired || input)
    }
}

private final class MutablePermissionService: @unchecked Sendable, PermissionServicing {
    var ax: Bool
    var input: Bool
    var requestCallCount = 0
    var requestedInputMonitoringFlags: [Bool] = []
    var grantInputMonitoringOnPrompt = false

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
    func requestIfNeeded(prompt: Bool, inputMonitoringRequired: Bool) -> Bool {
        requestCallCount += 1
        requestedInputMonitoringFlags.append(inputMonitoringRequired)
        if prompt && inputMonitoringRequired && grantInputMonitoringOnPrompt && ax {
            input = true
        }
        return ax && (!inputMonitoringRequired || input)
    }
}

private final class MutableAppBundleLocatorState: @unchecked Sendable {
    var entries: [String: URL]

    init(entries: [String: URL]) {
        self.entries = entries
    }
}

@MainActor
private final class FakeCaptureProvider: ShortcutCaptureProvider {
    var isRunning = false
    var startSucceeds = true
    var failingShortcuts: Set<KeyPress> = []
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var registeredShortcuts: Set<KeyPress> = []
    private(set) var activeShortcuts: Set<KeyPress> = []
    private var onKeyPress: (@MainActor @Sendable (KeyPress) -> Void)?

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: registeredShortcuts.count,
            registeredShortcutCount: activeShortcuts.count,
            failures: failingShortcuts.map {
                ShortcutCaptureRegistrationFailure(keyPress: $0, status: Int32(eventHotKeyExistsErr))
            }.sorted {
                if $0.keyPress.keyCode == $1.keyPress.keyCode {
                    return $0.keyPress.modifiers.rawValue < $1.keyPress.modifiers.rawValue
                }
                return $0.keyPress.keyCode < $1.keyPress.keyCode
            }
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (KeyPress) -> Void) {
        startCallCount += 1
        self.onKeyPress = onKeyPress
        refreshRunningState()
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
        activeShortcuts = []
        onKeyPress = nil
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<KeyPress>) {
        registeredShortcuts = keyPresses
        refreshRunningState()
    }

    func emit(_ keyPress: KeyPress) {
        onKeyPress?(keyPress)
    }

    private func refreshRunningState() {
        activeShortcuts = startSucceeds ? registeredShortcuts.subtracting(failingShortcuts) : []
        isRunning = onKeyPress != nil && !activeShortcuts.isEmpty
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

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: registeredShortcuts.count,
            registeredShortcutCount: isRunning ? registeredShortcuts.count : 0,
            failures: []
        )
    }

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

private func defaultShortcutManagerAppBundleLocator() -> AppBundleLocator {
    TestAppBundleLocator(entries: [
        "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app"),
        "com.apple.Terminal": URL(fileURLWithPath: "/Applications/Utilities/Terminal.app"),
    ]).locator
}

@MainActor
private func makeShortcutManager(
    permissionService: some PermissionServicing,
    standardProvider: FakeCaptureProvider = FakeCaptureProvider(),
    hyperProvider: FakeHyperCaptureProvider = FakeHyperCaptureProvider(),
    persistenceHarness: TestPersistenceHarness = TestPersistenceHarness(),
    appBundleLocator: AppBundleLocator = defaultShortcutManagerAppBundleLocator(),
    diagnosticSink: @escaping @Sendable (String) -> Void = { _ in }
) -> (manager: ShortcutManager, standardProvider: FakeCaptureProvider, hyperProvider: FakeHyperCaptureProvider, persistenceHarness: TestPersistenceHarness) {
    let coordinator = ShortcutCaptureCoordinator(
        standardProvider: standardProvider,
        hyperProvider: hyperProvider
    )
    let manager = ShortcutManager(
        shortcutStore: ShortcutStore(),
        persistenceService: persistenceHarness.makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: coordinator,
        permissionService: permissionService,
        appBundleLocator: appBundleLocator,
        diagnosticClient: .init(log: diagnosticSink)
    )
    return (manager, standardProvider, hyperProvider, persistenceHarness)
}

private func standardShortcut() -> AppShortcut {
    AppShortcut(
        appName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        keyEquivalent: "s",
        modifierFlags: ["command", "shift"]
    )
}

private func alternateStandardShortcut() -> AppShortcut {
    AppShortcut(
        appName: "Terminal",
        bundleIdentifier: "com.apple.Terminal",
        keyEquivalent: "t",
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

private func unavailableShortcut() -> AppShortcut {
    AppShortcut(
        appName: "Ghostty",
        bundleIdentifier: "com.mitchellh.ghostty",
        keyEquivalent: "g",
        modifierFlags: ["command"]
    )
}

private func standardShortcutKeyPress() -> KeyPress {
    KeyPress(
        keyCode: UInt16(kVK_ANSI_S),
        modifiers: [.command, .shift]
    )
}

@Test @MainActor
func helperBuiltShortcutManagerCanPersistIntoInjectedHarness() throws {
    let shortcuts = [standardShortcut()]
    let context = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false)
    )

    context.manager.save(shortcuts: shortcuts)

    let persisted = try context.persistenceHarness.makePersistenceService().load()
    #expect(persisted == shortcuts)
    #expect(context.persistenceHarness.shortcutsURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
}

@Test @MainActor
func saveRegistersOnlyCurrentlyAvailableShortcuts() throws {
    let bundleLocatorState = MutableAppBundleLocatorState(entries: [
        "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app")
    ])
    let context = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false),
        appBundleLocator: AppBundleLocator { bundleIdentifier in
            bundleLocatorState.entries[bundleIdentifier]
        }
    )
    let shortcuts = [standardShortcut(), unavailableShortcut()]

    context.manager.save(shortcuts: shortcuts)

    let persisted = try context.persistenceHarness.makePersistenceService().load()
    #expect(persisted == shortcuts)
    #expect(context.standardProvider.registeredShortcuts == [standardShortcutKeyPress()])
}

@Test @MainActor
func availabilityGainRebuildsRegisteredShortcutsWithoutAnotherSave() {
    let bundleLocatorState = MutableAppBundleLocatorState(entries: [:])
    let context = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false),
        appBundleLocator: AppBundleLocator { bundleIdentifier in
            bundleLocatorState.entries[bundleIdentifier]
        }
    )
    context.manager.save(shortcuts: [standardShortcut()])
    context.manager.start()

    #expect(context.standardProvider.registeredShortcuts.isEmpty)

    bundleLocatorState.entries["com.apple.Safari"] = URL(fileURLWithPath: "/Applications/Safari.app")
    context.manager.checkPermissionChange()

    #expect(context.standardProvider.registeredShortcuts == [standardShortcutKeyPress()])
}

@Test @MainActor
func availabilityGainForHyperShortcutRequestsInputMonitoringAndStartsEventTap() {
    let bundleLocatorState = MutableAppBundleLocatorState(entries: [:])
    let permissionService = MutablePermissionService(ax: true, input: false)
    permissionService.grantInputMonitoringOnPrompt = true
    let context = makeShortcutManager(
        permissionService: permissionService,
        appBundleLocator: AppBundleLocator { bundleIdentifier in
            bundleLocatorState.entries[bundleIdentifier]
        }
    )

    context.manager.save(shortcuts: [hyperShortcut()])
    context.manager.setHyperKeyEnabled(true)
    context.manager.start()

    #expect(permissionService.requestedInputMonitoringFlags == [false])
    #expect(context.hyperProvider.isRunning == false)

    bundleLocatorState.entries["com.apple.Safari"] = URL(fileURLWithPath: "/Applications/Safari.app")
    context.manager.checkPermissionChange()

    let status = context.manager.shortcutCaptureStatus()

    #expect(permissionService.requestedInputMonitoringFlags == [false, true])
    #expect(status.inputMonitoringGranted == true)
    #expect(status.inputMonitoringRequired == true)
    #expect(status.hyperShortcutsReady == true)
    #expect(context.hyperProvider.isRunning == true)
}

@Test @MainActor
func availabilityLossRemovesRegisteredShortcutsWithoutAnotherSave() {
    let bundleLocatorState = MutableAppBundleLocatorState(entries: [
        "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app")
    ])
    let context = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false),
        appBundleLocator: AppBundleLocator { bundleIdentifier in
            bundleLocatorState.entries[bundleIdentifier]
        }
    )
    context.manager.save(shortcuts: [standardShortcut()])
    context.manager.start()

    #expect(context.standardProvider.registeredShortcuts == [standardShortcutKeyPress()])

    bundleLocatorState.entries = [:]
    context.manager.checkPermissionChange()

    #expect(context.standardProvider.registeredShortcuts.isEmpty)
}

@Test @MainActor
func captureStatusKeepsStandardShortcutsReadyWhenInputMonitoringIsMissing() {
    let (manager, standardProvider, hyperProvider, _) = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false)
    )
    manager.save(shortcuts: [standardShortcut()])
    manager.start()

    let status = manager.shortcutCaptureStatus()

    #expect(status.accessibilityGranted == true)
    #expect(status.inputMonitoringGranted == false)
    #expect(status.inputMonitoringRequired == false)
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
    let (manager, standardProvider, hyperProvider, _) = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false)
    )
    manager.save(shortcuts: [hyperShortcut()])
    manager.setHyperKeyEnabled(true)
    manager.start()

    let status = manager.shortcutCaptureStatus()

    #expect(status.carbonHotKeysRegistered == false)
    #expect(status.eventTapActive == false)
    #expect(status.inputMonitoringRequired == true)
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
    let (manager, standardProvider, hyperProvider, _) = makeShortcutManager(
        permissionService: permissionService
    )
    manager.save(shortcuts: [standardShortcut()])

    manager.checkPermissionChange()

    #expect(standardProvider.startCallCount == 1)
    #expect(standardProvider.isRunning == true)
    #expect(hyperProvider.startCallCount == 0)
}

@Test @MainActor
func startDoesNotRequestInputMonitoringWhenCurrentConfigurationIsStandardOnly() {
    let permissionService = MutablePermissionService(ax: true, input: false)
    let (manager, standardProvider, hyperProvider, _) = makeShortcutManager(
        permissionService: permissionService
    )
    manager.save(shortcuts: [standardShortcut()])

    manager.start()

    #expect(permissionService.requestCallCount == 1)
    #expect(permissionService.requestedInputMonitoringFlags == [false])
    #expect(standardProvider.startCallCount == 1)
    #expect(hyperProvider.startCallCount == 0)
}

@Test @MainActor
func startRequestsInputMonitoringWhenCurrentConfigurationNeedsHyperTransport() {
    let permissionService = MutablePermissionService(ax: true, input: false)
    permissionService.grantInputMonitoringOnPrompt = true
    let (manager, standardProvider, hyperProvider, _) = makeShortcutManager(
        permissionService: permissionService
    )
    manager.save(shortcuts: [hyperShortcut()])
    manager.setHyperKeyEnabled(true)

    manager.start()

    let status = manager.shortcutCaptureStatus()

    #expect(permissionService.requestCallCount == 1)
    #expect(permissionService.requestedInputMonitoringFlags == [true])
    #expect(status.inputMonitoringGranted == true)
    #expect(status.inputMonitoringRequired == true)
    #expect(status.standardShortcutsReady == true)
    #expect(status.hyperShortcutsReady == true)
    #expect(standardProvider.startCallCount == 0)
    #expect(hyperProvider.startCallCount == 1)
}

@Test @MainActor
func startDefersInputMonitoringPromptUntilAccessibilityIsGrantedForHyperConfiguration() {
    let permissionService = MutablePermissionService(ax: false, input: false)
    permissionService.grantInputMonitoringOnPrompt = true
    let (manager, standardProvider, hyperProvider, _) = makeShortcutManager(
        permissionService: permissionService
    )
    manager.save(shortcuts: [hyperShortcut()])
    manager.setHyperKeyEnabled(true)

    manager.start()

    #expect(permissionService.requestedInputMonitoringFlags == [false])
    #expect(permissionService.input == false)
    #expect(standardProvider.isRunning == false)
    #expect(hyperProvider.isRunning == false)

    permissionService.ax = true
    manager.checkPermissionChange()

    let status = manager.shortcutCaptureStatus()

    #expect(permissionService.requestedInputMonitoringFlags == [false, true])
    #expect(status.accessibilityGranted == true)
    #expect(status.inputMonitoringGranted == true)
    #expect(status.inputMonitoringRequired == true)
    #expect(status.standardShortcutsReady == true)
    #expect(status.hyperShortcutsReady == true)
    #expect(standardProvider.isRunning == false)
    #expect(hyperProvider.isRunning == true)
}

@Test @MainActor
func mixedConfigurationKeepsStandardShortcutsReadyWhileHyperWaitsForInputMonitoring() {
    let permissionService = MutablePermissionService(ax: true, input: false)
    let (manager, standardProvider, hyperProvider, _) = makeShortcutManager(
        permissionService: permissionService
    )
    manager.save(shortcuts: [standardShortcut(), hyperShortcut()])
    manager.setHyperKeyEnabled(true)

    manager.start()

    let status = manager.shortcutCaptureStatus()

    #expect(permissionService.requestedInputMonitoringFlags == [true])
    #expect(status.inputMonitoringGranted == false)
    #expect(status.inputMonitoringRequired == true)
    #expect(status.standardShortcutsReady == true)
    #expect(status.hyperShortcutsReady == false)
    #expect(standardProvider.startCallCount == 1)
    #expect(hyperProvider.startCallCount == 0)
}

@Test @MainActor
func enablingHyperAtRuntimeRequestsInputMonitoringAndResyncsCapture() {
    let permissionService = MutablePermissionService(ax: true, input: false)
    permissionService.grantInputMonitoringOnPrompt = true
    let (manager, standardProvider, hyperProvider, _) = makeShortcutManager(
        permissionService: permissionService
    )
    manager.save(shortcuts: [hyperShortcut()])
    manager.start()

    #expect(permissionService.requestedInputMonitoringFlags == [false])
    #expect(standardProvider.isRunning == true)
    #expect(hyperProvider.isRunning == false)

    manager.setHyperKeyEnabled(true)

    let status = manager.shortcutCaptureStatus()

    #expect(permissionService.requestedInputMonitoringFlags == [false, true])
    #expect(status.inputMonitoringGranted == true)
    #expect(status.inputMonitoringRequired == true)
    #expect(status.standardShortcutsReady == true)
    #expect(status.hyperShortcutsReady == true)
    #expect(standardProvider.isRunning == false)
    #expect(hyperProvider.isRunning == true)
}

@Test @MainActor
func grantingAccessibilityAfterHyperBecomesRequiredRequestsInputMonitoring() {
    let permissionService = MutablePermissionService(ax: false, input: false)
    permissionService.grantInputMonitoringOnPrompt = true
    let (manager, standardProvider, hyperProvider, _) = makeShortcutManager(
        permissionService: permissionService
    )
    manager.save(shortcuts: [hyperShortcut()])

    manager.start()
    manager.setHyperKeyEnabled(true)

    #expect(permissionService.requestedInputMonitoringFlags == [false])
    #expect(standardProvider.isRunning == false)
    #expect(hyperProvider.isRunning == false)

    permissionService.ax = true
    manager.checkPermissionChange()

    let status = manager.shortcutCaptureStatus()

    #expect(permissionService.requestedInputMonitoringFlags == [false, true])
    #expect(status.accessibilityGranted == true)
    #expect(status.inputMonitoringGranted == true)
    #expect(status.inputMonitoringRequired == true)
    #expect(status.standardShortcutsReady == true)
    #expect(status.hyperShortcutsReady == true)
    #expect(standardProvider.isRunning == false)
    #expect(hyperProvider.isRunning == true)
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
        persistenceService: TestPersistenceHarness().makePersistenceService(),
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
    let (manager, standardProvider, hyperProvider, _) = makeShortcutManager(
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
    let (manager, _, _, _) = makeShortcutManager(
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
    let (manager, _, _, _) = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false),
        standardProvider: standardProvider,
        diagnosticSink: diagnostics.record
    )
    manager.save(shortcuts: [standardShortcut()])

    manager.start()
    let status = manager.shortcutCaptureStatus()

    #expect(status.carbonHotKeysRegistered == false)
    #expect(status.standardShortcutsReady == false)
    #expect(status.standardRegistrationWarning == "Standard shortcuts failed to register. Check logs for the blocked key combinations.")
    #expect(status.permissionWarning == nil)
    #expect(diagnostics.messages.contains {
        $0.contains("SHORTCUT_TRACE_BLOCKED")
            && $0.contains("reason=\"missing_registration_or_system_conflict\"")
            && $0.contains("route=standard")
    })
}

@Test @MainActor
func partialStandardRegistrationMarksStandardCaptureNotReadyAndIncludesFailedBindingDetails() {
    let diagnostics = DiagnosticCapture()
    let standardProvider = FakeCaptureProvider()
    let failedKeyPress = KeyPress(
        keyCode: UInt16(kVK_ANSI_T),
        modifiers: [.command, .shift]
    )
    standardProvider.failingShortcuts = [failedKeyPress]
    let (manager, _, _, _) = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false),
        standardProvider: standardProvider,
        diagnosticSink: diagnostics.record
    )
    manager.save(shortcuts: [standardShortcut(), alternateStandardShortcut()])

    manager.start()

    let status = manager.shortcutCaptureStatus()

    #expect(status.carbonHotKeysRegistered == false)
    #expect(status.standardShortcutsReady == false)
    #expect(status.standardRegistrationWarning == "1 standard shortcut binding failed to register. Check logs for the blocked key combination.")
    #expect(status.permissionWarning == nil)
    #expect(diagnostics.messages.contains {
        $0.contains("SHORTCUT_TRACE_BLOCKED")
            && $0.contains("reason=\"missing_registration_or_system_conflict\"")
            && $0.contains("route=standard")
            && $0.contains("keyCode=\(failedKeyPress.keyCode)")
            && $0.contains("modifiers=\(failedKeyPress.modifiers.rawValue)")
    })
}

@Test @MainActor
func missingInputMonitoringEmitsHyperCaptureBlockedDiagnostic() {
    let diagnostics = DiagnosticCapture()
    let (manager, _, _, _) = makeShortcutManager(
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
