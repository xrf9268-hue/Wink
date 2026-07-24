import AppKit

/// The app-scan roots shared by `AppListProvider.scanInstalledApps` and the
/// suggestion eligibility policy below. One source of truth: the #384
/// trade-off ("a non-.regular process is legitimate only when it resolves
/// to an installed app") is only coherent while both sides agree on what
/// "installed" means.
enum StandardApplicationDirectories {
    static let roots: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
    ]

    /// Component-wise containment (a plain string-prefix check would accept
    /// "/ApplicationsFake/X.app"), additionally rejecting bundles nested
    /// inside another .app: an embedded helper at
    /// /Applications/X.app/Contents/.../Helper.app is not an installed app,
    /// and the AppListProvider scan never descends into .app bundles either.
    static func contains(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard let bundleName = components.last, bundleName.hasSuffix(".app"),
              components.dropLast().allSatisfy({ !$0.hasSuffix(".app") }) else {
            return false
        }
        return roots.contains { root in
            let rootComponents = root.standardizedFileURL.pathComponents
            return components.count > rootComponents.count
                && Array(components.prefix(rootComponents.count)) == rootComponents
        }
    }
}

/// Which app activations deserve recording and surfacing in the Insights
/// "Suggested shortcuts" card. Non-.regular processes are background
/// agents, transient system dialogs (universalAccessAuthWarn — the
/// Accessibility auth warning briefly becomes the active app), and embedded
/// helpers — never suggestion material — UNLESS installed in a standard
/// application directory: a real app running menu-bar-only or with a
/// hidden Dock icon reports .accessory while remaining a legitimate switch
/// target (the Settings picker lists it via the disk scan, and the toggle
/// engine supports windowless .accessory targets).
enum AppSuggestionEligibility {
    /// Record-time gate, where the live activation policy is available.
    static func shouldRecordActivation(
        activationPolicy: NSApplication.ActivationPolicy,
        bundleURL: URL?
    ) -> Bool {
        if activationPolicy == .regular { return true }
        guard let bundleURL else { return false }
        return StandardApplicationDirectories.contains(bundleURL)
    }

    /// Query-time gate for rows recorded before the record-time filter
    /// existed (they persist until the user toggles collection off — there
    /// is no age-out for app_activations). The process is usually gone by
    /// query time, so LSUIElement/LSBackgroundOnly stand in for the live
    /// activation policy; an unreadable Info.plist keeps the app, matching
    /// the record-time default of trusting .regular.
    static func isSuggestable(appURL: URL) -> Bool {
        if StandardApplicationDirectories.contains(appURL) { return true }
        return !declaresBackgroundUI(at: appURL)
    }

    private static func declaresBackgroundUI(at url: URL) -> Bool {
        guard let info = Bundle(url: url)?.infoDictionary else { return false }
        return boolValue(info["LSUIElement"]) || boolValue(info["LSBackgroundOnly"])
    }

    /// Info.plist booleans appear as <true/>, <integer>1</integer>, or
    /// <string>1</string> depending on the bundle's era —
    /// universalAccessAuthWarn itself ships the numeric form.
    private static func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return (string as NSString).boolValue }
        return false
    }
}
