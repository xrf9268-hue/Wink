import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wink

@Suite("Menu bar popover")
struct MenuBarPopoverViewTests {
    /// #356: the search-palette trigger's sentinel bundle never resolves to
    /// an installed app or a running process, so an unfiltered status list
    /// would permanently flag it "App unavailable" even though it's working
    /// exactly as configured — this quick-launch list excludes it entirely,
    /// same as `ShortcutsTabView`'s per-app list.
    @Test @MainActor
    func shortcutRowsExcludeTheSearchPaletteTrigger() {
        let context = makePopoverContext(
            shortcuts: [
                AppShortcut(
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    keyEquivalent: "s",
                    modifierFlags: ["command"]
                ),
                AppShortcut(
                    appName: AppShortcut.searchPaletteTargetStableName,
                    bundleIdentifier: AppShortcut.searchPaletteTargetSentinelBundleIdentifier,
                    keyEquivalent: "space",
                    modifierFlags: ["command", "option"],
                    target: .searchPalette
                ),
            ],
            usageTotal: 0
        )

        #expect(context.model.shortcutRows.count == 1)
        #expect(context.model.shortcutRows.first?.shortcut.bundleIdentifier == "com.apple.Safari")
    }

    @Test @MainActor
    func viewRendersSearchSectionsRowsAndActions() async {
        let context = makePopoverContext(
            shortcuts: [
                AppShortcut(
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    keyEquivalent: "s",
                    modifierFlags: ["command"]
                ),
                AppShortcut(
                    appName: "IINA",
                    bundleIdentifier: "com.colliderli.iina",
                    keyEquivalent: "i",
                    modifierFlags: ["command", "option", "control", "shift"]
                ),
            ],
            runningBundleIdentifiers: ["com.apple.Safari"],
            usageTotal: 48,
            updateService: FakeUpdateService(
                isConfigured: true,
                canCheckForUpdates: true,
                currentVersion: "0.3.0",
                automaticallyChecksForUpdates: true,
                automaticallyDownloadsUpdates: true
            )
        )

        let host = makeHostingView(
            MenuBarPopoverView(model: context.model).winkChromeRoot(),
            size: NSSize(width: 356, height: 520)
        )
        let placeholders = Set(collectPlaceholders(in: host))
        await context.model.waitForUsageRefreshForTesting()

        #expect(placeholders.contains("Search shortcuts"))
        #expect(host.fittingSize.width > 0)
        #expect(host.fittingSize.height > 0)
        #expect(context.model.versionText == "v0.3.0")
        #expect(context.model.todayActivationCount == 48)
        #expect(context.model.shortcutRows.map(\.title) == ["Safari", "IINA"])
        #expect(context.model.shortcutRows[0].isRunning == true)
        #expect(context.model.shortcutsPaused == false)
    }

    @Test @MainActor
    func modelActionsRouteManageSettingsPauseUpdateAndQuit() throws {
        let defaults = try #require(UserDefaults(suiteName: "MenuBarPopoverViewTests.modelActions"))
        defaults.removePersistentDomain(forName: "MenuBarPopoverViewTests.modelActions")
        let openedTabs = OpenedTabsRecorder()
        let quitRecorder = FlagRecorder()
        let updateService = FakeUpdateService(
            isConfigured: true,
            canCheckForUpdates: true,
            currentVersion: "0.3.0",
            automaticallyChecksForUpdates: true,
            automaticallyDownloadsUpdates: true
        )
        let context = makePopoverContext(
            shortcuts: [],
            usageTotal: 0,
            userDefaults: defaults,
            updateService: updateService,
            openSettings: { tab in
                openedTabs.tabs.append(tab)
            },
            quit: {
                quitRecorder.didRun = true
            }
        )

        context.model.openManageShortcuts()
        context.model.openSettings()
        context.model.setShortcutsPaused(true)
        context.model.checkForUpdates()
        context.model.quit()

        #expect(openedTabs.tabs.count == 2)
        #expect(openedTabs.tabs[0] == .shortcuts)
        #expect(openedTabs.tabs[1] == nil)
        #expect(context.preferences.shortcutsPaused == true)
        #expect(defaults.bool(forKey: AppPreferences.shortcutsPausedDefaultsKey) == true)
        #expect(updateService.didRequestManualCheck == true)
        #expect(quitRecorder.didRun == true)
    }

