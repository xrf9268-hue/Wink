# UI Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Overhaul the Settings window with grouped card layout, app picker popover, per-shortcut enable/disable, and alternating row colors across all three tabs.

**Architecture:** Bottom-up approach — data model first, then shared UI components, then service layer (AppListProvider), then each tab view, and finally wiring. Each task produces a compilable, testable increment.

**Tech Stack:** Swift 6, SwiftUI + AppKit (NSViewRepresentable for popover keyboard nav), macOS 14+, SPM

---

### Task 1: Add `isEnabled` to AppShortcut + backward-compatible decoding

**Files:**
- Modify: `Sources/Quickey/Models/AppShortcut.swift`
- Modify: `Tests/QuickeyTests/QuickeyTests.swift`

- [ ] **Step 1: Write failing tests for isEnabled field and backward-compat decoding**

Add to `Tests/QuickeyTests/QuickeyTests.swift`:

```swift
// MARK: - AppShortcut isEnabled

@Suite("AppShortcut isEnabled")
struct AppShortcutIsEnabledTests {
    @Test
    func defaultsToEnabled() {
        let shortcut = AppShortcut(
            appName: "Test", bundleIdentifier: "com.test",
            keyEquivalent: "a", modifierFlags: ["command"]
        )
        #expect(shortcut.isEnabled == true)
    }

    @Test
    func canBeCreatedDisabled() {
        let shortcut = AppShortcut(
            appName: "Test", bundleIdentifier: "com.test",
            keyEquivalent: "a", modifierFlags: ["command"],
            isEnabled: false
        )
        #expect(shortcut.isEnabled == false)
    }

    @Test
    func decodesLegacyJSONWithoutIsEnabled() throws {
        // Simulate JSON saved by old version (no isEnabled key)
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "appName": "Safari",
            "bundleIdentifier": "com.apple.Safari",
            "keyEquivalent": "s",
            "modifierFlags": ["command"]
        }
        """.data(using: .utf8)!
        let shortcut = try JSONDecoder().decode(AppShortcut.self, from: json)
        #expect(shortcut.isEnabled == true)
        #expect(shortcut.appName == "Safari")
    }

    @Test
    func roundTripsWithIsEnabled() throws {
        let original = AppShortcut(
            appName: "Test", bundleIdentifier: "com.test",
            keyEquivalent: "x", modifierFlags: ["option"],
            isEnabled: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppShortcut.self, from: data)
        #expect(decoded.isEnabled == false)
        #expect(decoded.id == original.id)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "AppShortcutIsEnabledTests" 2>&1 | tail -20`
Expected: Compilation errors — `isEnabled` parameter does not exist.

- [ ] **Step 3: Implement isEnabled on AppShortcut**

Update `Sources/Quickey/Models/AppShortcut.swift`:

```swift
import Foundation

struct AppShortcut: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var appName: String
    var bundleIdentifier: String
    var keyEquivalent: String
    var modifierFlags: [String]
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        appName: String,
        bundleIdentifier: String,
        keyEquivalent: String,
        modifierFlags: [String],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
        self.isEnabled = isEnabled
    }

    // Backward-compatible decoding: old JSON without isEnabled defaults to true
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        appName = try container.decode(String.self, forKey: .appName)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        keyEquivalent = try container.decode(String.self, forKey: .keyEquivalent)
        modifierFlags = try container.decode([String].self, forKey: .modifierFlags)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
```

- [ ] **Step 4: Run all tests to verify they pass**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass (existing tests unaffected because `isEnabled` defaults to `true`).

- [ ] **Step 5: Commit**

```bash
git add Sources/Quickey/Models/AppShortcut.swift Tests/QuickeyTests/QuickeyTests.swift
git commit -m "feat: add isEnabled to AppShortcut with backward-compatible decoding"
```

---

### Task 2: Add toggle/enable-all methods to ShortcutEditorState + filter in ShortcutManager

