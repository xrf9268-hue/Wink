import AppKit
import Observation

struct ShortcutRuntimeStatus: Equatable {
    let isRunning: Bool
    let isUnavailable: Bool

    static let normal = ShortcutRuntimeStatus(isRunning: false, isUnavailable: false)
}

@MainActor
@Observable
final class ShortcutStatusProvider {
    struct Client {
        let applicationURL: (String) -> URL?
        let runningBundleIdentifiers: () -> Set<String>
    }

    private struct ObservationToken {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    private let client: Client
    private let workspaceNotificationCenter: NotificationCenter
    private let appNotificationCenter: NotificationCenter
    private var trackedShortcuts: [AppShortcut] = []
    private nonisolated(unsafe) var observationTokens: [ObservationToken] = []

    private(set) var statusesByShortcutID: [UUID: ShortcutRuntimeStatus] = [:]

    init(
        client: Client = .live,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        appNotificationCenter: NotificationCenter = .default
    ) {
        self.client = client
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.appNotificationCenter = appNotificationCenter
        observeNotifications()
    }

    deinit {
        for observation in observationTokens {
            observation.center.removeObserver(observation.token)
        }
    }

    func track(_ shortcuts: [AppShortcut]) {
        trackedShortcuts = shortcuts
        refresh()
    }

    func refresh() {
        statusesByShortcutID = makeStatuses(for: trackedShortcuts)
    }

    func status(for shortcut: AppShortcut) -> ShortcutRuntimeStatus {
        statusesByShortcutID[shortcut.id]
            ?? makeStatuses(for: [shortcut])[shortcut.id]
            ?? .normal
    }

    private func observeNotifications() {
        let workspaceNotifications: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]

        for name in workspaceNotifications {
            addObservation(for: name, center: workspaceNotificationCenter)
        }

        addObservation(
            for: NSApplication.didBecomeActiveNotification,
            center: appNotificationCenter
        )
    }

    private func addObservation(
        for name: Notification.Name,
        center: NotificationCenter
    ) {
        let token = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.refresh()
            }
        }

        observationTokens.append(
            ObservationToken(center: center, token: token)
        )
    }

    private func makeStatuses(
        for shortcuts: [AppShortcut]
    ) -> [UUID: ShortcutRuntimeStatus] {
        let runningBundleIdentifiers = client.runningBundleIdentifiers()
        let uniqueBundleIdentifiers = Set(shortcuts.map(\.bundleIdentifier))
        let availabilityByBundleIdentifier = Dictionary(
            uniqueKeysWithValues: uniqueBundleIdentifiers.map { bundleIdentifier in
                // A currently running app is still actionable even if LaunchServices
                // cannot resolve it back to a bundle URL from its install location.
                let isAvailable = runningBundleIdentifiers.contains(bundleIdentifier)
                    || client.applicationURL(bundleIdentifier) != nil
                return (bundleIdentifier, isAvailable)
            }
        )

        return Dictionary(uniqueKeysWithValues: shortcuts.map { shortcut in
            let isRunning = runningBundleIdentifiers.contains(shortcut.bundleIdentifier)
            let isUnavailable = !(availabilityByBundleIdentifier[shortcut.bundleIdentifier] ?? false)
            return (
                shortcut.id,
                ShortcutRuntimeStatus(
                    isRunning: isRunning,
                    isUnavailable: isUnavailable
                )
            )
        })
    }
}

extension ShortcutStatusProvider.Client {
    @MainActor
    static let live = ShortcutStatusProvider.Client(
        applicationURL: { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        },
        runningBundleIdentifiers: {
            Set(
                NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            )
        }
    )
}