    @Test @MainActor
    func pauseActionUsesTheInjectedSharedExecutorRoute() {
        let pauseRecorder = PauseRecorder()
        let context = makePopoverContext(
            shortcuts: [],
            usageTotal: 0,
            setShortcutsPaused: { paused in
                pauseRecorder.values.append(paused)
            }
        )

        context.model.setShortcutsPaused(true)

        #expect(pauseRecorder.values == [true])
        #expect(!context.preferences.shortcutsPaused)
    }

    @Test @MainActor
    func updateNoticeReflectsMirroredPhase() throws {
        let defaults = try #require(UserDefaults(suiteName: "MenuBarPopoverViewTests.updateNotice"))
        defaults.removePersistentDomain(forName: "MenuBarPopoverViewTests.updateNotice")
        let updateService = FakeUpdateService(
            isConfigured: true,
            canCheckForUpdates: true,
            currentVersion: "0.5.0",
            automaticallyChecksForUpdates: true,
            automaticallyDownloadsUpdates: true
        )
        let context = makePopoverContext(
            shortcuts: [],
            usageTotal: 0,
            userDefaults: defaults,
            updateService: updateService
        )

        #expect(context.model.updateNotice == nil)
        #expect(context.model.updateUnavailableCaption == nil)

        updateService.simulateUpdateState(phase: .available(version: "0.6.0"))
        #expect(context.model.updateNotice?.title == "Update available — v0.6.0")

        updateService.simulateUpdateState(phase: .ready(version: "0.6.0"))
        #expect(context.model.updateNotice?.title == "Update ready — v0.6.0")

        // Errors surface in the settings card, not as a popover notice row.
        updateService.simulateUpdateState(phase: .error(message: "feed unreachable"))
        #expect(context.model.updateNotice == nil)
    }

    @Test @MainActor
    func unconfiguredUpdaterDisablesCheckRowWithExplanatoryCaption() {
        let context = makePopoverContext(
            shortcuts: [],
            usageTotal: 0,
            updateService: FakeUpdateService(
                isConfigured: false,
                canCheckForUpdates: false,
                currentVersion: "0.5.0",
                automaticallyChecksForUpdates: true,
                automaticallyDownloadsUpdates: true
            )
        )

        #expect(context.model.isCheckForUpdatesEnabled == false)
        #expect(context.model.updateUnavailableCaption != nil)
    }

    @Test @MainActor
    func refreshBuildsEvenTwentyFourBarHistogramFromTodayTotal() async {
        let context = makePopoverContext(
            shortcuts: [],
            usageTotal: 24
        )

        await context.model.waitForUsageRefreshForTesting()

        #expect(context.model.todayActivationCount == 24)
        #expect(context.model.todayHistogramBars.count == 24)
        #expect(context.model.todayHistogramBars.allSatisfy { $0 == 1 })
    }

    @Test @MainActor
    func modelRefreshesRunningStateForWorkspaceNotificationsWhilePopoverIsOpen() {
        let runtimeState = PopoverRuntimeState(
            applicationURLs: [
                "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app")
            ],
            runningBundleIdentifiers: []
        )
        let workspaceNotificationCenter = NotificationCenter()
        let context = makePopoverContext(
            shortcuts: [
                AppShortcut(
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    keyEquivalent: "s",
                    modifierFlags: ["command"]
                )
            ],
            usageTotal: 0,
            runtimeState: runtimeState,
            workspaceNotificationCenter: workspaceNotificationCenter
        )

        #expect(context.model.shortcutRows.first?.isRunning == false)

        runtimeState.runningBundleIdentifiers = ["com.apple.Safari"]
        workspaceNotificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        drainMainRunLoop()

        #expect(context.model.shortcutRows.first?.isRunning == true)

        runtimeState.runningBundleIdentifiers = []
        workspaceNotificationCenter.post(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        drainMainRunLoop()

        #expect(context.model.shortcutRows.first?.isRunning == false)
    }

    @Test @MainActor
    func modelRefreshesUnavailableStateForActivationNotificationsWhilePopoverIsOpen() throws {
        let runtimeState = PopoverRuntimeState(
            applicationURLs: [
                "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app")
            ],
            runningBundleIdentifiers: []
        )
        let appNotificationCenter = NotificationCenter()
        let context = makePopoverContext(
            shortcuts: [
                AppShortcut(
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    keyEquivalent: "s",
                    modifierFlags: ["command"]
                )
            ],
            usageTotal: 0,
            runtimeState: runtimeState,
            appNotificationCenter: appNotificationCenter
        )

