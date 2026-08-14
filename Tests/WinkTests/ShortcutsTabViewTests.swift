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
