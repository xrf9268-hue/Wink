import AppKit
import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "ShortcutManager")

@MainActor
final class ShortcutManager {
    struct DiagnosticClient {
        let log: @Sendable (String) -> Void
    }

    private let shortcutStore: ShortcutStore
    private let persistenceService: PersistenceService
    private let appSwitcher: any AppSwitching
    private let captureCoordinator: ShortcutCaptureCoordinator
    private let permissionService: any PermissionServicing
    private let usageTracker: UsageTracker?
    private let diagnosticClient: DiagnosticClient
    private let keyMatcher = KeyMatcher()
    private var triggerIndex: [ShortcutTrigger: AppShortcut] = [:]
    private var permissionTimer: Timer?
    private var lastAccessibilityState: Bool = false
    private var lastInputMonitoringState: Bool = false
    private var hyperKeyEnabled = false
    private var lastCaptureBlockedMessages: Set<String> = []

    init(
        shortcutStore: ShortcutStore,
        persistenceService: PersistenceService,
        appSwitcher: any AppSwitching,
        captureCoordinator: ShortcutCaptureCoordinator = ShortcutCaptureCoordinator(),
        permissionService: any PermissionServicing = AccessibilityPermissionService(),
        usageTracker: UsageTracker? = nil,
        diagnosticClient: DiagnosticClient
    ) {
        self.shortcutStore = shortcutStore
        self.persistenceService = persistenceService
        self.appSwitcher = appSwitcher
        self.captureCoordinator = captureCoordinator
        self.permissionService = permissionService
        self.usageTracker = usageTracker
        self.diagnosticClient = diagnosticClient
    }

    func start() {
        let trusted = permissionService.requestIfNeeded(prompt: true)
        logger.info("start(): trusted=\(trusted), isTrusted=\(self.permissionService.isTrusted())")
        diagnosticClient.log("start(): trusted=\(trusted), isTrusted=\(permissionService.isTrusted())")
        startPermissionMonitoring()
        rebuildIndex()
        attemptStartIfPermitted()
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        captureCoordinator.stop()
    }

    func save(shortcuts: [AppShortcut]) {
        shortcutStore.replaceAll(with: shortcuts)
        persistenceService.save(shortcuts)
        rebuildIndex()
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
        hyperKeyEnabled = enabled
        captureCoordinator.setHyperKeyEnabled(enabled)
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
        let imGranted = permissionService.isInputMonitoringTrusted()
        let snapshot = captureCoordinator.snapshot()
        let accessibilityChanged = axGranted != lastAccessibilityState
        let inputMonitoringChanged = imGranted != lastInputMonitoringState

        logger.info(
            "checkPermission: ax=\(axGranted) im=\(imGranted) carbon=\(snapshot.carbonHotKeysRegistered) eventTap=\(snapshot.eventTapActive)"
        )
        diagnosticClient.log(
            "checkPermission: ax=\(axGranted) im=\(imGranted) carbon=\(snapshot.carbonHotKeysRegistered) eventTap=\(snapshot.eventTapActive)"
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

        let currentStatus = captureCoordinator.status(
            accessibilityGranted: axGranted,
            inputMonitoringGranted: imGranted
        )
        let captureNeedsResync = !currentStatus.standardShortcutsReady || !currentStatus.hyperShortcutsReady
        guard accessibilityChanged || inputMonitoringChanged || captureNeedsResync else {
            return
        }

        captureCoordinator.refreshInputMonitoring(granted: imGranted)
        logger.notice("Accessibility ready — syncing shortcut capture")
        diagnosticClient.log("Accessibility ready — syncing shortcut capture")
        attemptStartIfPermitted()
    }

    /// Send a user notification when a specific permission is revoked.
    private func sendPermissionNotification(permission: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Quickey: Permission Lost"
            content.body = "\(permission) permission was revoked. Quickey needs this permission to work. Please re-enable it in System Settings > Privacy & Security > \(permission)."
            let request = UNNotificationRequest(identifier: "quickey-permission-\(permission)", content: content, trigger: nil)
            center.add(request)
        }
    }

    private func attemptStartIfPermitted() {
        guard permissionService.isAccessibilityTrusted() else {
            #if DEBUG
            logger.debug("attemptStart: accessibility not granted, skipping")
            #endif
            captureCoordinator.stop()
            return
        }

        captureCoordinator.refreshInputMonitoring(granted: permissionService.isInputMonitoringTrusted())
        captureCoordinator.setHyperKeyEnabled(hyperKeyEnabled)
        captureCoordinator.start(inputMonitoringGranted: permissionService.isInputMonitoringTrusted()) { [weak self] keyPress in
            #if DEBUG
            logger.debug("KeyPress received: keyCode=\(keyPress.keyCode) modifiers=\(keyPress.modifiers.rawValue)")
            #endif
            _ = self?.handleKeyPress(keyPress)
        }
        let snapshot = captureCoordinator.snapshot()
        logger.info(
            "attemptStart: shortcuts=\(self.shortcutStore.shortcuts.count) triggerIndex=\(self.triggerIndex.count) carbon=\(snapshot.carbonHotKeysRegistered) eventTap=\(snapshot.eventTapActive)"
        )
        diagnosticClient.log(
            "attemptStart: shortcuts=\(shortcutStore.shortcuts.count) triggerIndex=\(triggerIndex.count) carbon=\(snapshot.carbonHotKeysRegistered) eventTap=\(snapshot.eventTapActive)"
        )
        emitCaptureBlockedDiagnostics(snapshot: snapshot)
    }

    // MARK: - Key handling

    private func rebuildIndex() {
        triggerIndex = keyMatcher.buildIndex(for: shortcutStore.shortcuts)
        captureCoordinator.updateShortcuts(shortcutStore.shortcuts)
    }

    /// Returns `true` if the key press matched a shortcut (so the event should be consumed).
    private func handleKeyPress(_ keyPress: KeyPress) -> Bool {
        let key = keyMatcher.trigger(for: keyPress)
        #if DEBUG
        if !triggerIndex.isEmpty {
            logger.debug("handleKeyPress: trigger=(\(key.keyCode), \(key.modifierMask)), index=\(self.triggerIndex.keys.map { "(\($0.keyCode),\($0.modifierMask))" }.joined(separator: ","))")
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
        var blockedMessages = Set<String>()

        if snapshot.standardShortcutCount > 0 && !snapshot.carbonHotKeysRegistered {
            blockedMessages.insert(captureBlockedMessage(
                reason: "missing_registration_or_system_conflict",
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
        "SHORTCUT_TRACE_BLOCKED reason=\(quoted(reason)) route=\(route == .hyper ? "hyper" : "standard") carbonRegistered=\(snapshot.carbonHotKeysRegistered) eventTapActive=\(snapshot.eventTapActive) standardShortcutCount=\(snapshot.standardShortcutCount) hyperShortcutCount=\(snapshot.hyperShortcutCount)"
    }

    private func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

extension ShortcutManager.DiagnosticClient {
    static let live = ShortcutManager.DiagnosticClient(
        log: { message in
            DiagnosticLog.log(message)
        }
    )
}