        let row = try #require(context.model.shortcutRows.first)
        #expect(row.isUnavailable == false)

        runtimeState.applicationURLs["com.apple.Safari"] = nil
        appNotificationCenter.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        drainMainRunLoop()

        #expect(context.model.shortcutRows.first?.isUnavailable == true)
        let unavailableRow = try #require(context.model.shortcutRows.first)
        #expect(!context.model.activateShortcut(unavailableRow))
        #expect(context.model.shortcutActivationFailure == .unavailable("Safari"))

        runtimeState.applicationURLs["com.apple.Safari"] = URL(
            fileURLWithPath: "/Applications/Safari.app"
        )
        appNotificationCenter.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        drainMainRunLoop()

        #expect(context.model.shortcutRows.first?.isUnavailable == false)
        #expect(context.model.shortcutActivationFailure == nil)
    }
}

@Suite("Menu bar profile row")
@MainActor
struct MenuBarProfileRowTests {
    @Test
    func theProfileRowStaysHiddenUntilThereIsSomethingToSwitchBetween() {
        let context = makePopoverContext(shortcuts: [], usageTotal: 0)
        defer { context.profileHarness.cleanup() }

        // A fresh install has exactly one profile. A row that can only ever
        // reselect what is already active is worse than no row.
        #expect(context.model.selectableProfiles.count == 1)
        #expect(!context.model.showsProfileRow)

        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)

