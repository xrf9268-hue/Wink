import AppKit
import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "ShortcutManager")
private let shortcutManagerSuppressAutomaticPermissionPromptsArgument = "--suppress-automatic-permission-prompts"

private func shortcutManagerAutomaticPermissionPromptingEnabled(
    processInfo: ProcessInfo = .processInfo
) -> Bool {
    !processInfo.arguments.contains(shortcutManagerSuppressAutomaticPermissionPromptsArgument)
}

@MainActor
final class ShortcutManager {
    static let suppressAutomaticPermissionPromptsArgument = shortcutManagerSuppressAutomaticPermissionPromptsArgument

    struct DiagnosticClient {
        let log: @Sendable (String) -> Void
    }

    private let shortcutStore: ShortcutStore
    private let persistenceService: PersistenceService
    private let appSwitcher: any AppSwitching
    private let captureCoordinator: ShortcutCaptureCoordinator
    private let permissionService: any PermissionServicing
    private let usageTracker: UsageTracker?
    private let appBundleLocator: AppBundleLocator
    private let diagnosticClient: DiagnosticClient
    private let automaticPermissionPromptingEnabled: Bool
    private let keyMatcher = KeyMatcher()
    private var triggerIndex: [ShortcutTrigger: AppShortcut] = [:]
    private var permissionTimer: Timer?
    private var lastAccessibilityState: Bool = false
    private var lastInputMonitoringState: Bool = false
    private var lastAvailableShortcutBundleIdentifiers: Set<String> = []
    private var hyperKeyEnabled = false
    private var shortcutsPaused = false
    private var lastCaptureBlockedMessages: Set<String> = []
    private var hasStarted = false

    init(
        shortcutStore: ShortcutStore,
        persistenceService: PersistenceService,
        appSwitcher: any AppSwitching,
        captureCoordinator: ShortcutCaptureCoordinator = ShortcutCaptureCoordinator(),
        permissionService: any PermissionServicing = AccessibilityPermissionService(),
        usageTracker: UsageTracker? = nil,
        appBundleLocator: AppBundleLocator = AppBundleLocator(),
        automaticPermissionPromptingEnabled: Bool = shortcutManagerAutomaticPermissionPromptingEnabled(),
        diagnosticClient: DiagnosticClient
    ) {
        self.shortcutStore = shortcutStore
        self.persistenceService = persistenceService
        self.appSwitcher = appSwitcher
        self.captureCoordinator = captureCoordinator
        self.permissionService = permissionService
        self.usageTracker = usageTracker
        self.appBundleLocator = appBundleLocator
        self.diagnosticClient = diagnosticClient
        self.automaticPermissionPromptingEnabled = automaticPermissionPromptingEnabled
    }

    func start() {
        rebuildIndex()
        let inputMonitoringRequired = captureCoordinator.inputMonitoringRequired
        let ready: Bool
        if shortcutsPaused {
            ready = false
        } else {
            let shouldRequestInputMonitoring = inputMonitoringRequired
                && permissionService.isAccessibilityTrusted()
            ready = permissionService.requestIfNeeded(
                prompt: automaticPermissionPromptingEnabled,
                inputMonitoringRequired: shouldRequestInputMonitoring
            )
        }
        if !automaticPermissionPromptingEnabled {
            diagnosticClient.log("Automatic permission prompts suppressed for this launch")
        }
        logger.info(
            "start(): ready=\(ready), ax=\(self.permissionService.isAccessibilityTrusted()), im=\(self.permissionService.isInputMonitoringTrusted()), inputMonitoringRequired=\(inputMonitoringRequired), paused=\(self.shortcutsPaused)"
        )
        diagnosticClient.log(
            "start(): ready=\(ready), ax=\(permissionService.isAccessibilityTrusted()), im=\(permissionService.isInputMonitoringTrusted()), inputMonitoringRequired=\(inputMonitoringRequired), paused=\(shortcutsPaused)"
        )
        hasStarted = true
        startPermissionMonitoring()
        attemptStartIfPermitted()
    }

    func stop() {
        hasStarted = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        captureCoordinator.stop()
    }

    /// Persists to disk first and only then updates the in-memory store, so a
    /// failed write cannot leave the running app showing state that silently
    /// reverts on next launch (`shortcuts.json` is the canonical state).
    func save(shortcuts: [AppShortcut]) throws {
        let inputMonitoringWasRequired = captureCoordinator.inputMonitoringRequired
        try persistenceService.save(shortcuts)
        shortcutStore.replaceAll(with: shortcuts)
        rebuildIndex()
        handleCaptureConfigurationChange(
            inputMonitoringWasRequired: inputMonitoringWasRequired
        )
        // Any configuration change may alter a shortcut's effective
        // frontmost behavior (per-shortcut override included); an
        // in-flight cycle cursor must not survive it, or a stale session
        // could steer the next gesture and qualify for the relaxed
        // cycle cooldown.
        appSwitcher.invalidateWindowCycleSession(reason: "shortcut_configuration_changed")
    }