**Files:**
- Modify: `Sources/Quickey/Services/ShortcutEditorState.swift`
- Modify: `Sources/Quickey/Services/ShortcutManager.swift` (line 175-176: `rebuildIndex()`)
- Modify: `Sources/Quickey/Services/KeyMatcher.swift` (line 26-33: `buildIndex`)
- Modify: `Tests/QuickeyTests/QuickeyTests.swift`

- [ ] **Step 1: Write failing test for KeyMatcher filtering disabled shortcuts**

Add to `Tests/QuickeyTests/QuickeyTests.swift` inside `KeyMatcherTests`:

```swift
@Test
func buildIndexExcludesDisabledShortcuts() {
    let enabled = AppShortcut(appName: "A", bundleIdentifier: "com.a", keyEquivalent: "a", modifierFlags: ["command"], isEnabled: true)
    let disabled = AppShortcut(appName: "B", bundleIdentifier: "com.b", keyEquivalent: "b", modifierFlags: ["option"], isEnabled: false)
    let index = matcher.buildIndex(for: [enabled, disabled])
    #expect(index.count == 1)
    #expect(index.values.first?.bundleIdentifier == "com.a")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "buildIndexExcludesDisabledShortcuts" 2>&1 | tail -10`
Expected: FAIL — index.count == 2, not 1.

- [ ] **Step 3: Update KeyMatcher.buildIndex to filter disabled shortcuts**

In `Sources/Quickey/Services/KeyMatcher.swift`, update `buildIndex`:

```swift
func buildIndex(for shortcuts: [AppShortcut]) -> [ShortcutTrigger: AppShortcut] {
    let enabled = shortcuts.filter(\.isEnabled)
    var index: [ShortcutTrigger: AppShortcut] = [:]
    index.reserveCapacity(enabled.count)
    for shortcut in enabled {
        index[trigger(for: shortcut)] = shortcut
    }
    return index
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test 2>&1 | tail -20`
Expected: All pass.

- [ ] **Step 5: Add toggle and enable-all methods to ShortcutEditorState**

In `Sources/Quickey/Services/ShortcutEditorState.swift`, add these methods after `removeShortcut`:

```swift
var allEnabled: Bool {
    shortcuts.contains { $0.isEnabled }
}

func toggleShortcutEnabled(id: UUID) {
    guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
    shortcuts[index].isEnabled.toggle()
    shortcutManager.save(shortcuts: shortcuts)
}

func setAllEnabled(_ enabled: Bool) {
    for index in shortcuts.indices {
        shortcuts[index].isEnabled = enabled
    }
    shortcutManager.save(shortcuts: shortcuts)
}
```

- [ ] **Step 6: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All pass (no compilation errors).

- [ ] **Step 7: Commit**

```bash
git add Sources/Quickey/Services/ShortcutEditorState.swift Sources/Quickey/Services/KeyMatcher.swift Tests/QuickeyTests/QuickeyTests.swift
git commit -m "feat: add shortcut enable/disable toggle and filter disabled from trigger index"
```

---

### Task 3: Create SharedComponents.swift — card style, section title, ShortcutLabel extraction

**Files:**
- Create: `Sources/Quickey/UI/SharedComponents.swift`
- Modify: `Sources/Quickey/UI/ShortcutsTabView.swift` (remove `private struct ShortcutLabel`, lines 97-116)

- [ ] **Step 1: Create SharedComponents.swift with card modifier, section title, and ShortcutLabel**

```swift
import SwiftUI

// MARK: - Card container

struct CardView<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }
            content()
        }
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Alternating row background

extension View {
    func alternatingRowBackground(index: Int) -> some View {
        self.background(index.isMultiple(of: 2)
            ? Color.clear
            : Color.primary.opacity(0.03))
    }
}

// MARK: - App icon resolver

struct AppIconView: View {
    let bundleIdentifier: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: resolveIcon())
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }

    private func resolveIcon() -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}

// MARK: - Shortcut label badge

struct ShortcutLabel: View {
    let displayText: String
    let isHyper: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(displayText)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            if isHyper {
                Text("Hyper")
                    .font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.purple.opacity(0.2))
                    .foregroundStyle(.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }
}

// MARK: - Permission status banner

struct PermissionStatusBanner: View {
    let granted: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(granted ? "Accessibility granted" : "Accessibility required for global shortcuts")
                .font(.system(size: 12))
                .foregroundStyle(granted ? .green : .orange)
            Spacer()
            Button("Refresh") { onRefresh() }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background((granted ? Color.green : Color.orange).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke((granted ? Color.green : Color.orange).opacity(0.2), lineWidth: 1)
        )
    }
}
```