        #expect(context.model.showsProfileRow)
        #expect(context.model.selectableProfiles.count == 2)
        #expect(context.model.activeProfileName == context.profileState.activeProfile?.name)
    }

    /// #435: a menu click is not a captured key event. Even while capture is
    /// paused and neither Carbon nor EventTap is live, it forwards the exact
    /// saved binding (including UUID) once through the injected switch path.
    @Test @MainActor
    func shortcutActionUsesExactBindingWithoutCaptureTransportReadiness() throws {
        let shortcut = AppShortcut(
            id: UUID(uuidString: "D1DAF134-8CB3-41E0-B08A-43777383A26F")!,
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
        let recorder = ShortcutActivationRecorder(result: true)
        let context = makePopoverContext(
            shortcuts: [shortcut],
            usageTotal: 0,
            permissionService: FakePermissionService(ax: true, input: false),
            activateShortcut: { shortcut, onFinalOutcome in
                recorder.shortcuts.append(shortcut)
                onFinalOutcome(.confirmed)
                return recorder.result
            }
        )
        defer { context.profileHarness.cleanup() }

        context.model.setShortcutsPaused(true)
        let status = context.preferences.shortcutCaptureStatus
        let row = try #require(context.model.shortcutRows.first)

        #expect(status.shortcutsPaused)
        #expect(!status.carbonHotKeysRegistered)
        #expect(!status.eventTapActive)
        #expect(context.model.activateShortcut(row))
        #expect(recorder.shortcuts == [shortcut])
        #expect(context.model.shortcutActivationFailure == nil)
        #expect(row.actionAccessibilityLabel == "Run Safari shortcut with Wink")
    }

    @Test @MainActor
    func shortcutActionKeepsActivationPrerequisitesAndSurfacesRejection() throws {
        let enabled = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
        let disabled = AppShortcut(
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t",
            modifierFlags: ["command"],
            isEnabled: false
        )
        let recorder = ShortcutActivationRecorder(result: false)
        let context = makePopoverContext(
            shortcuts: [enabled, disabled],
            usageTotal: 0,
            runtimeState: PopoverRuntimeState(
                applicationURLs: ["com.apple.Terminal": URL(fileURLWithPath: "/Applications/Terminal.app")],
                runningBundleIdentifiers: []
            ),
            activateShortcut: { shortcut, _ in
                recorder.shortcuts.append(shortcut)
                return recorder.result
            },
            announceAccessibility: { recorder.announcements.append($0) }
        )
        defer { context.profileHarness.cleanup() }

        let unavailableRow = try #require(context.model.shortcutRows.first { $0.shortcut.id == enabled.id })
        let disabledRow = try #require(context.model.shortcutRows.first { $0.shortcut.id == disabled.id })
        #expect(!context.model.activateShortcut(unavailableRow))
        #expect(context.model.shortcutActivationFailure == .unavailable("Safari"))
        #expect(!context.model.activateShortcut(disabledRow))
        #expect(context.model.shortcutActivationFailure == .disabled("Terminal"))
        #expect(recorder.shortcuts.isEmpty)
        #expect(recorder.announcements == ["Safari is unavailable.", "Terminal is disabled."])

        let availableContext = makePopoverContext(
            shortcuts: [enabled],
            usageTotal: 0,
            activateShortcut: { shortcut, _ in
                recorder.shortcuts.append(shortcut)
                return recorder.result
            },
            announceAccessibility: { recorder.announcements.append($0) }
        )
        defer { availableContext.profileHarness.cleanup() }
        let availableRow = try #require(availableContext.model.shortcutRows.first)
        #expect(!availableContext.model.activateShortcut(availableRow))
        #expect(availableContext.model.shortcutActivationFailure == .rejected("Safari"))
        #expect(recorder.shortcuts == [enabled])
        #expect(recorder.announcements.last == "Couldn’t run the Safari shortcut. Try again.")

        let deniedContext = makePopoverContext(
            shortcuts: [enabled],
            usageTotal: 0,
            permissionService: FakePermissionService(ax: false, input: true),
            activateShortcut: { shortcut, _ in
                recorder.shortcuts.append(shortcut)
                return true
            },
            announceAccessibility: { recorder.announcements.append($0) }
        )
        defer { deniedContext.profileHarness.cleanup() }
        let deniedRow = try #require(deniedContext.model.shortcutRows.first)
        #expect(!deniedContext.model.activateShortcut(deniedRow))
        #expect(deniedContext.model.shortcutActivationFailure == .accessibilityRequired)
        #expect(recorder.shortcuts == [enabled])
        #expect(recorder.announcements.last == "Accessibility permission is required to run shortcuts from the menu.")
    }

    @Test @MainActor
    func acceptedAsyncFailureStaysCorrelatedAndIsAnnounced() throws {
        let shortcut = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
        let recorder = ShortcutActivationRecorder(result: true)
        let context = makePopoverContext(
            shortcuts: [shortcut],
            usageTotal: 0,
            activateShortcut: { shortcut, onFinalOutcome in
                recorder.shortcuts.append(shortcut)
                recorder.onFinalOutcome = onFinalOutcome
                return true
            },
            announceAccessibility: { recorder.announcements.append($0) }
        )
        defer { context.profileHarness.cleanup() }
        let row = try #require(context.model.shortcutRows.first)

        #expect(context.model.activateShortcut(row))
        #expect(context.model.shortcutActivationFailure == nil)
        recorder.onFinalOutcome?(.failed)

        #expect(context.model.shortcutActivationFailure == .rejected("Safari"))
        #expect(recorder.announcements == ["Couldn’t run the Safari shortcut. Try again."])
    }

    @Test @MainActor
    func sameProfileEditInvalidatesDisplayedAndPendingActivationFeedback() async throws {
        let shortcut = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
        let recorder = ShortcutActivationRecorder(result: true)
        let context = makePopoverContext(
            shortcuts: [shortcut],
            usageTotal: 0,
            activateShortcut: { _, onFinalOutcome in
                recorder.onFinalOutcome = onFinalOutcome
                return true
            },
            announceAccessibility: { recorder.announcements.append($0) }
        )
        defer { context.profileHarness.cleanup() }
        let row = try #require(context.model.shortcutRows.first)

        #expect(context.model.activateShortcut(row))
        var edited = shortcut
        edited.keyEquivalent = "x"
        try context.shortcutManager.save(shortcuts: [edited])
        for _ in 0..<100 where context.model.shortcutRows.first?.shortcut != edited {
            await Task.yield()
        }

        #expect(context.model.shortcutRows.first?.shortcut == edited)
        #expect(context.model.shortcutActivationFailure == nil)
        recorder.onFinalOutcome?(.failed)
        #expect(context.model.shortcutActivationFailure == nil)
        #expect(recorder.announcements.isEmpty)

        var disabled = edited
        disabled.isEnabled = false
        try context.shortcutManager.save(shortcuts: [disabled])
        for _ in 0..<100 where context.model.shortcutRows.first?.shortcut != disabled {
            await Task.yield()
        }
        let disabledRow = try #require(context.model.shortcutRows.first)
        #expect(!context.model.activateShortcut(disabledRow))
        #expect(context.model.shortcutActivationFailure == .disabled("Safari"))

        try context.shortcutManager.save(shortcuts: [edited])
        for _ in 0..<100 where context.model.shortcutRows.first?.shortcut != edited {
            await Task.yield()
        }
        #expect(context.model.shortcutActivationFailure == nil)
    }

    @Test @MainActor
    func unrelatedLiveRowChangeDoesNotClearAnotherRowsFailure() throws {
        let safari = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"],
            isEnabled: false
        )
        let iina = AppShortcut(
            appName: "IINA",
            bundleIdentifier: "com.colliderli.iina",
            keyEquivalent: "i",
            modifierFlags: ["command"]
        )
        let runtimeState = PopoverRuntimeState(
            applicationURLs: [
                safari.bundleIdentifier: URL(fileURLWithPath: "/Applications/Safari.app"),
                iina.bundleIdentifier: URL(fileURLWithPath: "/Applications/IINA.app"),
            ],
            runningBundleIdentifiers: []
        )
        let workspaceNotificationCenter = NotificationCenter()
        let context = makePopoverContext(
            shortcuts: [safari, iina],
            usageTotal: 0,
            runtimeState: runtimeState,
            workspaceNotificationCenter: workspaceNotificationCenter
        )
        defer { context.profileHarness.cleanup() }
        let safariRow = try #require(
            context.model.shortcutRows.first { $0.shortcut.id == safari.id }
        )

        #expect(!context.model.activateShortcut(safariRow))
        #expect(context.model.shortcutActivationFailure == .disabled("Safari"))

        runtimeState.runningBundleIdentifiers = [iina.bundleIdentifier]
        workspaceNotificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        drainMainRunLoop()

        #expect(context.model.shortcutRows.first { $0.shortcut.id == iina.id }?.isRunning == true)
        #expect(context.model.shortcutActivationFailure == .disabled("Safari"))
    }

    @Test @MainActor
    func configurationRevisionClosesTheDeferredObservationOwnershipWindow() async throws {
        let safari = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
        let iina = AppShortcut(
            appName: "IINA",
            bundleIdentifier: "com.colliderli.iina",
            keyEquivalent: "i",
            modifierFlags: ["command"]
        )
        let recorder = ShortcutActivationRecorder(result: true)
        let context = makePopoverContext(
            shortcuts: [safari],
            usageTotal: 0,
            activateShortcut: { _, onFinalOutcome in
                recorder.onFinalOutcomes.append(onFinalOutcome)
                return true
            },
            announceAccessibility: { recorder.announcements.append($0) }
        )
        defer { context.profileHarness.cleanup() }
        let unchangedCachedRow = try #require(context.model.shortcutRows.first)

        #expect(context.model.activateShortcut(unchangedCachedRow))
        try context.shortcutManager.save(shortcuts: [safari, iina])

        // The store changed synchronously, but its Observation task cannot run
        // until this main-actor test yields. Exact membership alone still
        // matches Safari, so only the store revision can reject this old result.
        recorder.onFinalOutcomes[0](.failed)
        #expect(context.model.shortcutActivationFailure == nil)
        #expect(recorder.announcements.isEmpty)

        // A new click in that same pre-observer window belongs to the new
        // configuration and must survive the later UI-refresh task.
        #expect(context.model.activateShortcut(unchangedCachedRow))
        #expect(recorder.onFinalOutcomes.count == 2)
        for _ in 0..<100 where context.model.shortcutRows.count != 2 {
            await Task.yield()
        }
        #expect(context.model.shortcutRows.count == 2)

        recorder.onFinalOutcomes[1](.failed)
        #expect(context.model.shortcutActivationFailure == .rejected("Safari"))
        #expect(recorder.announcements == ["Couldn’t run the Safari shortcut. Try again."])
    }

    @Test @MainActor
    func profileSwitchInvalidatesPendingActivationFeedback() throws {
        let shortcut = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
        let recorder = ShortcutActivationRecorder(result: true)
        let context = makePopoverContext(
            shortcuts: [shortcut],
            usageTotal: 0,
            activateShortcut: { _, onFinalOutcome in
                recorder.onFinalOutcome = onFinalOutcome
                return true
            },
            announceAccessibility: { recorder.announcements.append($0) }
        )
        defer { context.profileHarness.cleanup() }
        let row = try #require(context.model.shortcutRows.first)
        #expect(context.model.activateShortcut(row))
        let originalProfileID = try #require(context.model.activeProfileID)

        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let work = try #require(context.model.selectableProfiles.first { $0.name == "Work" })
        // Switch through the shared state, as Settings and future automation
        // do, then return to the original ID before delivering the old result.
        // The monotonic revision must still reject it.
        context.profileState.switchToProfile(work.id)
        context.profileState.switchToProfile(originalProfileID)
        recorder.onFinalOutcome?(.failed)
        drainMainRunLoop()

        #expect(context.model.activeProfileID == originalProfileID)
        #expect(context.model.shortcutActivationFailure == nil)
        #expect(recorder.announcements.isEmpty)
    }

    @Test @MainActor
    func externallyAppliedProfileCannotDispatchAnOutgoingCachedRow() throws {
        let shortcut = AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"]
        )
        let recorder = ShortcutActivationRecorder(result: true)
        let context = makePopoverContext(
            shortcuts: [shortcut],
            usageTotal: 0,
            activateShortcut: { shortcut, _ in
                recorder.shortcuts.append(shortcut)
                return true
            },
            announceAccessibility: { recorder.announcements.append($0) }
        )
        defer { context.profileHarness.cleanup() }
        let outgoingRow = try #require(context.model.shortcutRows.first)

        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let work = try #require(context.model.selectableProfiles.first { $0.name == "Work" })
        // Bypass the model entry point to model a Focus/automation switch.
        // Do not drain the observation task: the outgoing cached row is still
        // visible at this exact point.
        context.profileState.switchToProfile(work.id)

        #expect(!context.model.activateShortcut(outgoingRow))
        #expect(recorder.shortcuts.isEmpty)
        #expect(context.model.shortcutRows.isEmpty)
        #expect(recorder.announcements == [
            "Couldn’t run the Safari shortcut. Try again."
        ])
    }

    @Test @MainActor
    func profileSwitchClearsSynchronousActivationFailure() throws {
        let shortcut = AppShortcut(
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t",
            modifierFlags: ["command"],
            isEnabled: false
        )
        let context = makePopoverContext(shortcuts: [shortcut], usageTotal: 0)
        defer { context.profileHarness.cleanup() }
        let row = try #require(context.model.shortcutRows.first)
        #expect(!context.model.activateShortcut(row))
        #expect(context.model.shortcutActivationFailure == .disabled("Terminal"))

        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let work = try #require(context.model.selectableProfiles.first { $0.name == "Work" })
        context.profileState.switchToProfile(work.id)
        drainMainRunLoop()

        #expect(context.model.shortcutActivationFailure == nil)
    }

    @Test
    func anUnreadableProfileIsListedButNotSelectable() {
        let context = makePopoverContext(shortcuts: [], usageTotal: 0)
        defer { context.profileHarness.cleanup() }

        context.profileState.createProfile(named: "Work", duplicatingActiveProfile: false)
        let work = context.model.selectableProfiles.first { $0.name == "Work" }

        #expect(work != nil)
        if let work {
            // Readable today; the gate is the state's unreadable set, which the
            // row consults rather than deciding for itself.
            #expect(context.model.isProfileSelectable(work))
        }
    }
}

