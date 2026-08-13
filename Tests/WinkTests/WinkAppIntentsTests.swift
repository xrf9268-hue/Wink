import Testing
import WinkIntents

@Suite("Wink App Intents", .serialized)
struct WinkAppIntentsTests {
    @Test
    func foregroundLaunchCompatibilityIsEnabled() {
        #expect(PauseWinkIntent.openAppWhenRun)
        #expect(ResumeWinkIntent.openAppWhenRun)
        #expect(ShowWinkSearchPaletteIntent.openAppWhenRun)
        #expect(OpenWinkSettingsIntent.openAppWhenRun)
    }

    @Test
    func unknownSettingsTabRawValueFailsClosed() {
        #expect(WinkSettingsTabIntentValue(rawValue: "advanced") == nil)
    }

    @Test @MainActor
    func intentsDispatchTheirDeterministicActions() async throws {
        let recorder = IntentActionRecorder()
        let client = WinkActionClient { action in
            recorder.record(action)
        }

        _ = try await PauseWinkIntent(client: client).perform()
        _ = try await ResumeWinkIntent(client: client).perform()
        _ = try await ShowWinkSearchPaletteIntent(client: client).perform()
        _ = try await OpenWinkSettingsIntent(tab: .general, client: client).perform()

        #expect(recorder.actions == [
            .pause,
            .resume,
            .showSearchPalette,
            .openSettings(.general),
        ])
    }

    @Test @MainActor
    func executionFailurePropagatesInsteadOfReturningSuccess() async {
        let client = WinkActionClient { _ in
            throw IntentFixtureError.expected
        }

        await #expect(throws: IntentFixtureError.expected) {
            _ = try await PauseWinkIntent(client: client).perform()
        }
    }
}

@MainActor
private final class IntentActionRecorder {
    private(set) var actions: [WinkAction] = []

    func record(_ action: WinkAction) {
        actions.append(action)
    }
}

private enum IntentFixtureError: Error, Equatable {
    case expected
}
