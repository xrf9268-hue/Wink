import Foundation
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
    private var lastPermissionState: Bool = false

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

    // MARK: - Permission monitoring

    private func startPermissionMonitoring() {
        lastPermissionState = permissionService.isTrusted()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermissionChange()
            }
        }
    }

    private func checkPermissionChange() {
        let granted = permissionService.isTrusted()
        logger.info("checkPermission: granted=\(granted) last=\(self.lastPermissionState) tapRunning=\(self.eventTapManager.isRunning)")
        DiagnosticLog.log("checkPermission: granted=\(granted) last=\(lastPermissionState) tapRunning=\(eventTapManager.isRunning)")
        guard granted != lastPermissionState else { return }
        lastPermissionState = granted

        if granted {
            logger.notice("Permission change detected: granted — starting event tap")
            DiagnosticLog.log("Permission change detected: granted — starting event tap")
            attemptStartIfPermitted()
        } else {
            logger.error("Permission change detected: revoked — stopping event tap")
            DiagnosticLog.log("Permission change detected: revoked — stopping event tap")
            eventTapManager.stop()
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