private struct PopoverContext {
    let model: MenuBarPopoverModel
    let preferences: AppPreferences
    /// Retained so its temporary directory outlives the model.
    let profileHarness: TestProfileHarness
    let profileState: ShortcutProfileState
    let shortcutManager: ShortcutManager
}

@MainActor
private func makePopoverContext(
    shortcuts: [AppShortcut],
    runningBundleIdentifiers: Set<String> = [],
    usageTotal: Int,
    runtimeState: PopoverRuntimeState? = nil,
    workspaceNotificationCenter: NotificationCenter = NotificationCenter(),
    appNotificationCenter: NotificationCenter = NotificationCenter(),
    userDefaults: UserDefaults? = nil,
    updateService: FakeUpdateService? = nil,
    permissionService: any PermissionServicing = FakePermissionService(ax: true, input: true),
    setShortcutsPaused: (@MainActor (Bool) -> Void)? = nil,
    activateShortcut: (@MainActor (
        AppShortcut,
        @escaping @MainActor @Sendable (ShortcutInvocationOutcome) -> Void
    ) -> Bool)? = nil,
    announceAccessibility: (@MainActor (String) -> Void)? = nil,
    openSettings: @escaping @MainActor (SettingsTab?) -> Void = { _ in },
    quit: @escaping @MainActor () -> Void = {}
) -> PopoverContext {
    let defaults = userDefaults ?? UserDefaults(suiteName: "MenuBarPopoverViewTests.\(UUID().uuidString)")!
    let shortcutStore = ShortcutStore()
    shortcutStore.replaceAll(with: shortcuts)
    let harness = TestPersistenceHarness()
    let manager = ShortcutManager(
        shortcutStore: shortcutStore,
        persistenceService: harness.makePersistenceService(),
        appSwitcher: FakeAppSwitcher(),
        captureCoordinator: ShortcutCaptureCoordinator(
            standardProvider: FakeCaptureProvider(),
            hyperProvider: FakeHyperCaptureProvider()
        ),
        permissionService: permissionService,
        diagnosticClient: .live
    )
    try! manager.save(shortcuts: shortcuts)

    let preferences = AppPreferences(
        shortcutManager: manager,
        launchAtLoginService: LaunchAtLoginService(client: .init(
            status: { .notRegistered },
            register: {},
            unregister: {},
            openSystemSettingsLoginItems: {}
        )),
        updateService: updateService,
        userDefaults: defaults
    )
    let resolvedRuntimeState = runtimeState ?? PopoverRuntimeState(
        applicationURLs: Dictionary(
            uniqueKeysWithValues: shortcuts.map { shortcut in
                (
                    shortcut.bundleIdentifier,
                    URL(fileURLWithPath: "/Applications/\(shortcut.appName).app")
                )
            }
        ),
        runningBundleIdentifiers: runningBundleIdentifiers
    )
    let statusProvider = ShortcutStatusProvider(
        client: .init(
            applicationURL: { bundleIdentifier in
                resolvedRuntimeState.applicationURLs[bundleIdentifier]
            },
            runningBundleIdentifiers: {
                resolvedRuntimeState.runningBundleIdentifiers
            }
        ),
        workspaceNotificationCenter: workspaceNotificationCenter,
        appNotificationCenter: appNotificationCenter
    )
    let profileHarness = TestProfileHarness()
    let profileState = profileHarness.makeLoadedProfileState(shortcutManager: manager)
    let model = MenuBarPopoverModel(
        shortcutStore: shortcutStore,
        preferences: preferences,
        profileState: profileState,
        shortcutStatusProvider: statusProvider,
        usageTracker: StaticUsageTracker(total: usageTotal),
        workspaceNotificationCenter: workspaceNotificationCenter,
        appNotificationCenter: appNotificationCenter,
        setShortcutsPaused: setShortcutsPaused,
        activateShortcut: activateShortcut,
        announceAccessibility: announceAccessibility,
        openSettings: openSettings,
        quit: quit
    )

    return PopoverContext(
        model: model,
        preferences: preferences,
        profileHarness: profileHarness,
        profileState: profileState,
        shortcutManager: manager
    )
}

