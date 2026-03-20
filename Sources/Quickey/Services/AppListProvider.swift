import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "AppListProvider")

struct AppEntry: Identifiable, Hashable {
    let id: String // bundleIdentifier
    let name: String
    let bundleIdentifier: String
    let url: URL
}

@MainActor
@Observable
final class AppListProvider {
    private(set) var allApps: [AppEntry] = []
    private(set) var recentBundleIDs: [String] = []
    private var lastScanTime: Date?

    var recentApps: [AppEntry] {
        let lookup = Dictionary(uniqueKeysWithValues: allApps.map { ($0.bundleIdentifier, $0) })
        return recentBundleIDs.compactMap { lookup[$0] }
    }

    func refreshIfNeeded() {
        if let lastScan = lastScanTime, Date().timeIntervalSince(lastScan) < 60 {
            return
        }
        scanInstalledApps()
        loadRecents()
    }

    func noteRecentApp(bundleIdentifier: String) {
        recentBundleIDs.removeAll { $0 == bundleIdentifier }
        recentBundleIDs.insert(bundleIdentifier, at: 0)
        if recentBundleIDs.count > 10 {
            recentBundleIDs = Array(recentBundleIDs.prefix(10))
        }
        saveRecents()
    }

    func filteredApps(query: String) -> [AppEntry] {
        guard !query.isEmpty else { return allApps }
        let lowered = query.lowercased()
        return allApps.filter {
            $0.name.lowercased().contains(lowered) ||
            $0.bundleIdentifier.lowercased().contains(lowered)
        }
    }

    // MARK: - Scanning

    private func scanInstalledApps() {
        let searchDirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
        ]

        var seen = Set<String>()
        var entries: [AppEntry] = []

        for dir in searchDirs {
            scanDirectory(dir, into: &entries, seen: &seen, depth: 0)
        }

        // Also add currently running apps not found in directories
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier,
                  !seen.contains(bid),
                  let url = app.bundleURL else { continue }
            let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            entries.append(AppEntry(id: bid, name: name, bundleIdentifier: bid, url: url))
            seen.insert(bid)
        }

        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        allApps = entries
        lastScanTime = Date()
    }

    private func scanDirectory(_ dir: URL, into entries: inout [AppEntry], seen: inout Set<String>, depth: Int) {
        guard depth < 3 else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        for url in contents {
            if url.pathExtension == "app" {
                if let bundle = Bundle(url: url),
                   let bid = bundle.bundleIdentifier,
                   !seen.contains(bid) {
                    let name = (bundle.infoDictionary?["CFBundleName"] as? String)
                        ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                        ?? url.deletingPathExtension().lastPathComponent
                    entries.append(AppEntry(id: bid, name: name, bundleIdentifier: bid, url: url))
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

    // MARK: - Recents persistence

    private var recentsURL: URL? {
        StoragePaths.appSupportDirectory()?.appendingPathComponent("recent-apps.json")
    }

    private func loadRecents() {
        guard let url = recentsURL,
              let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            // Seed from running apps if no recents file exists
            recentBundleIDs = NSWorkspace.shared.runningApplications
                .compactMap(\.bundleIdentifier)
                .filter { $0 != Bundle.main.bundleIdentifier }
                .prefix(10)
                .map { $0 }
            return
        }
        recentBundleIDs = ids
    }

    private func saveRecents() {
        guard let url = recentsURL else { return }
        do {
            let data = try JSONEncoder().encode(recentBundleIDs)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save recents: \(error.localizedDescription)")
        }
    }
}