- [ ] **Step 2: Remove private ShortcutLabel from ShortcutsTabView.swift**

Remove lines 97-116 (the `private struct ShortcutLabel` and its body) from `Sources/Quickey/UI/ShortcutsTabView.swift`. The `ShortcutLabel` references inside `ShortcutsTabView` body will now resolve to the one in `SharedComponents.swift`.

- [ ] **Step 3: Build to verify compilation**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeded.

- [ ] **Step 4: Run all tests**

Run: `swift test 2>&1 | tail -10`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Quickey/UI/SharedComponents.swift Sources/Quickey/UI/ShortcutsTabView.swift
git commit -m "feat: extract SharedComponents — CardView, AppIconView, ShortcutLabel, PermissionStatusBanner"
```

---

### Task 4: Create AppListProvider service

**Files:**
- Create: `Sources/Quickey/Services/AppListProvider.swift`

- [ ] **Step 1: Create AppListProvider.swift**

```swift
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
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeded.

- [ ] **Step 3: Commit**

```bash
git add Sources/Quickey/Services/AppListProvider.swift
git commit -m "feat: add AppListProvider — scans installed apps, maintains persistent recents"
```

---

### Task 5: Create AppPickerPopover view

**Files:**
- Create: `Sources/Quickey/UI/AppPickerPopover.swift`

- [ ] **Step 1: Create AppPickerPopover.swift**

```swift
import AppKit
import SwiftUI

struct AppPickerPopover: View {
    @Bindable var appListProvider: AppListProvider
    let onSelect: (AppEntry) -> Void
    let onBrowse: () -> Void

    @State private var searchText = ""
    @State private var highlightedIndex: Int?
    @Environment(\.dismiss) private var dismiss

    private var filteredRecent: [AppEntry] {
        if searchText.isEmpty {
            return appListProvider.recentApps
        }
        return [] // Hide sections during search
    }

    private var filteredAll: [AppEntry] {
        appListProvider.filteredApps(query: searchText)
    }

    private var flatList: [AppEntry] {
        if searchText.isEmpty {
            // Deduplicate: recent first, then remaining all
            let recentIDs = Set(filteredRecent.map(\.bundleIdentifier))
            return filteredRecent + filteredAll.filter { !recentIDs.contains($0.bundleIdentifier) }
        }
        return filteredAll
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { selectHighlighted() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // Scrollable list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if searchText.isEmpty {
                            if !filteredRecent.isEmpty {
                                sectionHeader("Recently Used")
                                ForEach(Array(filteredRecent.enumerated()), id: \.element.id) { index, entry in
                                    appRow(entry, index: index, proxy: proxy)
                                }
                            }

                            let recentIDs = Set(filteredRecent.map(\.bundleIdentifier))
                            let remaining = filteredAll.filter { !recentIDs.contains($0.bundleIdentifier) }
                            if !remaining.isEmpty {
                                sectionHeader("All Apps")
                                ForEach(Array(remaining.enumerated()), id: \.element.id) { i, entry in
                                    let index = filteredRecent.count + i
                                    appRow(entry, index: index, proxy: proxy)
                                }
                            }
                        } else {
                            ForEach(Array(filteredAll.enumerated()), id: \.element.id) { index, entry in
                                appRow(entry, index: index, proxy: proxy)
                            }
                        }
                    }
                }
            }

            Divider()

            // Browse fallback
            Button {
                onBrowse()
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text("Browse...")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 320, height: 400)
        .onAppear {
            appListProvider.refreshIfNeeded()
            highlightedIndex = 0
        }
        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
        .onKeyPress(.return) { selectHighlighted(); return .handled }
    }

    // MARK: - Subviews

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func appRow(_ entry: AppEntry, index: Int, proxy: ScrollViewProxy) -> some View {
        Button {
            select(entry)
        } label: {
            HStack(spacing: 10) {
                AppIconView(bundleIdentifier: entry.bundleIdentifier, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: highlightedIndex == index ? .medium : .regular))
                    Text(entry.bundleIdentifier)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(highlightedIndex == index ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .id(index)
    }

    // MARK: - Navigation

    private func moveHighlight(_ delta: Int) {
        let count = flatList.count
        guard count > 0 else { return }
        let current = highlightedIndex ?? 0
        highlightedIndex = max(0, min(count - 1, current + delta))
    }

    private func selectHighlighted() {
        guard let index = highlightedIndex, index < flatList.count else { return }
        select(flatList[index])
    }

    private func select(_ entry: AppEntry) {
        appListProvider.noteRecentApp(bundleIdentifier: entry.bundleIdentifier)
        onSelect(entry)
        dismiss()
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeded. Note: `.onKeyPress` requires macOS 14+, which is the target.

- [ ] **Step 3: Commit**

```bash
git add Sources/Quickey/UI/AppPickerPopover.swift
git commit -m "feat: add AppPickerPopover — searchable app list with keyboard nav"
```

---

### Task 6: Rewrite ShortcutsTabView with new layout

**Files:**
- Modify: `Sources/Quickey/UI/ShortcutsTabView.swift`

This is a full rewrite of the view body. Key changes:
- PermissionStatusBanner replaces inline permission row
- CardView("New Shortcut") wraps choose app + recorder + Add button (no Bundle ID field)
- CardView("Shortcuts") wraps LazyVStack with alternating rows, app icons, toggle, ✕ delete
- Popover for app picker triggered by state boolean

- [ ] **Step 1: Rewrite ShortcutsTabView.swift**

```swift
import SwiftUI

