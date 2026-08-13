import Foundation
import Testing
@testable import Wink
import WinkIntents

@Suite("Shared Wink action executor")
struct WinkActionExecutorTests {
    @Test @MainActor
    func pauseAndResumeAreIdempotentAndVerifyTheObservedState() throws {
        var paused = false
        var writes: [Bool] = []
        let executor = makeExecutor(
            paused: { paused },
            setPaused: {
                writes.append($0)
                paused = $0
            }
        )

        try executor.execute(.pause)
        try executor.execute(.pause)
        try executor.execute(.resume)
        try executor.execute(.resume)

        #expect(writes == [true, false])
        #expect(!paused)
    }

    @Test @MainActor
    func pauseFailureDoesNotReturnSuccess() {
        let executor = makeExecutor(paused: { false }, setPaused: { _ in })

        #expect(throws: WinkActionExecutionError.pauseStateDidNotChange(expectedPaused: true)) {
            try executor.execute(.pause)
        }
    }

    @Test @MainActor
    func searchPalettePresentsExactlyOnceAndVerifiesTheResult() throws {
        var presented = false
        var presentCount = 0
        let executor = makeExecutor(
            isSearchPresented: { presented },
            showSearch: {
                presentCount += 1
                presented = true
            }
        )

        try executor.execute(.showSearchPalette)
        try executor.execute(.showSearchPalette)

        #expect(presentCount == 1)
    }

    @Test @MainActor
    func unavailableSearchPaletteThrows() {
        let executor = makeExecutor(
            isSearchPresented: { false },
            showSearch: {}
        )

        #expect(throws: WinkActionExecutionError.searchPaletteUnavailable) {
            try executor.execute(.showSearchPalette)
        }
    }

    @Test @MainActor
    func searchPaletteDoesNotPresentWhileAnotherInteractivePanelIsActive() {
        var presentCount = 0
        let executor = makeExecutor(
            canPresentSearch: { false },
            isSearchPresented: { false },
            showSearch: { presentCount += 1 }
        )

        #expect(throws: WinkActionExecutionError.searchPaletteUnavailable) {
            try executor.execute(.showSearchPalette)
        }
        #expect(presentCount == 0)
    }

    @Test @MainActor
    func settingsMustOpenImmediatelyAndPreservesTypedTab() async throws {
        var requestedTabs: [SettingsTab?] = []
        let executor = makeExecutor(openSettings: { tab in
            requestedTabs.append(tab)
            return true
        })

        try await executor.appIntentClient().execute(.openSettings(.insights))

        #expect(requestedTabs == [.insights])
    }

    @Test @MainActor
    func settingsUnavailableThrowsInsteadOfQueuingSuccess() {
        let executor = makeExecutor(openSettings: { _ in false })

        #expect(throws: WinkActionExecutionError.settingsUnavailable) {
            try executor.execute(.openSettings(.general))
        }
    }

    @Test @MainActor
    func settingsIntentFailsWhenTheWindowNeverBecomesVisible() async {
        let executor = makeExecutor(
            openSettings: { _ in true },
            waitForSettings: { false }
        )

        await #expect(throws: WinkActionExecutionError.settingsDidNotAppear) {
            try await executor.appIntentClient().execute(.openSettings(.shortcuts))
        }
    }

    @MainActor
    private func makeExecutor(
        paused: @escaping @MainActor () -> Bool = { false },
        setPaused: @escaping @MainActor (Bool) -> Void = { _ in },
        canPresentSearch: @escaping @MainActor () -> Bool = { true },
        isSearchPresented: @escaping @MainActor () -> Bool = { true },
        showSearch: @escaping @MainActor () -> Void = {},
        openSettings: @escaping @MainActor (SettingsTab?) -> Bool = { _ in true },
        waitForSettings: @escaping @MainActor () async throws -> Bool = { true }
    ) -> WinkActionExecutor {
        WinkActionExecutor(client: .init(
            isShortcutsPaused: paused,
            setShortcutsPaused: setPaused,
            isSearchPalettePresented: isSearchPresented,
            canPresentSearchPalette: canPresentSearch,
            showSearchPalette: showSearch,
            openSettingsIfReady: openSettings,
            waitForSettingsPresentation: waitForSettings
        ))
    }
}
