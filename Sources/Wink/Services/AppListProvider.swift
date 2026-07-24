import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "AppListProvider")

struct AppEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL

    var bundleIdentifier: String { id }

    /// Pinned picker entry for frontmost-app shortcuts. The URL is a
    /// placeholder — the sentinel bundle names no installed app; selection
    /// is recognized by bundle identifier, never by path.
    ///
    /// `name` is the locale-stable name (not the localized display label):
    /// selecting this entry copies `name` straight into a new shortcut's
    /// persisted `appName` (see `ShortcutsTabView`'s picker `onSelect`), so
    /// it must stay `AppShortcut.frontmostTargetStableName`. Display sites
    /// (the picker row itself, and any shortcut's `displayAppName`) resolve
    /// the localized label separately.
    static let frontmostTarget = AppEntry(
        id: AppShortcut.frontmostTargetSentinelBundleIdentifier,
        name: AppShortcut.frontmostTargetStableName,
        url: URL(fileURLWithPath: "/")
    )
}

struct RunningApplicationSnapshot: Sendable {
    let bundleIdentifier: String?
    let localizedName: String?
    let bundleURL: URL?
    let activationPolicy: NSApplication.ActivationPolicy
}

@MainActor
@Observable
final class AppListProvider {
    struct Client: Sendable {
        let now: @Sendable () -> Date
        let scanInstalledApps: @Sendable () async -> [AppEntry]
        let runningApplications: @MainActor () -> [RunningApplicationSnapshot]
        let loadRecents: @Sendable () -> [String]?
        let saveRecents: @Sendable ([String]) -> Void
        let mainBundleIdentifier: @Sendable () -> String?
    }

    private(set) var allApps: [AppEntry] = []
    private(set) var recentBundleIDs: [String] = []
    private var lastScanTime: Date?
    private var allAppsByID: [String: AppEntry] = [:]

    /// Fires whenever a scan (forced or `refreshIfNeeded`-triggered)
    /// completes and `allApps` is updated. The #356 search palette uses this
    /// to stay resilient to a trigger fired before the first scan lands:
    /// if it's presented when this fires, it rebuilds its candidates and
    /// re-renders instead of staying on a stale/empty snapshot until
    /// dismiss/reopen.
    var onRefreshCompleted: (@MainActor () -> Void)?

    var recentApps: [AppEntry] {
        recentBundleIDs.compactMap { allAppsByID[$0] }
    }

    private var isScanning = false
    private let client: Client
    private var refreshTask: Task<Void, Never>?

    init(client: Client = .live) {
        self.client = client
    }

    func refreshIfNeeded() {
        refresh(force: false)
    }

    func forceRefresh() {
        refresh(force: true)
    }

    func noteRecentApp(bundleIdentifier: String) {
        recentBundleIDs.removeAll { $0 == bundleIdentifier }
        recentBundleIDs.insert(bundleIdentifier, at: 0)
        if recentBundleIDs.count > 10 {
            recentBundleIDs = Array(recentBundleIDs.prefix(10))
        }
        saveRecents()
    }

    func waitForRefreshForTesting() async {
        await refreshTask?.value
    }

    func refreshAndWaitIfNeeded() async {
        refreshIfNeeded()
        await waitForRefreshForTesting()
    }

    func forceRefreshAndWait() async {
        forceRefresh()
        await waitForRefreshForTesting()
    }

    func filteredApps(query: String) -> [AppEntry] {
        guard !query.isEmpty else { return allApps }
        let lowered = query.lowercased()
        return allApps.filter {
            $0.name.lowercased().contains(lowered) ||
            $0.bundleIdentifier.lowercased().contains(lowered)
        }
    }

    func app(for bundleIdentifier: String) -> AppEntry? {
        allAppsByID[bundleIdentifier]
    }

