import Foundation

struct MenuBarShortcutItemPresentation: Equatable {
    let bundleIdentifier: String?
    let titleText: String
    let shortcutText: String?
    let statusText: String?
    let unavailableStatusText: String?
    let unavailableHelpText: String?
    let isEnabled: Bool
    let isRunning: Bool
    let isUnavailable: Bool
    let isPlaceholder: Bool

    init(
        bundleIdentifier: String?,
        titleText: String,
        shortcutText: String?,
        statusText: String?,
        unavailableStatusText: String?,
        unavailableHelpText: String?,
        isEnabled: Bool,
        isRunning: Bool,
        isUnavailable: Bool,
        isPlaceholder: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.titleText = titleText
        self.shortcutText = shortcutText
        self.statusText = statusText
        self.unavailableStatusText = unavailableStatusText
        self.unavailableHelpText = unavailableHelpText
        self.isEnabled = isEnabled
        self.isRunning = isRunning
        self.isUnavailable = isUnavailable
        self.isPlaceholder = isPlaceholder
    }

    init(shortcut: AppShortcut, runtimeStatus: ShortcutRuntimeStatus) {
        self.init(
            bundleIdentifier: shortcut.bundleIdentifier,
            titleText: shortcut.appName,
            shortcutText: shortcut.displayText,
            statusText: shortcut.isEnabled ? nil : "Disabled",
            unavailableStatusText: runtimeStatus.isUnavailable ? "App unavailable" : nil,
            unavailableHelpText: runtimeStatus.isUnavailable
                ? "Couldn't find this app. Rebind it to restore the shortcut."
                : nil,
            isEnabled: shortcut.isEnabled,
            isRunning: runtimeStatus.isRunning,
            isUnavailable: runtimeStatus.isUnavailable,
            isPlaceholder: false
        )
    }

    var accessibilityTitle: String {
        guard !isPlaceholder else {
            return titleText
        }

        var segments = [titleText]

        if let shortcutText, !shortcutText.isEmpty {
            segments.append(shortcutText)
        }
        if let statusText, !statusText.isEmpty {
            segments.append(statusText)
        }
        if let unavailableStatusText, !unavailableStatusText.isEmpty {
            segments.append(unavailableStatusText)
        }
        if isRunning {
            segments.append("Running")
        }

        return segments.joined(separator: ", ")
    }

    static func build(
        from shortcuts: [AppShortcut],
        statusResolver: (AppShortcut) -> ShortcutRuntimeStatus
    ) -> [MenuBarShortcutItemPresentation] {
        guard !shortcuts.isEmpty else {
            return [.placeholder]
        }

        return shortcuts.map { shortcut in
            MenuBarShortcutItemPresentation(
                shortcut: shortcut,
                runtimeStatus: statusResolver(shortcut)
            )
        }
    }

    static let placeholder = MenuBarShortcutItemPresentation(
        bundleIdentifier: nil,
        titleText: "No shortcuts configured",
        shortcutText: nil,
        statusText: nil,
        unavailableStatusText: nil,
        unavailableHelpText: nil,
        isEnabled: false,
        isRunning: false,
        isUnavailable: false,
        isPlaceholder: true
    )
}