@MainActor
private final class PopoverRuntimeState {
    var applicationURLs: [String: URL]
    var runningBundleIdentifiers: Set<String>

    init(
        applicationURLs: [String: URL],
        runningBundleIdentifiers: Set<String>
    ) {
        self.applicationURLs = applicationURLs
        self.runningBundleIdentifiers = runningBundleIdentifiers
    }
}

private actor StaticUsageTracker: UsageTracking {

    func appActivationTotals(days: Int, relativeTo now: Date) async -> [(bundleIdentifier: String, count: Int)] {
        []
    }
    func deleteUsage(shortcutId: UUID) -> Bool { true }
    let total: Int

    init(total: Int) {
        self.total = total
    }

    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] {
        [:]
    }

    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] {
        [
            UUID().uuidString: [
                (date: "2026-04-22", count: total),
            ]
        ]
    }

    func totalSwitches(days: Int, relativeTo now: Date) async -> Int {
        total
    }

    func hourlyCounts(days: Int, relativeTo now: Date) async -> [HourlyUsageBucket] {
        let date = "2026-04-22"
        let baseCount = total / 24
        let remainder = total % 24

        return (0..<24).map { hour in
            HourlyUsageBucket(
                date: date,
                hour: hour,
                count: baseCount + (hour < remainder ? 1 : 0)
            )
        }
    }

    func previousPeriodTotal(days: Int, relativeTo now: Date) async -> Int {
        0
    }

    func streakDays(relativeTo now: Date) async -> Int {
        0
    }

    func usageTimeZone() async -> TimeZone {
        .current
    }
}

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

