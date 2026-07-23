import Testing
@testable import Wink

/// #383: `hyperCheatSheetSubtitleText` is the pure decision logic behind
/// `GeneralTabView.hyperCheatSheetSubtitle`, covering the cold-start-then-
/// tap-starts sequence — the "Needs at least one enabled Hyper shortcut"
/// copy must track live `eventTapActive`, not a value frozen at launch.
@Suite("General tab — Hyper cheat sheet subtitle")
struct GeneralTabViewTests {
    @Test @MainActor
    func inactiveEventTapWithHyperEnabledShowsNeedsShortcutCopy() {
        let subtitle = GeneralTabView.hyperCheatSheetSubtitleText(
            hyperCheatSheetEnabled: true,
            hyperKeyEnabled: true,
            eventTapActive: false
        )

        #expect(subtitle == "Hold Caps Lock without a second key to see all shortcuts. Needs at least one enabled Hyper shortcut.")
    }

    @Test @MainActor
    func activeEventTapAfterColdStartDoesNotShowNeedsShortcutCopy() {
        // Same feature/Hyper-enabled inputs as the case above; only
        // `eventTapActive` differs, as it would once the tap has actually
        // started after a cold launch.
        let subtitle = GeneralTabView.hyperCheatSheetSubtitleText(
            hyperCheatSheetEnabled: true,
            hyperKeyEnabled: true,
            eventTapActive: true
        )

        #expect(subtitle != "Hold Caps Lock without a second key to see all shortcuts. Needs at least one enabled Hyper shortcut.")
        #expect(subtitle == "Hold Caps Lock without a second key to see all shortcuts.")
    }

    @Test @MainActor
    func hyperKeyDisabledShowsNeedsHyperKeyCopyRegardlessOfEventTap() {
        #expect(
            GeneralTabView.hyperCheatSheetSubtitleText(
                hyperCheatSheetEnabled: true,
                hyperKeyEnabled: false,
                eventTapActive: false
            ) == "Hold Caps Lock without a second key to see all shortcuts. Needs Hyper Key enabled."
        )
    }

    @Test @MainActor
    func featureDisabledShowsPlainCopyRegardlessOfOtherState() {
        #expect(
            GeneralTabView.hyperCheatSheetSubtitleText(
                hyperCheatSheetEnabled: false,
                hyperKeyEnabled: true,
                eventTapActive: true
            ) == "Hold Caps Lock without a second key to see all shortcuts."
        )
    }
}