    @discardableResult
    func trigger(_ shortcut: AppShortcut) -> Bool {
        let success = appSwitcher.toggleApplication(for: shortcut)
        if success, let usageTracker {
            Task { await usageTracker.recordUsage(shortcutId: shortcut.id) }
        }
        return success
    }

    func shortcutCaptureStatus() -> ShortcutCaptureStatus {
        captureCoordinator.status(
            accessibilityGranted: permissionService.isAccessibilityTrusted(),
            inputMonitoringGranted: permissionService.isInputMonitoringTrusted()
        )
    }

    func setHyperKeyEnabled(_ enabled: Bool) {
        let inputMonitoringWasRequired = captureCoordinator.inputMonitoringRequired
        hyperKeyEnabled = enabled
        captureCoordinator.setHyperKeyEnabled(enabled)
        handleCaptureConfigurationChange(
            inputMonitoringWasRequired: inputMonitoringWasRequired
        )
    }

    func setFrontmostTargetBehavior(_ behavior: FrontmostTargetBehavior) {
        appSwitcher.setFrontmostTargetBehavior(behavior)
    }

    func setShortcutsPaused(_ paused: Bool) {
        guard shortcutsPaused != paused else {
            return
        }

        shortcutsPaused = paused
        if !paused {
            _ = refreshShortcutAvailabilityIfNeeded()
        }

        if paused {
            captureCoordinator.setCapturePaused(true)
            if hasStarted {
                diagnosticClient.log("Shortcut capture paused")
            }
            return
        }

        guard hasStarted else {
            captureCoordinator.setCapturePaused(false)
            return
        }

        let shouldRequestInputMonitoring = captureCoordinator.inputMonitoringRequired
            && permissionService.isAccessibilityTrusted()
        _ = permissionService.requestIfNeeded(
            prompt: automaticPermissionPromptingEnabled,
            inputMonitoringRequired: shouldRequestInputMonitoring
        )
        captureCoordinator.refreshInputMonitoring(
            granted: permissionService.isInputMonitoringTrusted()
        )
        captureCoordinator.setCapturePaused(false)
        attemptStartIfPermitted(retryStandardProvider: false)
    }

    func requestPermissions() {
        let inputMonitoringRequired = captureCoordinator.inputMonitoringRequired
        _ = permissionService.requestIfNeeded(
            prompt: true,
            inputMonitoringRequired: inputMonitoringRequired
        )
        attemptStartIfPermitted()
    }

    // MARK: - Permission monitoring

