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
    ///
    /// Both sides are normalized the way LaunchAtLoginService's
    /// installed-in-Applications check normalizes (standardize + resolve
    /// symlinks), plus two spellings symlink resolution cannot collapse:
    /// the APFS firmlink alias /System/Volumes/Data/Applications, and
    /// case variants on the default case-insensitive volume. The candidate
    /// is tried both WITH and WITHOUT symlink resolution — resolution alone
    /// would evict cryptex-backed apps (/Applications/Safari.app is a
    /// symlink into /System/Cryptexes and must still count as installed),
    /// while no resolution would miss a symlink that points INTO a root.
    static func contains(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        var candidates = [normalizedComponents(of: standardized)]
        let resolved = normalizedComponents(of: standardized.resolvingSymlinksInPath())
        if resolved != candidates[0] { candidates.append(resolved) }
        return candidates.contains { components in
            guard let bundleName = components.last, bundleName.lowercased().hasSuffix(".app"),
                  components.dropLast().allSatisfy({ !$0.lowercased().hasSuffix(".app") }) else {
                return false
            }
            return normalizedRoots.contains { root in
                components.count > root.count
                    && zip(root, components).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
            }
        }
    }

    private static let normalizedRoots: [[String]] = roots.map {
        normalizedComponents(of: $0.standardizedFileURL.resolvingSymlinksInPath())
    }

    private static func normalizedComponents(of url: URL) -> [String] {
        var components = url.pathComponents
        // /System/Volumes/Data/Applications is the same directory as
        // /Applications through an APFS firmlink, which is not a symlink —
        // no URL API collapses it, so strip the alias prefix by hand.
        if components.count > 4, components[0] == "/",
           components[1] == "System", components[2] == "Volumes", components[3] == "Data" {
            components = ["/"] + components.dropFirst(4)
        }
        return components
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
