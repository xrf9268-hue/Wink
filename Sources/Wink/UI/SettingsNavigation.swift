import Foundation
import Observation

enum SettingsTab: String, CaseIterable, Sendable {
    case shortcuts
    case insights
    case general

    var title: String {
        switch self {
        case .shortcuts: return String(localized: "Shortcuts", bundle: WinkResourceBundle.bundle)
        case .insights: return String(localized: "Insights", bundle: WinkResourceBundle.bundle)
        case .general: return String(localized: "General", bundle: WinkResourceBundle.bundle)
        }
    }

    var systemImage: String {
        switch self {
        case .shortcuts: return "keyboard"
        case .insights: return "chart.bar"
        case .general: return "gearshape"
        }
    }
}

@MainActor
@Observable
final class SettingsLauncher {
    static let selectedTabDefaultsKey = "selectedSettingsTab"

    var selectedTab: SettingsTab {
        didSet {
            userDefaults.set(selectedTab.rawValue, forKey: Self.selectedTabDefaultsKey)
        }
    }

    @ObservationIgnored
    private let userDefaults: UserDefaults

    @ObservationIgnored
    private var openSettingsHandler: (@MainActor () -> Void)?

    @ObservationIgnored
    private var settingsPresentationObserver: (@MainActor () -> Bool)?

    @ObservationIgnored
    private var pendingOpen = false

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let rawValue = userDefaults.string(forKey: Self.selectedTabDefaultsKey),
           let storedTab = SettingsTab(rawValue: rawValue) {
            selectedTab = storedTab
        } else {
            selectedTab = .shortcuts
        }
    }

    func installOpenSettingsHandler(_ handler: @escaping @MainActor () -> Void) {
        openSettingsHandler = handler
        guard pendingOpen else {
            return
        }
        pendingOpen = false
        handler()
    }

    func installSettingsPresentationObserver(_ observer: @escaping @MainActor () -> Bool) {
        settingsPresentationObserver = observer
    }

    func open(tab: SettingsTab? = nil) {
        if let tab {
            selectedTab = tab
        }

        guard let openSettingsHandler else {
            pendingOpen = true
            return
        }

        openSettingsHandler()
    }

    /// Opens immediately or reports that SwiftUI has not installed its
    /// environment bridge yet. Automation callers use this path so they can
    /// return a truthful error instead of claiming success for queued work.
    @discardableResult
    func openIfReady(tab: SettingsTab? = nil) -> Bool {
        guard let openSettingsHandler else {
            return false
        }
        if let tab {
            selectedTab = tab
        }
        openSettingsHandler()
        return true
    }

    func waitForSettingsPresentation(
        timeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(50)
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while settingsPresentationObserver?() != true {
            guard clock.now < deadline else {
                return false
            }
            try await clock.sleep(for: pollInterval)
        }
        return true
    }
}