struct ShortcutsTabView: View {
    @Bindable var editor: ShortcutEditorState
    var preferences: AppPreferences
    var appListProvider: AppListProvider

    @State private var showingAppPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionStatusBanner(
                granted: preferences.accessibilityGranted,
                onRefresh: { preferences.refreshPermissions() }
            )

            // New Shortcut card
            CardView("New Shortcut") {
                VStack(alignment: .leading, spacing: 10) {
                    // App chooser row
                    HStack(spacing: 10) {
                        Button {
                            showingAppPicker = true
                        } label: {
                            HStack(spacing: 4) {
                                Text("Choose App")
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                        }
                        .popover(isPresented: $showingAppPicker, arrowEdge: .bottom) {
                            AppPickerPopover(
                                appListProvider: appListProvider,
                                onSelect: { entry in
                                    editor.selectedAppName = entry.name
                                    editor.selectedBundleIdentifier = entry.bundleIdentifier
                                },
                                onBrowse: { editor.chooseApplication() }
                            )
                        }

                        if !editor.selectedAppName.isEmpty {
                            HStack(spacing: 6) {
                                AppIconView(bundleIdentifier: editor.selectedBundleIdentifier, size: 20)
                                Text(editor.selectedAppName)
                                    .font(.system(size: 13, weight: .medium))
                            }
                        } else {
                            Text("No app selected")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    // Recorder + Clear + Add
                    HStack(spacing: 10) {
                        ShortcutRecorderView(
                            recordedShortcut: $editor.recordedShortcut,
                            isRecording: $editor.isRecordingShortcut
                        )
                        .frame(height: 28)

                        if let recordedShortcut = editor.recordedShortcut {
                            ShortcutLabel(displayText: recordedShortcut.displayText, isHyper: recordedShortcut.isHyper)
                        } else if editor.isRecordingShortcut {
                            Text("Listening…")
                                .foregroundStyle(.secondary)
                        }

                        Button("Clear") {
                            editor.clearRecordedShortcut()
                        }
                        .disabled(editor.recordedShortcut == nil && !editor.isRecordingShortcut)

                        Spacer()

                        Button("Add") {
                            editor.addShortcut()
                        }
                        .disabled(editor.selectedBundleIdentifier.isEmpty || editor.recordedShortcut == nil)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(14)
            }

            if let conflictMessage = editor.conflictMessage {
                Text(conflictMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Shortcuts list card
            CardView("Shortcuts") {
                if editor.shortcuts.isEmpty {
                    Text("No shortcuts configured")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(editor.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                                shortcutRow(shortcut, index: index)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ shortcut: AppShortcut, index: Int) -> some View {
        HStack(spacing: 10) {
            AppIconView(bundleIdentifier: shortcut.bundleIdentifier, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(shortcut.appName)
                    .font(.system(size: 13, weight: .medium))
                Text(shortcut.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(editor.usageCounts[shortcut.id, default: 0])× past 7 days")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            ShortcutLabel(displayText: shortcut.displayText, isHyper: shortcut.isHyper)

            Toggle("", isOn: Binding(
                get: { shortcut.isEnabled },
                set: { _ in editor.toggleShortcutEnabled(id: shortcut.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            Button {
                editor.removeShortcut(id: shortcut.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .alternatingRowBackground(index: index)
        .opacity(shortcut.isEnabled ? 1.0 : 0.5)
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1 | tail -10`
Expected: Build error — `ShortcutsTabView` now requires `appListProvider` parameter. This will be fixed in the wiring task (Task 10).

For now, verify the view file itself compiles by checking only for syntax errors. We'll fix the call site in Task 10.

- [ ] **Step 3: Commit (WIP — call site update pending)**

```bash
git add Sources/Quickey/UI/ShortcutsTabView.swift
git commit -m "feat: rewrite ShortcutsTabView with card layout, app icons, toggle, alternating rows"
```

---

### Task 7: Rewrite GeneralTabView with card layout + master toggle

**Files:**
- Modify: `Sources/Quickey/UI/GeneralTabView.swift`

- [ ] **Step 1: Rewrite GeneralTabView.swift**

```swift
import SwiftUI

struct GeneralTabView: View {
    var preferences: AppPreferences
    var editor: ShortcutEditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Startup card
            CardView("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { preferences.launchAtLoginEnabled },
                    set: { preferences.setLaunchAtLogin($0) }
                ))
                .padding(14)
            }

            // Keyboard card
            CardView("Keyboard") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable All Shortcuts", isOn: Binding(
                        get: { editor.allEnabled },
                        set: { editor.setAllEnabled($0) }
                    ))

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Toggle("Enable Hyper Key", isOn: Binding(
                                get: { preferences.hyperKeyEnabled },
                                set: { preferences.setHyperKeyEnabled($0) }
                            ))
                            Text("Caps Lock → ⌃⌥⇧⌘")
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.secondary)
                        }
                        Text("按住 Caps Lock 再按其他键，等同于 ⌃⌥⇧⌘ 组合。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                }
                .padding(14)
            }

            Spacer()

            // About card
            CardView {
                HStack {
                    Spacer()
                    Text("Quickey")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(10)
            }
        }
    }
}
```

- [ ] **Step 2: Commit (call site update pending in Task 10)**

```bash
git add Sources/Quickey/UI/GeneralTabView.swift
git commit -m "feat: rewrite GeneralTabView with card layout and master enable toggle"
```

---

### Task 8: Rewrite InsightsTabView ranking list with cards + icons + mini bars

**Files:**
- Modify: `Sources/Quickey/UI/InsightsTabView.swift`

- [ ] **Step 1: Rewrite InsightsTabView.swift**

```swift
import SwiftUI

struct InsightsTabView: View {
    @Bindable var viewModel: InsightsViewModel

    var body: some View {
        VStack(spacing: 20) {
            // Period picker
            Picker("", selection: $viewModel.period) {
                ForEach(InsightsPeriod.allCases, id: \.self) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            // Headline
            VStack(spacing: 4) {
                Text(viewModel.period.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(viewModel.totalCount)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Text("app switches")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Trend chart (week/month only)
            if viewModel.period != .day {
                if viewModel.bars.allSatisfy({ $0.count == 0 }) {
                    Text("No usage data yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(height: 120)
                } else {
                    BarChartView(bars: viewModel.bars)
                        .frame(height: 120)
                }
            }

            // Ranking
            if viewModel.ranking.isEmpty {
                Spacer()
                Text("No shortcuts used in this period")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                CardView("Top Apps") {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.ranking.enumerated()), id: \.element.id) { index, item in
                            rankingRow(item, index: index)
                        }
                    }
                }
            }
        }
        .task { await viewModel.refresh() }
    }

    @ViewBuilder
    private func rankingRow(_ item: RankedShortcut, index: Int) -> some View {
        let maxCount = viewModel.ranking.first?.count ?? 1

        HStack(spacing: 10) {
            // Rank circle
            Text("\(item.rank)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(item.rank == 1 ? Color(red: 1, green: 0.84, blue: 0.04) : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    item.rank == 1
                        ? Color(red: 1, green: 0.84, blue: 0.04).opacity(0.15)
                        : Color.secondary.opacity(0.08)
                )
                .clipShape(Circle())

            AppIconView(bundleIdentifier: item.appName, size: 20)

            Text(item.appName)
                .font(.system(size: 13))

            Spacer()

            // Mini progress bar
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 60, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 60 * CGFloat(item.count) / CGFloat(max(maxCount, 1)), height: 4)
            }

            Text("\(item.count)×")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .alternatingRowBackground(index: index)
    }
}
```

**Note:** The `AppIconView` in ranking uses `item.appName` as bundleIdentifier — this is wrong. `RankedShortcut` only has `appName`, not `bundleIdentifier`. We need to add `bundleIdentifier` to `RankedShortcut`. See Step 2.

- [ ] **Step 2: Add bundleIdentifier to RankedShortcut**

In `Sources/Quickey/UI/InsightsViewModel.swift`, update:

```swift
struct RankedShortcut: Identifiable {
    let id: UUID
    let appName: String
    let bundleIdentifier: String
    let count: Int
    let rank: Int
}
```

And update the `refresh()` method's ranking construction:

Change:
```swift
ranked.append(RankedShortcut(id: id, appName: shortcut.appName, count: count, rank: 0))
```
to:
```swift
ranked.append(RankedShortcut(id: id, appName: shortcut.appName, bundleIdentifier: shortcut.bundleIdentifier, count: count, rank: 0))
```

And:
```swift
ranking = ranked.enumerated().map {
    RankedShortcut(id: $1.id, appName: $1.appName, count: $1.count, rank: $0 + 1)
}
```
to:
```swift
ranking = ranked.enumerated().map {
    RankedShortcut(id: $1.id, appName: $1.appName, bundleIdentifier: $1.bundleIdentifier, count: $1.count, rank: $0 + 1)
}
```

Then fix InsightsTabView to use `item.bundleIdentifier`:
```swift
AppIconView(bundleIdentifier: item.bundleIdentifier, size: 20)
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Quickey/UI/InsightsTabView.swift Sources/Quickey/UI/InsightsViewModel.swift
git commit -m "feat: rewrite InsightsTabView with card ranking, app icons, mini progress bars"
```

---

### Task 9: Wire everything together — SettingsView, SettingsWindowController, AppController

**Files:**
- Modify: `Sources/Quickey/UI/SettingsView.swift`
- Modify: `Sources/Quickey/UI/SettingsWindowController.swift`
- Modify: `Sources/Quickey/AppController.swift`

- [ ] **Step 1: Update SettingsView to pass new dependencies**

```swift
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case shortcuts = "Shortcuts"
    case general = "General"
    case insights = "Insights"
}

struct SettingsView: View {
    var editor: ShortcutEditorState
    var preferences: AppPreferences
    var insightsViewModel: InsightsViewModel
    var appListProvider: AppListProvider
    @State private var selectedTab: SettingsTab = .shortcuts

    var body: some View {
        VStack(spacing: 16) {
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case .shortcuts:
                ShortcutsTabView(editor: editor, preferences: preferences, appListProvider: appListProvider)
            case .general:
                GeneralTabView(preferences: preferences, editor: editor)
            case .insights:
                InsightsTabView(viewModel: insightsViewModel)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .insights {
                Task { await insightsViewModel.refresh() }
            }
        }
        .onAppear {
            preferences.refreshPermissions()
        }
    }
}
```

- [ ] **Step 2: Update SettingsWindowController to create AppListProvider**

In `Sources/Quickey/UI/SettingsWindowController.swift`, update `show()`:

```swift
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let shortcutStore: ShortcutStore
    private let shortcutManager: ShortcutManager
    private let usageTracker: UsageTracker?
    private let hyperKeyService: HyperKeyService?
    private var window: NSWindow?

    init(shortcutStore: ShortcutStore, shortcutManager: ShortcutManager, usageTracker: UsageTracker? = nil, hyperKeyService: HyperKeyService? = nil) {
        self.shortcutStore = shortcutStore
        self.shortcutManager = shortcutManager
        self.usageTracker = usageTracker
        self.hyperKeyService = hyperKeyService
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let editor = ShortcutEditorState(shortcutStore: shortcutStore, shortcutManager: shortcutManager, usageTracker: usageTracker)
        let preferences = AppPreferences(shortcutManager: shortcutManager, hyperKeyService: hyperKeyService)
        let insightsViewModel = InsightsViewModel(usageTracker: usageTracker, shortcutStore: shortcutStore)
        let appListProvider = AppListProvider()
        let contentView = SettingsView(editor: editor, preferences: preferences, insightsViewModel: insightsViewModel, appListProvider: appListProvider)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Quickey"
        window.setContentSize(NSSize(width: 720, height: 480))
        window.styleMask.insert(.titled)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 3: Build the full project**

Run: `swift build 2>&1 | tail -20`
Expected: Build succeeded. All call sites now pass the required parameters.

- [ ] **Step 4: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Quickey/UI/SettingsView.swift Sources/Quickey/UI/SettingsWindowController.swift
git commit -m "feat: wire AppListProvider through SettingsView and SettingsWindowController"
```

---

### Task 10: Manual smoke test + fix compilation issues

**Files:** Any files that have compilation issues from the previous tasks.

This task is a catch-all for integration. The previous tasks were designed to compile individually, but cross-task dependencies may surface here.

- [ ] **Step 1: Full build**

Run: `swift build 2>&1`
Fix any compilation errors.

- [ ] **Step 2: Run all tests**

Run: `swift test 2>&1`
Fix any test failures.

- [ ] **Step 3: Visual verification checklist (manual)**

Open the app (`swift build && .build/debug/Quickey`) and verify:

- [ ] ShortcutsTab: Permission banner shows green/orange correctly
- [ ] ShortcutsTab: "Choose App ▾" opens popover with search + app list
- [ ] ShortcutsTab: Search filters apps by name and bundle ID
- [ ] ShortcutsTab: ↑↓ keyboard nav works in popover
- [ ] ShortcutsTab: Selecting app populates name, popover closes
- [ ] ShortcutsTab: "Browse..." opens NSOpenPanel fallback
- [ ] ShortcutsTab: Shortcut list shows app icons, alternating rows
- [ ] ShortcutsTab: Toggle enables/disables individual shortcuts
- [ ] ShortcutsTab: Disabled shortcut row has reduced opacity
- [ ] ShortcutsTab: ✕ delete button works
- [ ] GeneralTab: Three cards (Startup / Keyboard / About)
- [ ] GeneralTab: Master "Enable All Shortcuts" toggle works
- [ ] GeneralTab: Hyper Key toggle with monospace badge
- [ ] InsightsTab: Ranking list in card with alternating rows
- [ ] InsightsTab: Rank circles (#1 gold, others gray)
- [ ] InsightsTab: App icons in ranking rows
- [ ] InsightsTab: Mini progress bars proportional to top app
- [ ] Cross-tab: Cards have consistent styling
- [ ] Dark mode: All elements adapt correctly
- [ ] Light mode: All elements adapt correctly

- [ ] **Step 4: Final commit if any fixes were needed**

```bash
git add -u
git commit -m "fix: resolve integration issues from UI overhaul"
```
