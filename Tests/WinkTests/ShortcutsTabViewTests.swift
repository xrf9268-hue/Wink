import Testing
@testable import Wink

@Suite("Shortcuts tab")
struct ShortcutsTabViewTests {
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