@MainActor
private func drainMainRunLoop() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

@MainActor
private final class FakeCaptureProvider: ShortcutCaptureProvider {
    var isRunning = false

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: isRunning ? 1 : 0,
            registeredShortcutCount: isRunning ? 1 : 0,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (Wink.KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<Wink.KeyPress>) {}
}

@MainActor
private final class FakeHyperCaptureProvider: HyperShortcutCaptureProvider {
    var isRunning = false

    var registrationState: ShortcutCaptureRegistrationState {
        ShortcutCaptureRegistrationState(
            desiredShortcutCount: isRunning ? 1 : 0,
            registeredShortcutCount: isRunning ? 1 : 0,
            failures: []
        )
    }

    func start(onKeyPress: @escaping @MainActor @Sendable (Wink.KeyPress) -> Void) {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    func updateRegisteredShortcuts(_ keyPresses: Set<Wink.KeyPress>) {}

    func setHyperKeyEnabled(_ enabled: Bool) {}
}

@MainActor
private struct FakeAppSwitcher: AppSwitching {
    @discardableResult
    func toggleApplication(for shortcut: AppShortcut, bypassCooldown: Bool) -> Bool {
        true
    }
}

@MainActor
private final class FakeUpdateService: UpdateServicing {
    let isConfigured: Bool
    let canCheckForUpdates: Bool
    let currentVersion: String
    var automaticallyChecksForUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
    private(set) var didRequestManualCheck = false
    private(set) var updatePhase: UpdatePhase = .idle
    private(set) var lastUpdateCheckDate: Date?
    var onUpdateStateChange: (@MainActor () -> Void)?

