import AppKit
import ApplicationServices
import WinkIntents

@MainActor
final class AppController {
    struct SettingsSceneServices {
        let editor: ShortcutEditorState
        let profileState: ShortcutProfileState
        let preferences: AppPreferences
        let diagnostics: DiagnosticsState
        let insightsViewModel: InsightsViewModel
        let appListProvider: AppListProvider
        let shortcutStatusProvider: ShortcutStatusProvider
        let settingsLauncher: SettingsLauncher
        let firstShortcutOnboarding: FirstShortcutOnboardingState
    }

    struct MenuBarSceneServices {
        let shortcutStore: ShortcutStore
        let preferences: AppPreferences
        let profileState: ShortcutProfileState
        let shortcutStatusProvider: ShortcutStatusProvider
        let usageTracker: any UsageTracking
        let setShortcutsPaused: @MainActor (Bool) -> Void
        let openSettings: @MainActor (SettingsTab?) -> Void
        let quit: @MainActor () -> Void
    }

    static let firstLaunchCompletedDefaultsKey = "com.wink.firstLaunchCompleted"
    static let lastSeenVersionDefaultsKey = "com.wink.lastSeenVersion"

    private let shortcutStore = ShortcutStore()
    private let profileStore = ShortcutProfileStore()
    /// Points at the ACTIVE profile's data file and carries the compat
    /// `shortcuts.json` mirror as a derived copy, so every existing save path
    /// stays profile-agnostic. A refused compat rewrite surfaces through the
    /// profile state's shared stale-mirror caveat — the save itself has
    /// already committed and is never failed by derived data.
    private lazy var persistenceService = profileStore.makeActiveProfilePersistenceService(
        onMirrorWriteOutcome: { [weak self] restored in
            Task { @MainActor [weak self] in
                self?.profileState.reportMirrorWriteOutcomeAfterSave(restored: restored)
            }
        }
    )
    private let usageTracker = UsageTracker()
    private let hyperKeyService = HyperKeyService()
    private let appBundleLocator = AppBundleLocator()
    private let userDefaults: UserDefaults
    private lazy var updateService = SparkleUpdateService()
    private let whatsNewPresenter = WhatsNewPresenter()
    private let updatePanelPresenter = UpdatePanelPresenter()
    private lazy var appSwitcher = AppSwitcher()
    private lazy var settingsLauncher = SettingsLauncher(userDefaults: userDefaults)
    private lazy var settingsShortcutStatusProvider = ShortcutStatusProvider()
    private lazy var shortcutManager: ShortcutManager = {
        let manager = ShortcutManager(
            shortcutStore: shortcutStore,
            persistenceService: persistenceService,
            appSwitcher: appSwitcher,
            usageTracker: usageTracker,
            appBundleLocator: appBundleLocator,
            automaticPermissionPromptingEnabled: ShortcutManager.defaultAutomaticPermissionPromptingEnabled(),
            diagnosticClient: .live
        )
        // Installed HERE, not in start(): AppPreferences' initializer replays
        // a persisted manual pause, and SwiftUI evaluates the scene services
        // (which construct AppPreferences) before applicationDidFinishLaunching
        // ever calls start(). Since AppPreferences takes this manager as an
        // init argument, any path that constructs it forces this lazy block
        // first — the handler is provably installed before the first pause
        // transition can fire, whichever access path wins. Without that
        // ordering, a launch into a paused state never suspends the hidutil
        // mapping and the startup reapply re-arms Caps Lock → F19 with
        // capture stopped (#375 at launch).
        //
        // Pause (manual or exception-rule) stops the Hyper provider without
        // an `ended` event; a presented sheet must not outlive capture, and
        // the mapping follows the same composed bit: a paused Wink consumes
        // no F19, so Caps Lock reverts to native behavior for the paused
        // interval and comes back on resume.
        manager.onCapturePauseStateChange = { [weak self] paused in
            if paused {
                self?.cheatSheetHUD.reset()
                self?.windowPickerHUD.dismiss()
                self?.searchPaletteHUD.dismiss()
                self?.hyperKeyService.suspendMappingForPause()
            } else {
                self?.hyperKeyService.resumeMappingAfterPause()
            }
        }
        return manager
    }()
    private lazy var windowPickerHUD = WindowPickerHUDController(
        onSessionStateChange: { [weak self] active in
            self?.shortcutManager.setInteractivePanelSessionActive(active)
        },
        focusWindow: { [weak self] windowID, session in
            self?.appSwitcher.focusPickedWindow(windowID: windowID, session: session) ?? false
        }
    )
    /// Search-to-switch palette (#356). Shares the exact single-flag gate
    /// #352 wired for the window picker (`setInteractivePanelSessionActive`)
    /// — since both controllers read/write the SAME shared bool and each
    /// panel's own trigger keypress is swallowed by `ShortcutManager`
    /// whenever that bool is already true, only one of the two panels can
    /// ever be open at a time with no extra coordination code: whichever
    /// trigger fires first wins, and the other's trigger keypress is a
    /// silent no-op (consumed, no dispatch) until the first panel closes.
    private lazy var searchPaletteHUD = SearchPaletteHUDController(
        onSessionStateChange: { [weak self] active in
            self?.shortcutManager.setInteractivePanelSessionActive(active)
        },
        candidatesProvider: { [weak self] in
            guard let self else { return [] }
            // A workspace snapshot taken once per open, not re-queried per
            // keystroke — see SearchPaletteMatcher.swift for the latency
            // rationale behind building candidates once up front.
            let runningBundleIdentifiers = Set(
                NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            )
            return SearchPaletteCandidateBuilder.build(
                apps: self.appListProvider.allApps,
                shortcuts: self.shortcutStore.shortcuts,
                runningBundleIdentifiers: runningBundleIdentifiers
            )
        },
        recentBundleIdentifiersProvider: { [weak self] in
            self?.appListProvider.recentBundleIDs ?? []
        },
        activate: { [weak self] entry in
            guard let self else { return false }
            // NOT toggleApplication's default semantics: a plain call would
            // hide the target if it's already frontmost (real toggle-off),
            // which is wrong for "type a name, land on that app". Forcing
            // `.focus` makes the already-frontmost branch a pure re-focus
            // (see AppSwitcher.performFrontmostFocus) — activation only,
            // independent of whatever frontmost behavior the user may have
            // separately configured for a real shortcut targeting the same
            // app. Calling AppSwitcher directly (not shortcutManager.trigger)
            // matches WinkURLCommandHandler's direct app-action handling: this
            // ad hoc shortcut has no persisted id, so recording "usage"
            // against it would just orphan a UUID no UI ever shows.
            //
            // bypassCooldown: true — a palette commit is a direct, one-shot
            // user choice ("activate this app right now"), not a repeated
            // key-chord press. Without this, hiding an app via its real
            // shortcut and then committing the SAME app from the palette
            // within the 400ms cooldown window would silently drop the
            // commit after the palette already dismissed, leaving the app
            // hidden with no feedback. The re-entry guard and cooldown STAMP
            // stay intact (see AppSwitcher.toggleApplication) — only the
            // early cooldown *check* is skipped, and the stamp this call
            // writes still protects the very next real shortcut press.
            //
            // Recency at request time (same semantics as AppPickerPopover's
            // selection path): the palette's own empty-query list is ordered
            // by recentBundleIDs, so a committed pick must feed it — noted
            // even if activation later fails, matching the picker's
            // request-time convention.
            self.appListProvider.noteRecentApp(bundleIdentifier: entry.bundleIdentifier)
            return self.appSwitcher.toggleApplication(
                for: AppShortcut(
                    appName: entry.name,
                    bundleIdentifier: entry.bundleIdentifier,
                    keyEquivalent: "",
                    modifierFlags: [],
                    frontmostBehaviorOverride: .focus
                ),
                bypassCooldown: true
            )
        }
    )
    private lazy var appPreferences = AppPreferences(
        shortcutManager: shortcutManager,
        hyperKeyService: hyperKeyService,
        updateService: updateService,
        userDefaults: userDefaults
    )
    private lazy var firstShortcutOnboarding: FirstShortcutOnboardingState = {
        let client = FirstShortcutOnboardingState.Client(
            readiness: { [weak self] shortcut in
                self?.shortcutManager.firstShortcutOnboardingReadiness(for: shortcut)
                    ?? FirstShortcutOnboardingReadiness(
                        route: .standard,
                        shortcutAvailable: false,
                        accessibilityGranted: false,
                        inputMonitoringGranted: false,
                        routeReady: false,
                        shortcutsPaused: false,
                        secureInputActive: false
                    )
            },
            requestPermissions: { [weak self] shortcut in
                self?.shortcutManager.requestPermissions(for: shortcut)
                self?.appPreferences.refreshPermissions()
            },
            openSystemSettings: { destination in
                let pane: String
                switch destination {
                case .accessibility:
                    pane = "Privacy_Accessibility"
                case .inputMonitoring:
                    pane = "Privacy_ListenEvent"
                }
                guard let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
                ) else { return }
                NSWorkspace.shared.open(url)
            },
            setAutomaticPermissionPromptSuppressed: { [weak self] suppressed in
                self?.shortcutManager.setAutomaticPermissionPromptSuppressedForOnboarding(
                    suppressed
                )
            },
            scheduleVerificationTimeout: { delay, operation in
                Task { @MainActor in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    operation()
                }
            },
            log: { message in
                DiagnosticLog.log(message)
            }
        )
        return FirstShortcutOnboardingState(
            userDefaults: userDefaults,
            legacyCompletionDefaultsKey: Self.firstLaunchCompletedDefaultsKey,
            client: client
        )
    }()
    private lazy var actionExecutor = WinkActionExecutor(client: .init(
        isShortcutsPaused: { [weak self] in
            self?.appPreferences.shortcutsPaused ?? false
        },
        setShortcutsPaused: { [weak self] paused in
            self?.appPreferences.setShortcutsPaused(paused)
        },
        isSearchPalettePresented: { [weak self] in
            self?.searchPaletteHUD.isPresented ?? false
        },
        canPresentSearchPalette: { [weak self] in
            guard let self else { return false }
            return !self.windowPickerHUD.isPresented
        },
        showSearchPalette: { [weak self] in
            self?.searchPaletteHUD.present()
        },
        openSettings: { [weak self] tab in
            guard let self else { return }
            self.settingsLauncher.open(tab: tab)
            NSApp.activate()
        },
        openSettingsIfReady: { [weak self] tab in
            guard let self, self.settingsLauncher.openIfReady(tab: tab) else {
                return false
            }
            NSApp.activate()
            return true
        },
        waitForSettingsPresentation: { [weak self] in
            guard let self else { return false }
            return try await self.settingsLauncher.waitForSettingsPresentation()
        }
    ))
    private lazy var urlCommandHandler = WinkURLCommandHandler(client: .init(
        applicationURL: { [weak self] bundleIdentifier in
            self?.appBundleLocator.applicationURL(for: bundleIdentifier)
        },
        performApplicationAction: { [weak self] shortcut, bypassCooldown in
            self?.appSwitcher.toggleApplication(
                for: shortcut,
                bypassCooldown: bypassCooldown
            ) ?? false
        },
        executeSharedAction: { [weak self] action, settingsPresentationPolicy in
            try self?.actionExecutor.execute(
                action,
                settingsPresentationPolicy: settingsPresentationPolicy
            )
        },
        log: { message in
            DiagnosticLog.log(message)
        }
    ))
    private lazy var shortcutEditor = ShortcutEditorState(
        shortcutStore: shortcutStore,
        shortcutManager: shortcutManager,
        usageTracker: usageTracker,
        isShortcutRetainedByAnotherProfile: { [weak self] id in
            self?.profileStore.isShortcutRetainedByAnotherProfile(id) ?? false
        },
        reserveUsageDeletion: { [weak self] id, claim in
            guard let self else { return }
            if claim {
                self.profileStore.reserveUsageDeletions([id])
            } else {
                self.profileStore.releaseUsageDeletions([id])
            }
        },
        onShortcutConfigurationChange: { [weak self] in
            self?.appPreferences.refreshPermissions()
        },
        onShortcutAdded: { [weak self] shortcut in
            self?.firstShortcutOnboarding.shortcutWasAdded(shortcut)
        }
    )
    private lazy var profileState = ShortcutProfileState(
        store: profileStore,
        shortcutManager: shortcutManager,
        usageTracker: usageTracker,
        prepareForSwitch: { [weak self] in
            guard let self else { return DiscardedProfileSwitchDrafts() }
            // Interactive panels first: their sessions are scoped to the
            // outgoing binding set, and a picker left open across the switch
            // would gate dispatch for chords that no longer exist.
            self.windowPickerHUD.dismiss()
            self.searchPaletteHUD.dismiss()
            self.cheatSheetHUD.reset()
            return self.shortcutEditor.cancelDraftsForProfileSwitch()
        },
        hasUnsavedEditorWork: { [weak self] in
            self?.shortcutEditor.hasUnsavedWork ?? false
        },
        onProfileApplied: { [weak self] in
            self?.appPreferences.refreshPermissions()
            self?.shortcutEditor.scheduleUsageRefresh()
            // Insights reads `ShortcutStore` only while refreshing, so its
            // rankings, unused-shortcut list, and bound-app suggestions keep
            // describing the OUTGOING profile after a switch made from the
            // menu bar — the tab is already open, so neither the tab-change
            // nor the become-active refresh fires.
            self?.insightsViewModel.scheduleRefresh()
        }
    )
    private lazy var frontmostExceptionMonitor = FrontmostExceptionMonitor(
        onAutoPauseChange: { [weak self] paused, appName in
            self?.shortcutManager.setAutoPausedByException(paused)
            self?.appPreferences.setAutoPauseTrigger(appName: paused ? appName : nil)
            // Keep the observable capture status truthful under auto-pause.
            self?.appPreferences.refreshPermissions()
        }
    )
    private lazy var cheatSheetHUD = CheatSheetHUDController(
        rowsProvider: { [weak self] in
            guard let self else { return [] }
            // Exactly the rows the CURRENT trigger index was built from: one
            // the index dropped (uninstalled app, unrecognized sentinel)
            // must not render as an armed chord (#404).
            return self.shortcutStore.shortcuts
                .filter { self.shortcutManager.isShortcutInTriggerIndex($0) }
                .map { shortcut in
                    CheatSheetRow(
                        id: shortcut.id,
                        appName: shortcut.displayAppName,
                        bundleIdentifier: shortcut.bundleIdentifier,
                        keyDisplay: ModifierFormatting.displayText(
                            modifierFlags: shortcut.modifierFlags,
                            keyEquivalent: shortcut.keyEquivalent
                        )
                    )
                }
        },
        isEnabled: { [weak self] in
            guard let self else { return false }
            // The sheet rides F19 events from the interception tap, which
            // only runs when at least one Hyper shortcut is enabled — a
            // display toggle must not become an Input Monitoring demand.
            return self.appPreferences.hyperCheatSheetEnabled
                && self.appPreferences.hyperKeyEnabled
                && self.appPreferences.shortcutCaptureStatus.eventTapActive
        }
    )
    private lazy var appActivationRecorder = AppActivationRecorder(
        onActivation: { [weak self] bundleIdentifier in
            self?.recordAppActivation(bundleIdentifier)
        }
    )
    private lazy var insightsViewModel = InsightsViewModel(
        usageTracker: usageTracker,
        shortcutStore: shortcutStore
    )
    private lazy var appListProvider = AppListProvider()
    private lazy var diagnosticsState = DiagnosticsState(
        client: DiagnosticsClientLive.make(
            preferences: appPreferences,
            shortcutStore: shortcutStore
        )
    )
    private lazy var settingsSceneServicesStorage = SettingsSceneServices(
        editor: shortcutEditor,
        profileState: profileState,
        preferences: appPreferences,
        diagnostics: diagnosticsState,
        insightsViewModel: insightsViewModel,
        appListProvider: appListProvider,
        shortcutStatusProvider: settingsShortcutStatusProvider,
        settingsLauncher: settingsLauncher,
        firstShortcutOnboarding: firstShortcutOnboarding
    )
    private lazy var menuBarSceneServicesStorage = MenuBarSceneServices(
        shortcutStore: shortcutStore,
        preferences: appPreferences,
        profileState: profileState,
        shortcutStatusProvider: settingsShortcutStatusProvider,
        usageTracker: usageTracker,
        setShortcutsPaused: { [weak self] paused in
            do {
                try self?.actionExecutor.execute(paused ? .pause : .resume)
            } catch {
                DiagnosticLog.log("ACTION: menu pause transition failed: \(error.localizedDescription)")
            }
        },
        openSettings: { [weak self] tab in
            do {
                try self?.actionExecutor.execute(.openSettings(tab.map(WinkSettingsTabIntentValue.init)))
            } catch {
                DiagnosticLog.log("ACTION: menu settings open failed: \(error.localizedDescription)")
            }
        },
        quit: {
            NSApplication.shared.terminate(nil)
        }
    )

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var settingsSceneServices: SettingsSceneServices {
        settingsSceneServicesStorage
    }

    var settingsLauncherService: SettingsLauncher {
        settingsLauncher
    }

    var menuBarSceneServices: MenuBarSceneServices {
        menuBarSceneServicesStorage
    }

    var appIntentClient: WinkActionClient {
        actionExecutor.appIntentClient()
    }

    /// FIFO chain over activation writes and the opt-out purge: unstructured
    /// tasks have no mutual ordering, so a queued write could otherwise land
    /// AFTER the purge (retaining data while disabled) or a queued purge
    /// could erase rows recorded after a quick re-enable.
    private var activationWriteChain: Task<Void, Never>?

    private func recordAppActivation(_ bundleIdentifier: String) {
        let tracker = usageTracker
        activationWriteChain = Task { [previous = activationWriteChain] in
            await previous?.value
            await tracker.recordAppActivation(bundleIdentifier: bundleIdentifier)
        }
    }

    private func purgeAppActivations() {
        let tracker = usageTracker
        activationWriteChain = Task { [previous = activationWriteChain] in
            await previous?.value
            await tracker.deleteAllAppActivations()
        }
    }

    func start() {
        DiagnosticLog.rotateIfNeeded()
        DiagnosticLog.log("Wink starting, version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")

        // Set AX global messaging timeout to 1s (default is 6s).
        // Prevents AX calls from blocking threads for too long when apps are unresponsive.
        // Reference: alt-tab-macos
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

        // Wire the update panel before the updater starts so a launch-time
        // resumed session can present immediately.
        updateService.presentUpdatePanel = { [weak self] activate in
            guard let self else { return }
            self.updatePanelPresenter.present(preferences: self.appPreferences, activate: activate)
        }
        updateService.dismissUpdatePanel = { [weak self] in
            self?.updatePanelPresenter.dismiss()
        }

        // The onCapturePauseStateChange handler is installed inside the
        // shortcutManager lazy initializer, not here — SwiftUI's scene
        // services construct AppPreferences before start() runs, and the
        // initial pause replay must already see the handler.

        // Exception rules: configure from persisted preferences, follow
        // future edits, and start following frontmost changes.
        appPreferences.onFrontmostExceptionConfigurationChange = { [weak self] in
            guard let self else { return }
            self.frontmostExceptionMonitor.configure(
                enabled: self.appPreferences.frontmostExceptionsEnabled,
                ruleBundleIdentifiers: self.appPreferences.frontmostExceptionRules
            )
        }
        frontmostExceptionMonitor.configure(
            enabled: appPreferences.frontmostExceptionsEnabled,
            ruleBundleIdentifiers: appPreferences.frontmostExceptionRules
        )
        frontmostExceptionMonitor.startObservingWorkspaceNotifications()

        appPreferences.onSuggestShortcutsConfigurationChange = { [weak self] enabled in
            // Recorder disables synchronously before the purge enqueues, so
            // the FIFO chain guarantees "stop AND clear": prior writes land
            // first, no later writes exist, and post-re-enable writes queue
            // after the purge.
            self?.appActivationRecorder.setEnabled(enabled)
            if !enabled {
                self?.purgeAppActivations()
            }
        }
        appActivationRecorder.setEnabled(appPreferences.suggestShortcutsFromUsage)
        appActivationRecorder.startObservingWorkspaceNotifications()
        if !appPreferences.suggestShortcutsFromUsage {
            // Quitting before the async opt-out purge ran leaves rows on
            // disk with the preference off; sweep them on every disabled
            // startup so re-enabling never resurfaces pre-opt-out counts.
            purgeAppActivations()
        }

        // Configured BEFORE the startup sequence so launching while an
        // exception app is frontmost never lets capture (or permission
        // prompts) fire ahead of the auto-pause. Applies the delivered
        // snapshot directly (not `refreshPermissions()`'s independent
        // re-pull) — the manager's AX/IM/Secure-Input probes are volatile,
        // and a second probe here could race and desync from what the
        // manager just deduped on (#383).
        shortcutManager.onCaptureStatusChange = { [weak self] status in
            self?.appPreferences.applyCaptureStatus(status)
        }
        // Hold events arrive on the tap thread; hop once to the main actor
        // via the main QUEUE, whose FIFO ordering keeps began/ended in
        // emission order (sibling Tasks carry no such guarantee, and a
        // reordered quick tap would arm a timer after its release).
        let cheatSheet = cheatSheetHUD
        shortcutManager.setHyperHoldObserver { event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    cheatSheet.handle(event)
                }
            }
        }
        appPreferences.onHyperKeyEnabledChange = { [weak self] enabled in
            if !enabled {
                // Disabling Hyper mid-hold clears tap state without an
                // `ended`; reset so no timer stays armed and no presented
                // sheet sticks.
                self?.cheatSheetHUD.reset()
            }
        }
        // Hold-to-show window picker (#352): a hold-enabled shortcut's chord
        // held past the threshold resolves the target's windows and presents
        // the picker; nothing to pick (target not running, no eligible
        // windows, transient AX failure) degrades to a silent no-op.
        shortcutManager.onHoldActionTriggered = { [weak self] shortcut in
            guard let self,
                  let session = self.appSwitcher.windowPickerSession(for: shortcut) else {
                return
            }
            self.windowPickerHUD.present(session: session)
        }
        // Search-to-switch palette (#356): a plain key-down match on the
        // dedicated trigger shortcut opens the palette. Pre-warm the app
        // list now (not on first open) so a trigger pressed any time after
        // launch sees an already-scanned, cached `AppListProvider.allApps`
        // — the open-to-first-keystroke latency budget has no room for a
        // synchronous filesystem scan. The scan is still async, though: a
        // trigger pressed before it lands must not leave the palette stuck
        // empty until dismiss/reopen, so the palette also self-heals once
        // the scan (this one or any later one) actually completes.
        appListProvider.onRefreshCompleted = { [weak self] in
            self?.searchPaletteHUD.refreshCandidatesIfPresented()
        }
        appListProvider.refreshIfNeeded()
        shortcutManager.onSearchPaletteTriggered = { [weak self] in
            do {
                try self?.actionExecutor.execute(.showSearchPalette)
            } catch {
                DiagnosticLog.log("ACTION: shortcut Search Palette failed: \(error.localizedDescription)")
            }
        }
        shortcutManager.onRecordingSessionKeyPress = { [weak self] keyPress in
            self?.shortcutEditor.handleRecordingSessionKeyPress(keyPress)
        }
        shortcutManager.shouldCaptureOnboardingTriggerContext = { [weak self] shortcut in
            self?.firstShortcutOnboarding.isAwaitingPhysicalVerification(for: shortcut.id) == true
        }
        shortcutManager.onCapturedShortcutTrigger = { [weak self] shortcut, accepted, targetWasFrontmost, activationAttempt in
            self?.firstShortcutOnboarding.capturedShortcutTriggered(
                shortcut,
                accepted: accepted,
                targetWasFrontmost: targetWasFrontmost,
                activationAttempt: activationAttempt
            )
        }
        shortcutManager.onShortcutSetApplied = { [weak self] shortcuts in
            self?.firstShortcutOnboarding.synchronize(shortcuts: shortcuts)
        }
        appSwitcher.setActivationConfirmationObserver { [weak self] identity in
            self?.firstShortcutOnboarding.activationAttemptDidConfirm(identity)
        }

        // Read the legacy state before onboarding potentially records an
        // explicit Skip/success (or exempts an already-configured upgrade), so
        // the What's New gate still distinguishes a fresh install.
        let hasLaunchedBefore = userDefaults.bool(forKey: Self.firstLaunchCompletedDefaultsKey)
        var shouldPresentFirstShortcutOnboarding = false

        Self.runStartupSequence(
            startUpdateService: { _ = updateService },
            // Profile-aware: returns the ACTIVE profile's shortcuts, and an
            // empty set for every recovery state so an unreadable
            // configuration can never fall through to a different profile's
            // bindings. The failure itself is surfaced by `profileState`.
            loadShortcuts: { profileState.loadAtStartup() },
            replaceShortcuts: { shortcutStore.replaceAll(with: $0) },
            // "Deferred by an active pause" counts as armed: the routing
            // decision below must reflect user intent, not the pause. With
            // capture paused the tap isn't running anyway, and resume
            // restores the mapping — disabling Hyper routing here instead
            // would leave F19 mapped-but-unintercepted after resume until a
            // manual Hyper off/on cycle.
            reapplyHyperIfNeeded: {
                hyperKeyService.reapplyIfNeeded() || hyperKeyService.isSuspended
            },
            isHyperEnabled: { hyperKeyService.isEnabled },
            setHyperKeyEnabled: { shortcutManager.setHyperKeyEnabled($0) },
            preparePreferences: { _ = appPreferences },
            prepareFirstShortcutOnboarding: {
                guard profileState.canPrepareFirstShortcutOnboarding else {
                    return false
                }
                shouldPresentFirstShortcutOnboarding = firstShortcutOnboarding.prepareForLaunch(
                    shortcuts: shortcutStore.shortcuts,
                    hasLegacyCompletion: hasLaunchedBefore
                )
                return shouldPresentFirstShortcutOnboarding
            },
            startShortcutManager: { suppressAutomaticPermissionPrompt in
                shortcutManager.start(
                    suppressAutomaticPermissionPrompt: suppressAutomaticPermissionPrompt
                )
            }
        )

        if shouldPresentFirstShortcutOnboarding {
            // Pending attempts were restored before capture started so the
            // launch prompt could be suppressed. Refresh once more against
            // the now-live provider state before presenting the guide.
            firstShortcutOnboarding.refreshReadiness()
            openSettings(tab: .shortcuts)
        }

        let currentVersion = Self.currentVersionString()
        let notes = WhatsNewCatalog.notes(for: currentVersion)
        if Self.consumeWhatsNewGate(
            userDefaults: userDefaults,
            currentVersion: currentVersion,
            hasLaunchedBefore: hasLaunchedBefore,
            hasNotes: !notes.isEmpty
        ) {
            // Slight delay so the panel appears after launch settles; it is
            // non-activating and never steals focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.whatsNewPresenter.present(version: currentVersion, notes: notes)
            }
        }
    }

    func stop() {
        hyperKeyService.clearMappingIfEnabled()
        shortcutManager.stop()
    }

    /// `wink://` delivery is untrusted local input. The pure parser rejects
    /// the complete URL before this handler performs any side effect, while
    /// accepted commands reuse the shared action executor or AppSwitcher's
    /// established toggle/focus lanes. Raw URLs are never logged.
    func handleURLStrings(_ rawValues: [String]) {
        urlCommandHandler.handle(rawValues)
    }

    func openPrimarySettingsWindow() {
        openSettings()
    }

    private func openSettings(tab: SettingsTab? = nil) {
        settingsLauncher.open(tab: tab)
        NSApp.activate()
    }

    static func runStartupSequence(
        startUpdateService: @MainActor () -> Void,
        loadShortcuts: @MainActor () throws -> [AppShortcut],
        replaceShortcuts: @MainActor ([AppShortcut]) -> Void,
        reapplyHyperIfNeeded: @MainActor () -> Bool,
        isHyperEnabled: @MainActor () -> Bool,
        setHyperKeyEnabled: @MainActor (Bool) -> Void,
        preparePreferences: @MainActor () -> Void = {},
        prepareFirstShortcutOnboarding: @MainActor () -> Bool = { false },
        startShortcutManager: @MainActor (_ suppressAutomaticPermissionPrompt: Bool) -> Void
    ) {
        startUpdateService()
        do {
            replaceShortcuts(try loadShortcuts())
        } catch {
            DiagnosticLog.log(
                "Startup skipped shortcut restore because persistence loading failed: \(error.localizedDescription)"
            )
        }
        let isHyperEnabled = isHyperEnabled()
        let isHyperMappingApplied = reapplyHyperIfNeeded()
        setHyperKeyEnabled(isHyperEnabled && isHyperMappingApplied)
        preparePreferences()
        let suppressAutomaticPermissionPrompt = prepareFirstShortcutOnboarding()
        startShortcutManager(suppressAutomaticPermissionPrompt)
    }

    /// Returns true exactly once per version change on an already-onboarded
    /// install (fresh installs only record the version). Always writes back
    /// `lastSeenVersion` synchronously, mirroring `consumeFirstLaunchFlag`'s
    /// crash-safe consume-then-act shape. The decision itself is
    /// `LaunchGates.shouldShowWhatsNew` (pure, unit-tested).
    static func consumeWhatsNewGate(
        userDefaults: UserDefaults,
        currentVersion: String,
        hasLaunchedBefore: Bool,
        hasNotes: Bool
    ) -> Bool {
        let lastSeenVersion = userDefaults.string(forKey: lastSeenVersionDefaultsKey)
        userDefaults.set(currentVersion, forKey: lastSeenVersionDefaultsKey)
        return LaunchGates.shouldShowWhatsNew(
            currentVersion: currentVersion,
            hasLaunchedBefore: hasLaunchedBefore,
            lastSeenVersion: lastSeenVersion,
            hasNotes: hasNotes
        )
    }

    private static func currentVersionString(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

private extension WinkSettingsTabIntentValue {
    init(_ settingsTab: SettingsTab) {
        switch settingsTab {
        case .shortcuts: self = .shortcuts
        case .general: self = .general
        case .insights: self = .insights
        }
    }
}
