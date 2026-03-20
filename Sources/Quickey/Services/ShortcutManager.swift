import Foundation
import os.log

private let logger = Logger(subsystem: "com.quickey.app", category: "ShortcutManager")

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
        debugLog("start(): trusted=\(trusted), isTrusted=\(permissionService.isTrusted())")
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
        debugLog("checkPermission: granted=\(granted) last=\(lastPermissionState) tapRunning=\(eventTapManager.isRunning)")
        guard granted != lastPermissionState else { return }
        lastPermissionState = granted

        if granted {
            debugLog("Permission change detected: granted — starting event tap")
            attemptStartIfPermitted()
        } else {
            debugLog("Permission change detected: revoked — stopping event tap")
            eventTapManager.stop()
        }
    }

    private func attemptStartIfPermitted() {
        guard permissionService.isTrusted() else {
            debugLog("attemptStart: not trusted, skipping")
            return
        }
        guard !eventTapManager.isRunning else {
            debugLog("attemptStart: already running")
            return
        }

        rebuildIndex()
        debugLog("attemptStart: starting event tap, shortcuts count: \(shortcutStore.shortcuts.count), triggerIndex count: \(triggerIndex.count)")
        eventTapManager.start { [weak self] keyPress in
            Self.debugLog("KeyPress received: keyCode=\(keyPress.keyCode) modifiers=\(keyPress.modifiers.rawValue)")
            return self?.handleKeyPress(keyPress) ?? false
        }
        debugLog("Event tap running: \(eventTapManager.isRunning)")
    }

    // MARK: - Debug logging

    private static let debugLogPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/Quickey/debug.log").path

    static func debugLog(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: debugLogPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: debugLogPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: debugLogPath, contents: data)
        }
    }

    private func debugLog(_ message: String) {
        Self.debugLog(message)
    }

    // MARK: - Key handling

    private func rebuildIndex() {
        triggerIndex = keyMatcher.buildIndex(for: shortcutStore.shortcuts)
    }

    /// Returns `true` if the key press matched a shortcut (so the event should be consumed).
    private func handleKeyPress(_ keyPress: EventTapManager.KeyPress) -> Bool {
        let key = keyMatcher.trigger(for: keyPress)
        NSLog("[DEBUG] handleKeyPress: trigger=(\(key.keyCode), \(key.modifierMask)), index keys: \(triggerIndex.keys.map { ($0.keyCode, $0.modifierMask) })")
        guard let match = triggerIndex[key] else {
            return false
        }
        NSLog("[DEBUG] MATCHED: \(match.appName) - \(match.bundleIdentifier)")
        _ = trigger(match)
        return true
    }
}