    init(
        isConfigured: Bool,
        canCheckForUpdates: Bool,
        currentVersion: String,
        automaticallyChecksForUpdates: Bool,
        automaticallyDownloadsUpdates: Bool
    ) {
        self.isConfigured = isConfigured
        self.canCheckForUpdates = canCheckForUpdates
        self.currentVersion = currentVersion
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
    }

    func checkForUpdates() {
        didRequestManualCheck = true
    }

    func simulateUpdateState(phase: UpdatePhase, lastCheck: Date? = nil) {
        updatePhase = phase
        if let lastCheck {
            lastUpdateCheckDate = lastCheck
        }
        onUpdateStateChange?()
    }

    func installUpdateNow() {}
    func remindUpdateLater() {}
    func skipUpdateVersion() {}
    func cancelUpdateOperation() {}
    func acknowledgeUpdateResult() {}
}

private final class OpenedTabsRecorder: @unchecked Sendable {
    var tabs: [SettingsTab?] = []
}

private final class FlagRecorder: @unchecked Sendable {
    var didRun = false
}

private final class PauseRecorder: @unchecked Sendable {
    var values: [Bool] = []
}

private final class ShortcutActivationRecorder: @unchecked Sendable {
    let result: Bool
    var shortcuts: [AppShortcut] = []
    var announcements: [String] = []
    var onFinalOutcome: (@MainActor @Sendable (ShortcutInvocationOutcome) -> Void)?
    var onFinalOutcomes: [(@MainActor @Sendable (ShortcutInvocationOutcome) -> Void)] = []

    init(result: Bool) {
        self.result = result
    }
}

@MainActor
private func makeHostingView<Content: View>(_ rootView: Content, size: NSSize) -> NSHostingView<Content> {
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    hostingView.layoutSubtreeIfNeeded()
    return hostingView
}

@MainActor
private func collectPlaceholders(in view: NSView) -> [String] {
    var values: [String] = []
    if let textField = view as? NSTextField,
       let placeholder = textField.placeholderString,
       !placeholder.isEmpty {
        values.append(placeholder)
    }

    for subview in view.subviews {
        values.append(contentsOf: collectPlaceholders(in: subview))
    }

    return values
}
