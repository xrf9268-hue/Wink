import AppIntents
import Foundation

public enum WinkSettingsTabIntentValue: String, AppEnum, Sendable {
    case shortcuts
    case general
    case insights

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Settings Tab"
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shortcuts: "Shortcuts",
        .general: "General",
        .insights: "Insights",
    ]
}

public enum WinkAction: Sendable, Equatable {
    case pause
    case resume
    case showSearchPalette
    case openSettings(WinkSettingsTabIntentValue?)
}

public struct WinkActionClient: Sendable {
    public let execute: @MainActor @Sendable (WinkAction) async throws -> Void

    public init(execute: @escaping @MainActor @Sendable (WinkAction) async throws -> Void) {
        self.execute = execute
    }
}

public enum WinkAppIntentDependency {
    public static func register(_ client: WinkActionClient) {
        AppDependencyManager.shared.add(dependency: client)
    }
}

public struct PauseWinkIntent: AppIntent {
    public static let title: LocalizedStringResource = "Pause Wink"
    public static let description = IntentDescription("Pause all Wink shortcuts.")
    public static let openAppWhenRun = true

    #if compiler(>=6.2)
        @available(macOS 26.0, *)
        public static var supportedModes: IntentModes { [.foreground(.dynamic)] }
    #endif

    @Dependency private var actions: WinkActionClient

    public init() {}

    public init(client: WinkActionClient) {
        self.init()
        actions = client
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await actions.execute(.pause)
        return .result(dialog: "Wink shortcuts are paused.")
    }
}

public struct ResumeWinkIntent: AppIntent {
    public static let title: LocalizedStringResource = "Resume Wink"
    public static let description = IntentDescription("Clear Wink's manual shortcut pause.")
    public static let openAppWhenRun = true

    #if compiler(>=6.2)
        @available(macOS 26.0, *)
        public static var supportedModes: IntentModes { [.foreground(.dynamic)] }
    #endif

    @Dependency private var actions: WinkActionClient

    public init() {}

    public init(client: WinkActionClient) {
        self.init()
        actions = client
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await actions.execute(.resume)
        return .result(dialog: "Wink manual pause is cleared.")
    }
}

public struct ShowWinkSearchPaletteIntent: AppIntent {
    public static let title: LocalizedStringResource = "Show Wink Search Palette"
    public static let description = IntentDescription("Show Wink's app search palette.")
    public static let openAppWhenRun = true

    #if compiler(>=6.2)
        @available(macOS 26.0, *)
        public static var supportedModes: IntentModes { [.foreground(.dynamic)] }
    #endif

    @Dependency private var actions: WinkActionClient

    public init() {}

    public init(client: WinkActionClient) {
        self.init()
        actions = client
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await actions.execute(.showSearchPalette)
        return .result(dialog: "Wink Search Palette is open.")
    }
}

public struct OpenWinkSettingsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Wink Settings"
    public static let description = IntentDescription("Open Wink Settings to an optional tab.")
    public static let openAppWhenRun = true

    #if compiler(>=6.2)
        @available(macOS 26.0, *)
        public static var supportedModes: IntentModes { [.foreground(.dynamic)] }
    #endif

    @Parameter(title: "Settings Tab")
    public var tab: WinkSettingsTabIntentValue?

    @Dependency private var actions: WinkActionClient

    public init() {}

    public init(tab: WinkSettingsTabIntentValue?, client: WinkActionClient) {
        self.init()
        self.tab = tab
        actions = client
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Open Wink Settings at \(\.$tab)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await actions.execute(.openSettings(tab))
        return .result(dialog: "Wink Settings is open.")
    }
}

public struct WinkAppShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PauseWinkIntent(),
            phrases: ["Pause \(.applicationName)"],
            shortTitle: "Pause Wink",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeWinkIntent(),
            phrases: ["Resume \(.applicationName)"],
            shortTitle: "Resume Wink",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: ShowWinkSearchPaletteIntent(),
            phrases: ["Search with \(.applicationName)"],
            shortTitle: "Search with Wink",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenWinkSettingsIntent(),
            phrases: ["Open \(.applicationName) settings"],
            shortTitle: "Open Wink Settings",
            systemImageName: "gearshape"
        )
    }

    public static let shortcutTileColor: ShortcutTileColor = .purple
}
