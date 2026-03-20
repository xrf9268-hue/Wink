import AppKit
import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "ShortcutManager")

@MainActor
final class ShortcutManager {
    private let shortcutStore: ShortcutStore
    private let persistenceService: PersistenceService
    private let appSwitcher: AppSwitcher
    private let eventTapManager: EventTapManager
    private let permissionService: AccessibilityPermissionService
    private let usageTracker: UsageTracker?
    private let keyMatcher = KeyMatcher()
    private var triggerIndex: [ShortcutTrigger: AppShortcut] = [:]
    private var permissionTimer: Timer?
    private var lastAccessibilityState: Bool = false
    private var lastInputMonitoringState: Bool = false

    init(
        shortcutStore: ShortcutStore,
        persistenceService: PersistenceService,
        appSwitcher: AppSwitcher,
        eventTapManager: EventTapManager = EventTapManager(),
        permissionService: AccessibilityPermissionService = AccessibilityPermissionService(),
        usageTracker: UsageTracker? = nil
    ) {
        self.shortcutStore = shortcutStore
        self.persistenceService = persistenceService
        self.appSwitcher = appSwitcher
        self.eventTapManager = eventTapManager
        self.permissionService = permissionService
        self.usageTracker = usageTracker
    }

    func start() {
        let trusted = permissionService.requestIfNeeded(prompt: true)
        logger.info("start(): trusted=\(trusted), isTrusted=\(self.permissionService.isTrusted())")
        DiagnosticLog.log("start(): trusted=\(trusted), isTrusted=\(permissionService.isTrusted())")
        startPermissionMonitoring()
        attemptStartIfPermitted()
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        eventTapManager.stop()
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

    func hasAccessibilityAccess() -> Bool {
        permissionService.isTrusted()
    }

    func setHyperKeyEnabled(_ enabled: Bool) {
        eventTapManager.setHyperKeyEnabled(enabled)
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

    private func checkPermissionChange() {
        let axGranted = permissionService.isAccessibilityTrusted()
        let imGranted = permissionService.isInputMonitoringTrusted()

        logger.info("checkPermission: ax=\(axGranted) im=\(imGranted) tapRunning=\(self.eventTapManager.isRunning)")
        DiagnosticLog.log("checkPermission: ax=\(axGranted) im=\(imGranted) tapRunning=\(eventTapManager.isRunning)")

        // Report individual permission changes
        if axGranted != lastAccessibilityState {
            if axGranted {
                logger.notice("Accessibility permission: granted")
                DiagnosticLog.log("Accessibility permission: granted")
            } else {
                logger.error("Accessibility permission: REVOKED")
                DiagnosticLog.log("Accessibility permission: REVOKED")
                sendPermissionNotification(permission: "Accessibility")
            }
            lastAccessibilityState = axGranted
        }

        if imGranted != lastInputMonitoringState {
            if imGranted {
                logger.notice("Input Monitoring permission: granted")
                DiagnosticLog.log("Input Monitoring permission: granted")
            } else {
                logger.error("Input Monitoring permission: REVOKED")
                DiagnosticLog.log("Input Monitoring permission: REVOKED")
                sendPermissionNotification(permission: "Input Monitoring")
            }
            lastInputMonitoringState = imGranted
        }

        // Handle combined state transitions
        let nowGranted = axGranted && imGranted

        if nowGranted && !eventTapManager.isRunning {
            logger.notice("All permissions granted — starting event tap")
            DiagnosticLog.log("All permissions granted — starting event tap")
            attemptStartIfPermitted()
        } else if !nowGranted && eventTapManager.isRunning {
            logger.error("Permission lost — stopping event tap")
            DiagnosticLog.log("Permission lost — stopping event tap")
            eventTapManager.stop()
        }
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
        guard permissionService.isTrusted() else {
            #if DEBUG
            logger.debug("attemptStart: not trusted, skipping")
            #endif
            return
        }
        guard !eventTapManager.isRunning else {
            #if DEBUG
            logger.debug("attemptStart: already running")
            #endif
            return
        }

        rebuildIndex()
        logger.info("attemptStart: starting event tap, shortcuts count: \(self.shortcutStore.shortcuts.count), triggerIndex count: \(self.triggerIndex.count)")
        DiagnosticLog.log("attemptStart: starting event tap, shortcuts count: \(shortcutStore.shortcuts.count), triggerIndex count: \(triggerIndex.count)")
        eventTapManager.start { [weak self] keyPress in
            #if DEBUG
            logger.debug("KeyPress received: keyCode=\(keyPress.keyCode) modifiers=\(keyPress.modifiers.rawValue)")
            #endif
            return self?.handleKeyPress(keyPress) ?? false
        }
        logger.info("Event tap running: \(self.eventTapManager.isRunning)")
        DiagnosticLog.log("Event tap running: \(eventTapManager.isRunning)")
    }

    // MARK: - Key handling

    private func rebuildIndex() {
        triggerIndex = keyMatcher.buildIndex(for: shortcutStore.shortcuts)
        // Sync registered shortcuts to EventTapManager for synchronous event swallowing
        syncRegisteredShortcuts()
    }

    /// Build a Set<KeyPress> from the trigger index and pass it to EventTapManager.
    private func syncRegisteredShortcuts() {
        var keyPresses = Set<EventTapManager.KeyPress>()
        for trigger in triggerIndex.keys {
            let modifiers = NSEvent.ModifierFlags(rawValue: trigger.modifierMask)
            keyPresses.insert(EventTapManager.KeyPress(keyCode: trigger.keyCode, modifiers: modifiers))
        }
        eventTapManager.updateRegisteredShortcuts(keyPresses)
    }

    /// Returns `true` if the key press matched a shortcut (so the event should be consumed).
    private func handleKeyPress(_ keyPress: EventTapManager.KeyPress) -> Bool {
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
        DiagnosticLog.log("MATCHED: \(match.appName) - \(match.bundleIdentifier)")
        _ = trigger(match)
        return true
    }
}