    func apps(named appName: String) -> [AppEntry] {
        allApps.filter {
            $0.name.compare(
                appName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
    }

    var hasScannedApps: Bool {
        lastScanTime != nil
    }

    func isInstalled(bundleIdentifier: String) -> Bool {
        allAppsByID[bundleIdentifier] != nil
    }

    // MARK: - Scanning

    private func refresh(force: Bool) {
        if !force,
           let lastScan = lastScanTime,
           client.now().timeIntervalSince(lastScan) < 60 {
            return
        }
        guard !isScanning else { return }
        isScanning = true
        refreshTask = Task { [client] in
            let scanned = await client.scanInstalledApps()
            let runningApplications = client.runningApplications()
            applyRefresh(
                scanned: scanned,
                runningApplications: runningApplications,
                now: client.now()
            )
        }
    }

    nonisolated private static func scanInstalledApps() -> [AppEntry] {
        // Shared with AppSuggestionEligibility: the suggestion policy's
        // "installed app" exception must mean the same roots this scan uses.
        let searchDirs = StandardApplicationDirectories.roots

        var seen = Set<String>()
        var entries: [AppEntry] = []

        for dir in searchDirs {
            scanDirectory(dir, into: &entries, seen: &seen, depth: 0)
        }

        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return entries
    }

    private func applyRefresh(
        scanned: [AppEntry],
        runningApplications: [RunningApplicationSnapshot],
        now: Date
    ) {
        var entries = scanned
        var seen = Set(entries.map(\.id))

        for app in runningApplications {
            // .accessory/.prohibited apps are background agents and embedded
            // helpers (loginwindow, WindowManager, an app's own auxiliary
            // process) — never user-facing switch targets, and some share a
            // localizedName with their .regular parent (#384's WeChat case).
            // Trade-off: a legitimate .accessory app running from outside
            // every scan root (e.g. launched from Downloads or an external
            // volume) is knowingly excluded here too — the installed scan
            // above already covers the legitimate standard-location case.
            guard app.activationPolicy == .regular,
                  let bid = app.bundleIdentifier,
                  !seen.contains(bid),
                  let url = app.bundleURL else { continue }
            let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            entries.append(AppEntry(id: bid, name: name, url: url))
            seen.insert(bid)
        }

        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        allApps = entries
        allAppsByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        lastScanTime = now
        loadRecents(from: runningApplications)
        isScanning = false
        refreshTask = nil
        onRefreshCompleted?()
    }

    nonisolated private static func scanDirectory(_ dir: URL, into entries: inout [AppEntry], seen: inout Set<String>, depth: Int) {
        guard depth < 3 else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        for url in contents {
            if url.pathExtension == "app" {
                if let bundle = Bundle(url: url),
                   let bid = bundle.bundleIdentifier,
                   !seen.contains(bid) {
                    let name = localizedAppName(for: bundle) ?? url.deletingPathExtension().lastPathComponent
                    entries.append(AppEntry(id: bid, name: name, url: url))
                    seen.insert(bid)
                }
            } else {
                // Recurse into subdirectories (e.g., /Applications/Utilities)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    scanDirectory(url, into: &entries, seen: &seen, depth: depth + 1)
                }
            }
        }
    }

    /// Prefers the bundle's LOCALIZED display name/name (reads the
    /// `.lproj` `InfoPlist.strings` the app itself ships) over the base
    /// `infoDictionary`'s development-language values — matters for the
    /// #356 search palette's CJK containment claim: `bundle.infoDictionary`
    /// alone would return an app's English name even under a zh-Hans system
    /// language, so "微信" would never match WeChat by name for a zh-Hans
    /// user. Also improves `AppPickerPopover`'s search, which reads the same
    /// `AppListProvider.allApps` snapshot. Reads from the already-loaded
    /// `Bundle` object (no extra filesystem walk beyond what `Bundle(url:)`
    /// already performs), so this doesn't add a distinguishable scan-perf
    /// cost.
    nonisolated private static func localizedAppName(for bundle: Bundle) -> String? {
        (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
    }

    // MARK: - Recents persistence

    private func loadRecents(from runningApplications: [RunningApplicationSnapshot]) {
        guard let ids = client.loadRecents() else {
            // Seed from running apps if no recents file exists
            recentBundleIDs = runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.bundleIdentifier)
                .filter { $0 != client.mainBundleIdentifier() }
                .prefix(10)
                .map { $0 }
            return
        }
        // Conservative sanitation, not a general filter: only drop an id when
        // BOTH (a) the CURRENT running snapshot proves it's a non-.regular
        // process AND (b) it's absent from `allAppsByID` — i.e. it resolves
        // to no installed app on any scan root. This targets exactly the
        // #384 system agents (loginwindow, WindowManager, ...), which live
        // under /System/Library/CoreServices outside every scan root and are
        // no longer merged into `allApps`/`allAppsByID` by the filter above.
        // A currently-.accessory id that DOES resolve in `allAppsByID` is a
        // legitimate installed menu-bar-only app (Wink's toggle engine
        // supports windowless .accessory targets, see
        // docs/architecture.md:405) that a user could have picked from
        // Settings — pruning it would wrongly evict a real recent. An id
        // absent from the running snapshot entirely is left alone too — it
        // may be a valid recent for an app that simply isn't running right
        // now. `allAppsByID` is rebuilt just above (this method runs at the
        // end of `applyRefresh`, after the `allApps`/`allAppsByID` assignment),
        // so this check always sees the current-refresh installed set.
        let nonRegularRunningIDs = Set(
            runningApplications
                .filter { $0.activationPolicy != .regular }
                .compactMap(\.bundleIdentifier)
        )
        recentBundleIDs = ids.filter { id in
            !nonRegularRunningIDs.contains(id) || allAppsByID[id] != nil
        }
    }

    private func saveRecents() {
        client.saveRecents(recentBundleIDs)
    }
}

extension AppListProvider.Client {
    static let live = AppListProvider.Client(
        now: {
            Date()
        },
        scanInstalledApps: {
            await Task.detached(priority: .userInitiated) {
                AppListProvider.scanInstalledApps()
            }.value
        },
        runningApplications: {
            NSWorkspace.shared.runningApplications.map { app in
                RunningApplicationSnapshot(
                    bundleIdentifier: app.bundleIdentifier,
                    localizedName: app.localizedName,
                    bundleURL: app.bundleURL,
                    activationPolicy: app.activationPolicy
                )
            }
        },
        loadRecents: {
            AppListProvider.loadRecentsFromDisk()
        },
        saveRecents: { recentBundleIDs in
            AppListProvider.saveRecentsToDisk(recentBundleIDs)
        },
        mainBundleIdentifier: {
            Bundle.main.bundleIdentifier
        }
    )
}

private extension AppListProvider {
    nonisolated static func recentsURL() -> URL? {
        StoragePaths.appSupportDirectory()?.appendingPathComponent("recent-apps.json")
    }

    nonisolated static func loadRecentsFromDisk() -> [String]? {
        guard let url = recentsURL(),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    nonisolated static func saveRecentsToDisk(_ recentBundleIDs: [String]) {
        guard let url = recentsURL() else { return }
        do {
            let data = try JSONEncoder().encode(recentBundleIDs)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save recents: \(error.localizedDescription)")
        }
    }
}
