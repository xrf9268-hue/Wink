import AppKit
import Carbon.HIToolbox
import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "ShortcutManager")
private let shortcutManagerSuppressAutomaticPermissionPromptsArgument = "--suppress-automatic-permission-prompts"

/// The permission a revocation notification is about. `identifierToken` must
/// stay locale-stable — it drives `UNNotificationRequest` identity
/// (replacement/dedup), so it can never be built from the localized display
/// name (same locale-stable-identity principle as #323's persistence keys).
private enum PermissionKind {
    case accessibility
    case inputMonitoring

    var identifierToken: String {
        switch self {
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "input-monitoring"
        }
    }

    var displayName: String {
        switch self {
        case .accessibility: return String(localized: "Accessibility", bundle: WinkResourceBundle.bundle)
        case .inputMonitoring: return String(localized: "Input Monitoring", bundle: WinkResourceBundle.bundle)
        }
    }
}

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
    private var autoPausedByException = false
    private let secureInputProbe: () -> Bool
    private var lastSecureInputState = false
    /// Invoked from the 3s poll when observed capture-relevant state
    /// changed (permissions, secure input) so observers can re-pull
    /// `shortcutCaptureStatus()` without their own timers.
    var onCaptureStatusChange: (@MainActor () -> Void)?
    /// Fires whenever the composed pause state transitions (manual pause,
    /// exception auto-pause, either direction).
    var onCapturePauseStateChange: (@MainActor (_ paused: Bool) -> Void)?
    /// Fires when a hold-enabled shortcut's chord is held past the hold
    /// threshold. The consumer (AppController) owns what a hold action does;
    /// the manager only resolves the gesture and the matched shortcut.
    var onHoldActionTriggered: (@MainActor (AppShortcut) -> Void)?
    private var holdGestureArbiter: HoldGestureArbiter?
    /// True while an interactive Wink panel (the hold-to-show window picker)
    /// is key. Matched shortcut dispatch is gated on it instead of the full
    /// capture-pause machinery: providers keep running (registered chords
    /// stay swallowed and can't leak into the panel or the app underneath),
    /// nothing user-visible flips to "Paused", and the #375 mapping
    /// suspension isn't churned by every picker open. The original goal —
    /// no toggleApplication re-entry while the panel is up — holds because
    /// dispatch, not capture, is what's gated.
    private var interactivePanelSessionActive = false

    private var effectivePaused: Bool {
        shortcutsPaused || autoPausedByException
    }
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
        // Optional with a nil default instead of a closure-literal default:
        // the CI toolchain (Xcode 16.4, Swift 6.1.2) SILGen crashes while
        // lowering complex default-argument thunks for this initializer
        // (same class as the WindowCycleClient `.live` default); a nil
        // literal is trivially emitted and the closure moves into the body.
        secureInputProbe: (() -> Bool)? = nil,
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
        self.secureInputProbe = secureInputProbe ?? { IsSecureEventInputEnabled() }
    }

    func start() {
        wireHoldGestureArbiterIfNeeded()
        rebuildIndex()
        let inputMonitoringRequired = captureCoordinator.inputMonitoringRequired
        let ready: Bool
        if effectivePaused {
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
            "start(): ready=\(ready), ax=\(self.permissionService.isAccessibilityTrusted()), im=\(self.permissionService.isInputMonitoringTrusted()), inputMonitoringRequired=\(inputMonitoringRequired), paused=\(self.effectivePaused)"
        )
        diagnosticClient.log(
            "start(): ready=\(ready), ax=\(permissionService.isAccessibilityTrusted()), im=\(permissionService.isInputMonitoringTrusted()), inputMonitoringRequired=\(inputMonitoringRequired), paused=\(effectivePaused)"
        )
        hasStarted = true
        startPermissionMonitoring()
        attemptStartIfPermitted()
    }

    func stop() {
        hasStarted = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        holdGestureArbiter?.reset()
        captureCoordinator.stop()
    }

    private func wireHoldGestureArbiterIfNeeded() {
        guard holdGestureArbiter == nil else { return }
        let arbiter = HoldGestureArbiter(
            onTap: { [weak self] keyPress, pressDuration in
                // The tap-latency cost of opting into a hold action, measured
                // per gesture: a tap dispatches only at its up edge (or the
                // lost-keyUp probe), so added latency == press duration.
                self?.diagnosticClient.log(
                    "HOLD_GESTURE_TAP: keyCode=\(keyPress.keyCode) durationMs=\(Int(pressDuration * 1000))"
                )
                _ = self?.handleKeyPress(keyPress)
            },
            onHold: { [weak self] keyPress in
                self?.handleHoldGesture(keyPress)
            }
        )
        holdGestureArbiter = arbiter
        captureCoordinator.setPhasedKeyObserver { [weak self, weak arbiter] keyPress, phase in
            // Delivery-time pause guard: a phased event queued on the main
            // queue from the tap thread can land after a pause transition
            // already reset the arbiter — starting a fresh gesture then
            // would let its deadline open the picker (or dispatch a tap)
            // into a paused session.
            guard let self, !self.effectivePaused else { return }
            arbiter?.handle(keyPress, phase)
        }
    }

    func setInteractivePanelSessionActive(_ active: Bool) {
        interactivePanelSessionActive = active
        if active {
            // A gesture straddling the panel-open transition must not
            // resolve into a toggle or a second panel underneath it.
            holdGestureArbiter?.reset()
        }
    }

    private func handleHoldGesture(_ keyPress: KeyPress) {
        // Second layer of the late-delivery guard: an arbiter deadline
        // scheduled before a pause can still fire after it.
        guard !effectivePaused else {
            diagnosticClient.log("HOLD_GESTURE_IGNORED: capture paused")
            return
        }
        guard !interactivePanelSessionActive else {
            diagnosticClient.log("HOLD_GESTURE_IGNORED: interactive panel session active")
            return
        }
        let key = keyMatcher.trigger(for: keyPress)
        guard let match = triggerIndex[key], match.holdAction != nil else {
            // The phased set and the trigger index are rebuilt from the same
            // store, but a hold can resolve after a configuration change
            // removed the action mid-gesture; a stale hold degrades to a tap
            // rather than silently dropping the press.
            diagnosticClient.log(
                "HOLD_GESTURE_STALE: keyCode=\(keyPress.keyCode) fallback=tap"
            )
            _ = handleKeyPress(keyPress)
            return
        }
        logger.info("MATCHED_HOLD: \(match.appName) - \(match.bundleIdentifier)")
        diagnosticClient.log("MATCHED_HOLD: \(match.appName) - \(match.bundleIdentifier)")
        onHoldActionTriggered?(match)
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
            inputMonitoringGranted: permissionService.isInputMonitoringTrusted(),
            secureInputActive: secureInputProbe()
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

    func setHyperHoldObserver(_ observer: (@Sendable (HyperHoldEvent) -> Void)?) {
        captureCoordinator.setHyperHoldObserver(observer)
    }

    func setShortcutsPaused(_ paused: Bool) {
        guard shortcutsPaused != paused else {
            return
        }

        let wasEffectivelyPaused = effectivePaused
        shortcutsPaused = paused
        // Manual and exception pauses compose: capture only transitions
        // when the OR of both bits changes, so resuming one while the
        // other still holds keeps capture paused.
        guard effectivePaused != wasEffectivelyPaused else { return }
        applyEffectivePauseTransition()
    }

    /// Exception-rule auto-pause (frontmost VM/remote-desktop app).
    /// Never persists and never touches the user's manual pause bit.
    func setAutoPausedByException(_ paused: Bool) {
        guard autoPausedByException != paused else {
            return
        }

        let wasEffectivelyPaused = effectivePaused
        autoPausedByException = paused
        guard effectivePaused != wasEffectivelyPaused else { return }
        applyEffectivePauseTransition()
    }

    private func applyEffectivePauseTransition() {
        let paused = effectivePaused
        onCapturePauseStateChange?(paused)
        // A gesture straddling the pause transition must not resolve into a
        // tap or hold inside the paused session.
        holdGestureArbiter?.reset()
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
        let secureInput = secureInputProbe()
        if secureInput != lastSecureInputState {
            lastSecureInputState = secureInput
            diagnosticClient.log(secureInput
                ? "Secure Input engaged — Hyper/event-tap shortcuts degraded until it ends"
                : "Secure Input ended — shortcut capture back to normal")
            onCaptureStatusChange?()
        }
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
                sendPermissionNotification(permission: .accessibility)
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
                sendPermissionNotification(permission: .inputMonitoring)
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

        if effectivePaused {
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
    private func sendPermissionNotification(permission: PermissionKind) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Wink: Permission Lost", bundle: WinkResourceBundle.bundle)
            let displayName = permission.displayName
            content.body = String(
                localized: "\(displayName) permission was revoked. Wink needs this permission to work. Please re-enable it in System Settings > Privacy & Security > \(displayName).",
                bundle: WinkResourceBundle.bundle
            )
            // Identifier is built from the locale-stable token, never the
            // localized display name, so replacement/dedup keeps working
            // regardless of the user's language.
            let request = UNNotificationRequest(
                identifier: "wink-permission-\(permission.identifierToken)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func attemptStartIfPermitted(retryStandardProvider: Bool = true) {
        if effectivePaused {
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
        if !effectivePaused
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
        guard !interactivePanelSessionActive else {
            // The chord stays swallowed by the providers; only dispatch is
            // gated, so a press can never re-enter toggleApplication under
            // an open picker.
            diagnosticClient.log("KEYPRESS_IGNORED: interactive panel session active")
            return true
        }
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