    private func startPermissionMonitoring() {
        lastAccessibilityState = permissionService.isAccessibilityTrusted()
        lastInputMonitoringState = permissionService.isInputMonitoringTrusted()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermissionChange()
            }
        }
    }

    func checkPermissionChange() {
        let axGranted = permissionService.isAccessibilityTrusted()
        var imGranted = permissionService.isInputMonitoringTrusted()
        let snapshot = captureCoordinator.snapshot()
        let accessibilityChanged = axGranted != lastAccessibilityState
        let inputMonitoringChanged = imGranted != lastInputMonitoringState
        let inputMonitoringWasRequired = captureCoordinator.inputMonitoringRequired

        logger.info(
            "checkPermission: ax=\(axGranted) im=\(imGranted) carbon=\(snapshot.carbonHotKeysRegistered) eventTap=\(snapshot.eventTapActive) standardFnObserverRequired=\(snapshot.standardInputMonitoringRequired)"
        )
        diagnosticClient.log(
            "checkPermission: ax=\(axGranted) im=\(imGranted) carbon=\(snapshot.carbonHotKeysRegistered) eventTap=\(snapshot.eventTapActive) standardFnObserverRequired=\(snapshot.standardInputMonitoringRequired)"
        )

        // Report individual permission changes
        if accessibilityChanged {
            if axGranted {
                logger.notice("Accessibility permission: granted")
                diagnosticClient.log("Accessibility permission: granted")
            } else {
                logger.error("Accessibility permission: REVOKED")
                diagnosticClient.log("Accessibility permission: REVOKED")
                sendPermissionNotification(permission: "Accessibility")
            }
            lastAccessibilityState = axGranted
        }

        if inputMonitoringChanged {
            if imGranted {
                logger.notice("Input Monitoring permission: granted")
                diagnosticClient.log("Input Monitoring permission: granted")
            } else {
                logger.error("Input Monitoring permission: REVOKED")
                diagnosticClient.log("Input Monitoring permission: REVOKED")
                sendPermissionNotification(permission: "Input Monitoring")
            }
            lastInputMonitoringState = imGranted
        }

        guard axGranted else {
            if snapshot.carbonHotKeysRegistered || snapshot.eventTapActive {
                logger.error("Accessibility lost — stopping shortcut capture")
                diagnosticClient.log("Accessibility lost — stopping shortcut capture")
                captureCoordinator.stop()
            }
            return
        }

        if shortcutsPaused {
            _ = refreshShortcutAvailabilityIfNeeded()
            captureCoordinator.refreshInputMonitoring(granted: imGranted)
            return
        }

        let availabilityRefresh = refreshShortcutAvailabilityIfNeeded()
        let inputMonitoringRequirementChanged = !inputMonitoringWasRequired
            && captureCoordinator.inputMonitoringRequired

        if (accessibilityChanged || inputMonitoringRequirementChanged)
            && captureCoordinator.inputMonitoringRequired
            && !imGranted
        {
            _ = permissionService.requestIfNeeded(
                prompt: automaticPermissionPromptingEnabled,
                inputMonitoringRequired: true
            )
            let refreshedInputMonitoring = permissionService.isInputMonitoringTrusted()
            if refreshedInputMonitoring != imGranted {
                imGranted = refreshedInputMonitoring
                lastInputMonitoringState = refreshedInputMonitoring
                logger.notice("Input Monitoring permission: granted")
                diagnosticClient.log("Input Monitoring permission: granted")
            }
        }

        let currentStatus = captureCoordinator.status(
            accessibilityGranted: axGranted,
            inputMonitoringGranted: imGranted
        )
        let captureNeedsResync = !currentStatus.standardShortcutsReady || !currentStatus.hyperShortcutsReady
        guard accessibilityChanged
            || inputMonitoringChanged
            || captureNeedsResync
            || availabilityRefresh.availabilityChanged else {
            return
        }

        logger.notice("Accessibility ready — syncing shortcut capture")
        diagnosticClient.log("Accessibility ready — syncing shortcut capture")
        attemptStartIfPermitted(
            retryStandardProvider: !availabilityRefresh.standardShortcutsChanged
        )
    }

    /// Send a user notification when a specific permission is revoked.
    private func sendPermissionNotification(permission: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Wink: Permission Lost"
            content.body = "\(permission) permission was revoked. Wink needs this permission to work. Please re-enable it in System Settings > Privacy & Security > \(permission)."
            let request = UNNotificationRequest(identifier: "wink-permission-\(permission)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func attemptStartIfPermitted(retryStandardProvider: Bool = true) {
        if shortcutsPaused {
            captureCoordinator.start(
                inputMonitoringGranted: permissionService.isInputMonitoringTrusted(),
                retryStandardProvider: retryStandardProvider
            ) { [weak self] keyPress in
                #if DEBUG
                logger.debug("KeyPress received: keyCode=\(keyPress.keyCode) modifiers=\(keyPress.modifiers.rawValue)")
                #endif
                _ = self?.handleKeyPress(keyPress)
            }
            let snapshot = captureCoordinator.snapshot()
            logger.info(
                "attemptStart: shortcuts=\(self.shortcutStore.shortcuts.count) triggerIndex=\(self.triggerIndex.count) carbon=\(snapshot.carbonHotKeysRegistered) carbonHandler=\(snapshot.standardHandlerState.diagnosticName) carbonHandlerStatus=\(snapshot.standardHandlerState.failureStatus.map(String.init) ?? "none") eventTap=\(snapshot.eventTapActive) standardFnObserverRequired=\(snapshot.standardInputMonitoringRequired) paused=true"
            )
            diagnosticClient.log(
                "attemptStart: shortcuts=\(shortcutStore.shortcuts.count) triggerIndex=\(triggerIndex.count) carbon=\(snapshot.carbonHotKeysRegistered) carbonHandler=\(snapshot.standardHandlerState.diagnosticName) carbonHandlerStatus=\(snapshot.standardHandlerState.failureStatus.map(String.init) ?? "none") eventTap=\(snapshot.eventTapActive) standardFnObserverRequired=\(snapshot.standardInputMonitoringRequired) paused=true"
            )
            lastCaptureBlockedMessages = []
            return
        }

        guard permissionService.isAccessibilityTrusted() else {
            #if DEBUG
            logger.debug("attemptStart: accessibility not granted, skipping")
            #endif
            captureCoordinator.stop()
            return
        }

        captureCoordinator.start(
            inputMonitoringGranted: permissionService.isInputMonitoringTrusted(),
            retryStandardProvider: retryStandardProvider
        ) { [weak self] keyPress in
            #if DEBUG
            logger.debug("KeyPress received: keyCode=\(keyPress.keyCode) modifiers=\(keyPress.modifiers.rawValue)")
            #endif
            _ = self?.handleKeyPress(keyPress)
        }
        let snapshot = captureCoordinator.snapshot()
        logger.info(
            "attemptStart: shortcuts=\(self.shortcutStore.shortcuts.count) triggerIndex=\(self.triggerIndex.count) carbon=\(snapshot.carbonHotKeysRegistered) carbonHandler=\(snapshot.standardHandlerState.diagnosticName) carbonHandlerStatus=\(snapshot.standardHandlerState.failureStatus.map(String.init) ?? "none") eventTap=\(snapshot.eventTapActive) standardFnObserverRequired=\(snapshot.standardInputMonitoringRequired)"
        )
        diagnosticClient.log(
            "attemptStart: shortcuts=\(shortcutStore.shortcuts.count) triggerIndex=\(triggerIndex.count) carbon=\(snapshot.carbonHotKeysRegistered) carbonHandler=\(snapshot.standardHandlerState.diagnosticName) carbonHandlerStatus=\(snapshot.standardHandlerState.failureStatus.map(String.init) ?? "none") eventTap=\(snapshot.eventTapActive) standardFnObserverRequired=\(snapshot.standardInputMonitoringRequired)"
        )
        emitCaptureBlockedDiagnostics(snapshot: snapshot)
    }

    private func handleCaptureConfigurationChange(inputMonitoringWasRequired: Bool) {
        guard hasStarted else {
            return
        }

        let inputMonitoringRequired = captureCoordinator.inputMonitoringRequired
        if !shortcutsPaused
            && !inputMonitoringWasRequired
            && inputMonitoringRequired
            && permissionService.isAccessibilityTrusted()
        {
            _ = permissionService.requestIfNeeded(
                prompt: automaticPermissionPromptingEnabled,
                inputMonitoringRequired: true
            )
        }

        captureCoordinator.refreshInputMonitoring(
            granted: permissionService.isInputMonitoringTrusted()
        )
    }

    // MARK: - Key handling

    private func rebuildIndex() {
        _ = applyAvailabilitySnapshot(availabilitySnapshot())
    }

    private func refreshShortcutAvailabilityIfNeeded() -> (
        availabilityChanged: Bool,
        standardShortcutsChanged: Bool
    ) {
        let snapshot = availabilitySnapshot()
        guard snapshot.availableBundleIdentifiers != lastAvailableShortcutBundleIdentifiers else {
            return (availabilityChanged: false, standardShortcutsChanged: false)
        }

        return (
            availabilityChanged: true,
            standardShortcutsChanged: applyAvailabilitySnapshot(snapshot)
        )
    }

    private func availabilitySnapshot() -> (activeShortcuts: [AppShortcut], availableBundleIdentifiers: Set<String>) {
        var activeShortcuts: [AppShortcut] = []
        var availableBundleIdentifiers = Set<String>()

        for shortcut in shortcutStore.shortcuts where shortcut.isEnabled {
            // Frontmost-app pseudo-targets have no app URL by design (their
            // sentinel bundle names no installed app) and are always
            // available: skipping the locator check here is what makes
            // them register with Carbon and enter the trigger index.
            guard shortcut.isFrontmostAppTarget
                    || appBundleLocator.applicationURL(for: shortcut.bundleIdentifier) != nil else {
                continue
            }

            activeShortcuts.append(shortcut)
            availableBundleIdentifiers.insert(shortcut.bundleIdentifier)
        }

        return (activeShortcuts, availableBundleIdentifiers)
    }

    private func applyAvailabilitySnapshot(
        _ snapshot: (activeShortcuts: [AppShortcut], availableBundleIdentifiers: Set<String>)
    ) -> Bool {
        lastAvailableShortcutBundleIdentifiers = snapshot.availableBundleIdentifiers
        triggerIndex = keyMatcher.buildIndex(for: snapshot.activeShortcuts)
        return captureCoordinator.updateShortcuts(snapshot.activeShortcuts)
    }

    /// Returns `true` if the key press matched a shortcut (so the event should be consumed).
    private func handleKeyPress(_ keyPress: KeyPress) -> Bool {
        let key = keyMatcher.trigger(for: keyPress)
        #if DEBUG
        if !triggerIndex.isEmpty {
            logger.debug("handleKeyPress: trigger=(\(key.keyCode), \(key.modifierMask)) indexCount=\(self.triggerIndex.count)")
        }
        #endif
        guard let match = triggerIndex[key] else {
            return false
        }
        logger.info("MATCHED: \(match.appName) - \(match.bundleIdentifier)")
        diagnosticClient.log("MATCHED: \(match.appName) - \(match.bundleIdentifier)")
        diagnosticClient.log(matchedShortcutTraceMessage(for: match))
        _ = trigger(match)
        return true
    }

    private func emitCaptureBlockedDiagnostics(snapshot: ShortcutCaptureSnapshot) {
        guard !snapshot.shortcutsPaused else {
            lastCaptureBlockedMessages = []
            return
        }

        var blockedMessages = Set<String>()

        if snapshot.standardShortcutCount > 0 && !snapshot.carbonHotKeysRegistered {
            let reason: String
            if case .installationFailed = snapshot.standardHandlerState {
                reason = "carbon_handler_installation_failed"
            } else if snapshot.standardInputMonitoringRequired
                && !permissionService.isInputMonitoringTrusted() {
                reason = "input_monitoring_missing"
            } else {
                reason = "missing_registration_or_system_conflict"
            }
            blockedMessages.insert(captureBlockedMessage(
                reason: reason,
                route: .standard,
                snapshot: snapshot
            ))
        }

        if snapshot.hyperShortcutCount > 0 && !permissionService.isInputMonitoringTrusted() {
            blockedMessages.insert(captureBlockedMessage(
                reason: "input_monitoring_missing",
                route: .hyper,
                snapshot: snapshot
            ))
        } else if snapshot.hyperShortcutCount > 0 && !snapshot.eventTapActive {
            blockedMessages.insert(captureBlockedMessage(
                reason: "event_tap_inactive",
                route: .hyper,
                snapshot: snapshot
            ))
        }

        guard blockedMessages != lastCaptureBlockedMessages else {
            return
        }

        lastCaptureBlockedMessages = blockedMessages
        for message in blockedMessages.sorted() {
            diagnosticClient.log(message)
        }
    }

    func matchedShortcutTraceMessage(for shortcut: AppShortcut) -> String {
        let route = ShortcutCaptureRoute.route(for: shortcut, hyperKeyEnabled: hyperKeyEnabled)
        return "SHORTCUT_TRACE_DECISION event=matched bundle=\(shortcut.bundleIdentifier) route=\(route == .hyper ? "hyper" : "standard")"
    }

    func captureBlockedMessage(
        reason: String,
        route: ShortcutCaptureRoute,
        snapshot: ShortcutCaptureSnapshot
    ) -> String {
        var message = "SHORTCUT_TRACE_BLOCKED reason=\(quoted(reason)) route=\(route == .hyper ? "hyper" : "standard") carbonRegistered=\(snapshot.carbonHotKeysRegistered) eventTapActive=\(snapshot.eventTapActive) standardShortcutCount=\(snapshot.standardShortcutCount) hyperShortcutCount=\(snapshot.hyperShortcutCount)"

        if route == .standard {
            message += " registeredStandardShortcutCount=\(snapshot.registeredStandardShortcutCount) handlerState=\(snapshot.standardHandlerState.diagnosticName)"

            if let handlerStatus = snapshot.standardHandlerState.failureStatus {
                message += " handlerStatus=\(handlerStatus)"
            }

            if !snapshot.standardRegistrationFailures.isEmpty {
                let failedBindings = snapshot.standardRegistrationFailures
                    .map { failure in
                        "keyCode=\(failure.keyPress.keyCode),modifiers=\(failure.keyPress.modifiers.rawValue),status=\(failure.status)"
                    }
                    .joined(separator: ";")
                message += " failedBindings=\(quoted(failedBindings))"
            }
        }

        return message
    }

    private func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    static func defaultAutomaticPermissionPromptingEnabled(
        processInfo: ProcessInfo = .processInfo
    ) -> Bool {
        shortcutManagerAutomaticPermissionPromptingEnabled(processInfo: processInfo)
    }
}

extension ShortcutManager.DiagnosticClient {
    static let live = ShortcutManager.DiagnosticClient(
        log: { message in
            DiagnosticLog.log(message)
        }
    )
}
