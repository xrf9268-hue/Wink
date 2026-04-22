import Foundation
import Observation

enum SettingsTab: String, CaseIterable, Sendable {
    case shortcuts
    case insights
    case general

    var title: String {
        switch self {
        case .shortcuts: return "Shortcuts"
        case .insights: return "Insights"
        case .general: return "General"
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
}
