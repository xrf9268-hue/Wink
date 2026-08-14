import Foundation
import WinkIntents

enum WinkActionExecutionError: LocalizedError, Equatable {
    case pauseStateDidNotChange(expectedPaused: Bool)
    case searchPaletteUnavailable
    case settingsUnavailable
    case settingsDidNotAppear

    var errorDescription: String? {
        switch self {
        case .pauseStateDidNotChange(let expectedPaused):
            return expectedPaused
                ? String(localized: "Wink could not pause shortcuts.", bundle: WinkResourceBundle.bundle)
                : String(localized: "Wink could not resume shortcuts.", bundle: WinkResourceBundle.bundle)
        case .searchPaletteUnavailable:
            return String(localized: "Wink could not show the Search Palette.", bundle: WinkResourceBundle.bundle)
        case .settingsUnavailable:
            return String(
                localized: "Wink Settings is not ready yet. Please try again.",
                bundle: WinkResourceBundle.bundle
            )
        case .settingsDidNotAppear:
            return String(localized: "Wink Settings did not become visible.", bundle: WinkResourceBundle.bundle)
        }
    }
}

@MainActor
struct WinkActionExecutor {
    enum SettingsPresentationPolicy: Equatable, Sendable {
        /// App Intents and menu actions must fail if the SwiftUI bridge is not
        /// installed yet; they must never report a queued request as success.
        case requireReady
        /// A custom URL has no completion result. On cold launch it may use
        /// SettingsLauncher's existing pending-open commit so the delivered
        /// request executes as soon as SwiftUI installs its bridge.
        case allowDeferred
    }

    struct Client {
        let isShortcutsPaused: @MainActor () -> Bool
        let setShortcutsPaused: @MainActor (Bool) -> Void
        let isSearchPalettePresented: @MainActor () -> Bool
        let canPresentSearchPalette: @MainActor () -> Bool
        let showSearchPalette: @MainActor () -> Void
        let openSettings: @MainActor (SettingsTab?) -> Void
        let openSettingsIfReady: @MainActor (SettingsTab?) -> Bool
        let waitForSettingsPresentation: @MainActor () async throws -> Bool
    }

    let client: Client

    func execute(
        _ action: WinkAction,
        settingsPresentationPolicy: SettingsPresentationPolicy = .requireReady
    ) throws {
        switch action {
        case .pause:
            try setPaused(true)
        case .resume:
            try setPaused(false)
        case .showSearchPalette:
            if !client.isSearchPalettePresented() {
                guard client.canPresentSearchPalette() else {
                    throw WinkActionExecutionError.searchPaletteUnavailable
                }
                client.showSearchPalette()
            }
            guard client.isSearchPalettePresented() else {
                throw WinkActionExecutionError.searchPaletteUnavailable
            }
        case .openSettings(let tab):
            let settingsTab = tab.map(SettingsTab.init)
            switch settingsPresentationPolicy {
            case .requireReady:
                guard client.openSettingsIfReady(settingsTab) else {
                    throw WinkActionExecutionError.settingsUnavailable
                }
            case .allowDeferred:
                client.openSettings(settingsTab)
            }
        }
    }

    func appIntentClient() -> WinkActionClient {
        WinkActionClient { action in
            try execute(action)
            guard case .openSettings = action else {
                return
            }
            guard try await client.waitForSettingsPresentation() else {
                throw WinkActionExecutionError.settingsDidNotAppear
            }
        }
    }

    private func setPaused(_ paused: Bool) throws {
        if client.isShortcutsPaused() != paused {
            client.setShortcutsPaused(paused)
        }
        guard client.isShortcutsPaused() == paused else {
            throw WinkActionExecutionError.pauseStateDidNotChange(expectedPaused: paused)
        }
    }
}

private extension SettingsTab {
    init(_ intentValue: WinkSettingsTabIntentValue) {
        switch intentValue {
        case .shortcuts: self = .shortcuts
        case .general: self = .general
        case .insights: self = .insights
        }
    }
}
