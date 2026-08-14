import Foundation
import WinkIntents

/// Executes already-delivered custom URLs without treating delivery as caller
/// authentication or as completion of any asynchronous activation request.
/// Parsing happens before each side effect, and diagnostics contain only a
/// normalized accepted command or a bounded rejection code — never the raw URL.
@MainActor
struct WinkURLCommandHandler {
    struct Client {
        let applicationURL: @MainActor (String) -> URL?
        let canonicalBundleIdentifier: @MainActor (URL) -> String?
        let performApplicationAction: @MainActor (AppShortcut, Bool) -> Bool
        let executeSharedAction: @MainActor (
            WinkAction,
            WinkActionExecutor.SettingsPresentationPolicy
        ) throws -> Void
        let log: @MainActor (String) -> Void

        init(
            applicationURL: @escaping @MainActor (String) -> URL?,
            canonicalBundleIdentifier: @escaping @MainActor (URL) -> String? = {
                Bundle(url: $0)?.bundleIdentifier
            },
            performApplicationAction: @escaping @MainActor (AppShortcut, Bool) -> Bool,
            executeSharedAction: @escaping @MainActor (
                WinkAction,
                WinkActionExecutor.SettingsPresentationPolicy
            ) throws -> Void,
            log: @escaping @MainActor (String) -> Void
        ) {
            self.applicationURL = applicationURL
            self.canonicalBundleIdentifier = canonicalBundleIdentifier
            self.performApplicationAction = performApplicationAction
            self.executeSharedAction = executeSharedAction
            self.log = log
        }
    }

    let client: Client

    func handle(_ rawValues: [String]) {
        var handledSearchPresentation = false
        var handledSettingsPresentation = false

        for rawValue in rawValues {
            let command: WinkURLCommand
            switch WinkURLCommand.parseResult(rawValue) {
            case .success(let parsedCommand):
                command = parsedCommand
            case .failure(let rejection):
                client.log("URL: ignored reason=\(rejection.rawValue)")
                continue
            }

            switch command {
            case .toggle(let bundleIdentifier):
                performInstalledApplicationAction(
                    bundleIdentifier: bundleIdentifier,
                    frontmostBehaviorOverride: nil,
                    bypassCooldown: false,
                    command: command
                )
            case .focus(let bundleIdentifier):
                performInstalledApplicationAction(
                    bundleIdentifier: bundleIdentifier,
                    frontmostBehaviorOverride: .focus,
                    bypassCooldown: true,
                    command: command
                )
            case .pause:
                executeShared(.pause, command: command)
            case .resume:
                executeShared(.resume, command: command)
            case .search:
                guard !handledSearchPresentation else {
                    client.log("URL: ignored duplicate_in_batch command=search")
                    continue
                }
                handledSearchPresentation = true
                executeShared(.showSearchPalette, command: command)
            case .openSettings(let tab):
                guard !handledSettingsPresentation else {
                    client.log("URL: ignored duplicate_in_batch command=open-settings")
                    continue
                }
                handledSettingsPresentation = true
                executeShared(
                    .openSettings(tab.map(\.intentValue)),
                    command: command,
                    settingsPresentationPolicy: .allowDeferred
                )
            }
        }
    }

    private func performInstalledApplicationAction(
        bundleIdentifier: String,
        frontmostBehaviorOverride: FrontmostTargetBehavior?,
        bypassCooldown: Bool,
        command: WinkURLCommand
    ) {
        guard let applicationURL = client.applicationURL(bundleIdentifier) else {
            client.log("URL: ignored unavailable command=\(command.diagnosticDescription)")
            return
        }
        let canonicalBundleIdentifier = client.canonicalBundleIdentifier(applicationURL)
            ?? bundleIdentifier
        let normalizedCommand: WinkURLCommand = frontmostBehaviorOverride == .focus
            ? .focus(bundleIdentifier: canonicalBundleIdentifier)
            : .toggle(bundleIdentifier: canonicalBundleIdentifier)
        let shortcut = AppShortcut(
            appName: applicationURL.deletingPathExtension().lastPathComponent,
            bundleIdentifier: canonicalBundleIdentifier,
            keyEquivalent: "",
            modifierFlags: [],
            frontmostBehaviorOverride: frontmostBehaviorOverride
        )
        client.log("URL: accepted command=\(normalizedCommand.diagnosticDescription)")
        _ = client.performApplicationAction(shortcut, bypassCooldown)
    }

    private func executeShared(
        _ action: WinkAction,
        command: WinkURLCommand,
        settingsPresentationPolicy: WinkActionExecutor.SettingsPresentationPolicy = .requireReady
    ) {
        client.log("URL: accepted command=\(command.diagnosticDescription)")
        do {
            try client.executeSharedAction(action, settingsPresentationPolicy)
        } catch {
            client.log("URL: action_failed command=\(command.diagnosticDescription)")
        }
    }
}

private extension WinkURLSettingsTab {
    var intentValue: WinkSettingsTabIntentValue {
        switch self {
        case .shortcuts: .shortcuts
        case .general: .general
        case .insights: .insights
        }
    }
}
