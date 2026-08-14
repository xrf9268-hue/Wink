import Foundation
import Testing
@testable import Wink

@Suite("Shortcuts tab")
struct ShortcutsTabViewTests {
    @Test
    func firstShortcutGuideRequiresAResolvedWritableProfile() {
        #expect(
            FirstShortcutOnboardingLaunchEligibility.canStart(
                isPresented: false,
                canPrepareProfile: true
            )
        )
        #expect(
            !FirstShortcutOnboardingLaunchEligibility.canStart(
                isPresented: false,
                canPrepareProfile: false
            )
        )
        #expect(
            !FirstShortcutOnboardingLaunchEligibility.canStart(
                isPresented: true,
                canPrepareProfile: true
            )
        )
    }

    @Test
    func manualPauseOffersARealResumeAction() throws {
        let presentation = try #require(
            FirstShortcutOnboardingPausePresentation(
                effectivePaused: true,
                manuallyPaused: true,
                autoPauseTriggerAppName: nil
            )
        )

        #expect(presentation == .manual)
        #expect(presentation.showsResumeAction)
        #expect(presentation.title == "Resume shortcuts to continue")
    }

    @Test
    func exceptionPauseDoesNotOfferADeadManualResumeAction() throws {
        let presentation = try #require(
            FirstShortcutOnboardingPausePresentation(
                effectivePaused: true,
                manuallyPaused: true,
                autoPauseTriggerAppName: "Parallels Desktop"
            )
        )

        #expect(presentation == .exception(appName: "Parallels Desktop"))
        #expect(!presentation.showsResumeAction)
        #expect(presentation.title == "Shortcuts paused by Parallels Desktop")
        #expect(
            presentation.message
                == "Switch away from Parallels Desktop to resume shortcut capture, or remove it from the exception list."
        )
    }

    @Test
    func unnamedEffectivePauseStillUsesExceptionGuidance() throws {
        let presentation = try #require(
            FirstShortcutOnboardingPausePresentation(
                effectivePaused: true,
                manuallyPaused: false,
                autoPauseTriggerAppName: nil
            )
        )

        #expect(presentation == .exception(appName: nil))
        #expect(!presentation.showsResumeAction)
        #expect(presentation.title == "Shortcuts paused by an exception rule")
    }

    @Test
    func focusPauseDoesNotOfferADeadManualResumeAction() throws {
        let presentation = try #require(
            FirstShortcutOnboardingPausePresentation(
                effectivePaused: true,
                manuallyPaused: false,
                autoPauseTriggerAppName: nil,
                focusPauseActive: true
            )
        )

        #expect(presentation == .focus)
        #expect(!presentation.showsResumeAction)
        #expect(presentation.title == "Shortcuts paused by Focus")
    }

    @Test
    func focusPauseGuidanceNamesTheRemainingPauseReason() throws {
        let presentation = try #require(
            FirstShortcutOnboardingPausePresentation(
                effectivePaused: true,
                manuallyPaused: true,
                autoPauseTriggerAppName: "Parallels Desktop",
                focusPauseActive: true
            )
        )

        #expect(presentation == .focusWithOtherReason)
        #expect(!presentation.showsResumeAction)
        #expect(presentation.title == "Shortcuts paused by Focus and another reason")
        #expect(
            presentation.message
                == "Change or deactivate the Focus Filter, then clear the remaining pause reason before shortcut capture can resume."
        )
    }

    @Test
    func profilePickerAndAccessibilityUseTheSameRestoreSelectionDuringFocus() {
        let activeID = UUID()
        let restoreID = UUID()
        let focusID = UUID()
        let profiles = [
            ShortcutProfile(id: activeID, name: "Active", createdAt: .distantPast),
            ShortcutProfile(id: restoreID, name: "Restore", createdAt: .distantPast),
        ]

        let selectedID = ProfileBarSelection.profileID(
            activeProfileID: activeID,
            focusProfileID: focusID,
            manualProfileIDDuringFocus: restoreID,
            focusRestorePending: false
        )

        #expect(selectedID == restoreID)
        #expect(
            ProfileBarSelection.profileName(
                profiles: profiles,
                selectedProfileID: selectedID
            ) == "Restore"
        )
    }

    @Test
    func profilePickerSelectsPendingRestoreTargetAfterFocusEnds() {
        let formerFocusID = UUID()
        let restoreID = UUID()

        #expect(
            ProfileBarSelection.profileID(
                activeProfileID: formerFocusID,
                focusProfileID: nil,
                manualProfileIDDuringFocus: restoreID,
                focusRestorePending: true
            ) == restoreID
        )
    }

    @Test
    func inputMonitoringWarningDoesNotAssumeHyperRouting() {
        let status = ShortcutCaptureStatus(
            accessibilityGranted: true,
            inputMonitoringGranted: false,
            inputMonitoringRequired: true,
            carbonHotKeysRegistered: false,
            eventTapActive: false,
            standardShortcutsReady: false,
            hyperShortcutsReady: true
        )

        #expect(
            ShortcutBannerPresentation(status: status)
                == .warning(
                    title: "Input Monitoring needed",
                    message: "Some shortcuts need Input Monitoring before Wink can capture them.",
                    showsAction: true
                )
        )
    }

    @Test
    func inactiveHyperEventTapDoesNotPresentCaptureAsReady() {
        let status = ShortcutCaptureStatus(
            accessibilityGranted: true,
            inputMonitoringGranted: true,
            inputMonitoringRequired: true,
            carbonHotKeysRegistered: false,
            eventTapActive: false,
            standardShortcutsReady: true,
            hyperShortcutsReady: false
        )

        #expect(
            ShortcutBannerPresentation(status: status)
                == .warning(
                    title: "Shortcut capture needs attention",
                    message: "Hyper shortcuts are configured, but shortcut capture is not active.",
                    showsAction: false
                )
        )
    }

    @Test
    func pausedCaptureMapsToInfoBanner() {
        let status = ShortcutCaptureStatus(
            accessibilityGranted: true,
            inputMonitoringGranted: true,
            carbonHotKeysRegistered: false,
            eventTapActive: false,
            standardShortcutsReady: false,
            hyperShortcutsReady: false,
            shortcutsPaused: true
        )

        #expect(
            ShortcutBannerPresentation(status: status)
                == .info(title: "Shortcuts paused", message: "All shortcuts are paused.")
        )
    }

    @Test
    func pausedCaptureSuppressesMissingInputMonitoringAction() {
        let status = ShortcutCaptureStatus(
            accessibilityGranted: true,
            inputMonitoringGranted: false,
            inputMonitoringRequired: true,
            carbonHotKeysRegistered: false,
            eventTapActive: false,
            standardShortcutsReady: false,
            hyperShortcutsReady: false,
            shortcutsPaused: true
        )

        #expect(
            ShortcutBannerPresentation(status: status)
                == .info(
                    title: "Shortcuts paused",
                    message: "All shortcuts are paused."
                )
        )
    }
}
