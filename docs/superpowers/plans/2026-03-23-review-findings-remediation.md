# Review Findings Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the three accepted 2026-03-23 review findings so Insights uses a single time window per refresh, launch-at-login approval states are modeled truthfully, and file-backed diagnostics are safe under concurrent logging.

**Architecture:** Keep the existing AppKit-first structure and make the smallest changes that restore truthful system-state modeling and deterministic analytics. Prefer narrow seams over broad refactors: add date-aware usage-query APIs for snapshot consistency, add an explicit approval-pending action model instead of negating a bool, and isolate synchronized file logging behind a small writer type that can be unit-tested.

**Tech Stack:** Swift 6, macOS 14+, SPM, Swift Testing, AppKit, SwiftUI Observation, ServiceManagement, Foundation, SQLite

**Inputs:** 2026-03-23 review findings for `InsightsViewModel`, `LaunchAtLoginService`, and `DiagnosticLog`; Apple documentation for `SMAppService.Status.requiresApproval` and `NSWorkspace.openApplication`

---

### Task 1: Make each Insights refresh use one anchor date

**Files:**
- Modify: `Sources/Quickey/Protocols/UsageTracking.swift`
- Modify: `Sources/Quickey/Services/UsageTracker.swift`
- Modify: `Sources/Quickey/UI/InsightsViewModel.swift`
- Modify: `Tests/QuickeyTests/InsightsViewModelTests.swift`
- Test: `Tests/QuickeyTests/UsageTrackerWindowTests.swift`

- [ ] **Step 1: Add a failing test that proves one refresh must share one anchor**

Extend `Tests/QuickeyTests/InsightsViewModelTests.swift` with a tracker that records the anchor date passed to every usage query:

```swift
actor RecordingUsageTracker: UsageTracking {
    private var anchors: [Date] = []
    let shortcutId: UUID

    init(shortcutId: UUID) {
        self.shortcutId = shortcutId
    }

    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int] {
        anchors.append(now)
        return [shortcutId: 3]
    }

    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]] {
        anchors.append(now)
        return [shortcutId.uuidString: [("2026-03-21", 3)]]
    }

    func totalSwitches(days: Int, relativeTo now: Date) async -> Int {
        anchors.append(now)
        return 3
    }

    func recordedAnchors() -> [Date] { anchors }
}
```

Add a focused test:

```swift
@Test @MainActor
func refreshUsesOneAnchorDateForAllQueriesAndBars() async {
    let shortcutId = UUID()
    let store = ShortcutStore()
    store.replaceAll(with: [
        AppShortcut(
            id: shortcutId,
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t",
            modifierFlags: ["command"]
        )
    ])

    let tracker = RecordingUsageTracker(shortcutId: shortcutId)
    let viewModel = InsightsViewModel(usageTracker: tracker, shortcutStore: store)
    let anchor = isoDate("2026-03-21")

    await viewModel.refresh(for: .week, relativeTo: anchor)

    let anchors = await tracker.recordedAnchors()
    #expect(anchors.count == 3)
    #expect(anchors.allSatisfy { $0 == anchor })
    #expect(viewModel.bars.first?.id == "2026-03-15")
    #expect(viewModel.bars.last?.id == "2026-03-21")
}
```

- [ ] **Step 2: Run the focused Insights tests and verify the new test fails**

Run:

```bash
swift test --filter InsightsViewModelTests
```

Expected: FAIL because `InsightsViewModel` currently hard-codes `Date()` inside `refresh(for:)` and `buildBars(...)`.

- [ ] **Step 3: Add date-aware usage APIs and thread one anchor through the whole refresh**

In `Sources/Quickey/Protocols/UsageTracking.swift`, add explicit date-aware requirements and keep convenience overloads in a protocol extension:

```swift
protocol UsageTracking: Sendable {
    func usageCounts(days: Int, relativeTo now: Date) async -> [UUID: Int]
    func dailyCounts(days: Int, relativeTo now: Date) async -> [String: [(date: String, count: Int)]]
    func totalSwitches(days: Int, relativeTo now: Date) async -> Int
}

extension UsageTracking {
    func usageCounts(days: Int) async -> [UUID: Int] {
        await usageCounts(days: days, relativeTo: Date())
    }
}
```

In `Sources/Quickey/Services/UsageTracker.swift`, make the actor conform to those date-aware overloads and keep the existing window-boundary helpers as the single source of truth.

In `Sources/Quickey/UI/InsightsViewModel.swift`, add:

```swift
func refresh(for period: InsightsPeriod, relativeTo now: Date) async

private func buildBars(
    rawDaily: [String: [(date: String, count: Int)]],
    days: Int,
    relativeTo now: Date
) -> [DailyBar]
```

Then change the production path to capture one date:

```swift
func refresh(for period: InsightsPeriod) async {
    await refresh(for: period, relativeTo: Date())
}
```

Inside the new overload, pass the same `now` to:
- `usageTracker.totalSwitches(days:relativeTo:)`
- `usageTracker.dailyCounts(days:relativeTo:)`
- `usageTracker.usageCounts(days:relativeTo:)`
- `buildBars(..., relativeTo: now)`

- [ ] **Step 4: Re-run the focused Insights and usage-window tests**

Run:

```bash
swift test --filter InsightsViewModelTests
swift test --filter UsageTrackerWindowTests
```

Expected: PASS.

- [ ] **Step 5: Re-run the full analytics-related coverage**

Run:

```bash
swift test --filter UsageTracker
```

Expected: PASS, including the existing date-window tests and overlap-refresh test.

- [ ] **Step 6: Commit**

```bash
git add Sources/Quickey/Protocols/UsageTracking.swift \
  Sources/Quickey/Services/UsageTracker.swift \
  Sources/Quickey/UI/InsightsViewModel.swift \
  Tests/QuickeyTests/InsightsViewModelTests.swift \
  Tests/QuickeyTests/UsageTrackerWindowTests.swift
git commit -m "Fix insights refresh anchor consistency"
```

---

### Task 2: Model launch-at-login approval as a distinct user-visible state

**Files:**
- Modify: `Sources/Quickey/Services/LaunchAtLoginService.swift`
- Modify: `Sources/Quickey/Services/AppPreferences.swift`
- Modify: `Sources/Quickey/UI/GeneralTabView.swift`
- Modify: `Sources/Quickey/UI/MenuBarController.swift`
- Modify: `Tests/QuickeyTests/LaunchAtLoginServiceTests.swift`

- [ ] **Step 1: Add failing tests for pending-approval behavior**

Extend `Tests/QuickeyTests/LaunchAtLoginServiceTests.swift` so it covers not just status mapping, but action semantics:

```swift
@Test
func requiresApprovalIsNotTreatedAsFullyEnabled() {
    #expect(LaunchAtLoginStatus.requiresApproval.isEnabled == false)
}

@Test
func requiresApprovalPrimaryActionOpensSettings() {
    #expect(LaunchAtLoginStatus.requiresApproval.primaryAction == .openSystemSettings)
}

@Test
func enabledPrimaryActionDisablesService() {
    #expect(LaunchAtLoginStatus.enabled.primaryAction == .disable)
}

@Test
func disabledPrimaryActionEnablesService() {
    #expect(LaunchAtLoginStatus.disabled.primaryAction == .enable)
}
```

Add a small action enum in production code that both the preferences layer and the menu controller can use:

```swift
enum LaunchAtLoginPrimaryAction: Equatable {
    case enable
    case disable
    case openSystemSettings
}
```

- [ ] **Step 2: Run the focused launch-at-login tests and verify failure**

Run:

```bash
swift test --filter LaunchAtLoginServiceTests
```

Expected: FAIL because `requiresApproval` is currently collapsed into `isEnabled == true` and there is no action model.

- [ ] **Step 3: Narrow `isEnabled` and add an explicit action model**

In `Sources/Quickey/Services/LaunchAtLoginService.swift`:
- Change `LaunchAtLoginStatus.isEnabled` so it returns `true` only for `.enabled`
- Add:

```swift
var requiresApproval: Bool { self == .requiresApproval }

var primaryAction: LaunchAtLoginPrimaryAction {
    switch self {
    case .enabled:
        .disable
    case .disabled:
        .enable
    case .requiresApproval, .notFound:
        .openSystemSettings
    }
}
```

This keeps “registered but not runnable” distinct from “actually launches at login”.

- [ ] **Step 4: Update the app-level presentation logic to stop negating a bool**

In `Sources/Quickey/Services/AppPreferences.swift`, expose helpers derived from `launchAtLoginStatus` instead of using `launchAtLoginEnabled` as the only source of truth:

```swift
var launchAtLoginRequiresApproval: Bool {
    launchAtLoginStatus.requiresApproval
}

func performLaunchAtLoginPrimaryAction() {
    switch launchAtLoginStatus.primaryAction {
    case .enable:
        launchAtLoginService.setEnabled(true)
        refreshLaunchAtLoginStatus()
    case .disable:
        launchAtLoginService.setEnabled(false)
        refreshLaunchAtLoginStatus()
    case .openSystemSettings:
        openLoginItemsSettings()
    }
}
```

In `Sources/Quickey/UI/GeneralTabView.swift`, stop driving the approval-pending state through a plain toggle alone. Keep the toggle for true on/off, but add explicit pending/not-found affordances:

```swift
if preferences.launchAtLoginStatus == .requiresApproval {
    Text("Quickey is registered, but macOS still needs approval in Login Items.")
    Button("Open Login Items Settings") {
        preferences.openLoginItemsSettings()
    }
}

if preferences.launchAtLoginStatus == .notFound {
    Text("Quickey could not find a login item in the packaged app.")
}
```

Use `performLaunchAtLoginPrimaryAction()` anywhere a single “primary” user action is needed.

In `Sources/Quickey/UI/MenuBarController.swift`, replace:

```swift
let newState = !launchAtLoginService.isEnabled
launchAtLoginService.setEnabled(newState)
```

with a status switch:

```swift
switch launchAtLoginService.status.primaryAction {
case .enable:
    launchAtLoginService.setEnabled(true)
case .disable:
    launchAtLoginService.setEnabled(false)
case .openSystemSettings:
    launchAtLoginService.openSystemSettingsLoginItems()
}
```

- [ ] **Step 5: Re-run the focused launch-at-login tests**

Run:

```bash
swift test --filter LaunchAtLoginServiceTests
```

Expected: PASS.

- [ ] **Step 6: Re-run the full suite before macOS validation**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 7: Perform targeted macOS validation for approval flow**

On a real macOS machine:

1. Package and launch the app bundle with `open`, not by executing the binary directly.
2. Start from a state where Launch at Login is disabled.
3. Enable Launch at Login.
4. If macOS reports approval is still required, confirm:
   - General tab shows an approval-needed explanation
   - “Open Login Items Settings” opens System Settings
   - The menu bar item does not silently unregister the login item when the state is pending approval
5. After approving in System Settings, confirm the state refreshes to `.enabled`.

Document any macOS-only surprises in `docs/handoff-notes.md` after validation.

- [ ] **Step 8: Commit**

```bash
git add Sources/Quickey/Services/LaunchAtLoginService.swift \
  Sources/Quickey/Services/AppPreferences.swift \
  Sources/Quickey/UI/GeneralTabView.swift \
  Sources/Quickey/UI/MenuBarController.swift \
  Tests/QuickeyTests/LaunchAtLoginServiceTests.swift
git commit -m "Fix launch at login approval state handling"
```

---

### Task 3: Serialize file-backed diagnostic logging

**Files:**
- Create: `Sources/Quickey/Services/DiagnosticLogWriter.swift`
- Modify: `Sources/Quickey/Services/DiagnosticLog.swift`
- Create: `Tests/QuickeyTests/DiagnosticLogTests.swift`

- [ ] **Step 1: Add a failing concurrency test around file appends**

Create `Tests/QuickeyTests/DiagnosticLogTests.swift` around a testable writer type, not the hard-coded global singleton:

```swift
import Foundation
import Testing
@testable import Quickey

@Test
func concurrentWritesProduceOneLinePerMessage() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("debug.log")
    let writer = DiagnosticLogWriter(fileURL: fileURL)

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<100 {
            group.addTask {
                writer.log("message-\(index)")
            }
        }
    }

    let contents = try String(contentsOf: fileURL)
    let lines = contents.split(separator: "\n")
    #expect(lines.count == 100)
    #expect(lines.contains { $0.contains("message-0") })
    #expect(lines.contains { $0.contains("message-99") })
}
```

- [ ] **Step 2: Run the focused diagnostic-log test and verify failure**

Run:

```bash
swift test --filter DiagnosticLogTests
```

Expected: FAIL because there is no isolated writer type yet and the current implementation writes with unsynchronized seek-and-append calls.

- [ ] **Step 3: Introduce a small synchronized writer and route `DiagnosticLog` through it**

Create `Sources/Quickey/Services/DiagnosticLogWriter.swift`:

```swift
import Foundation

final class DiagnosticLogWriter: @unchecked Sendable {
    private let fileURL: URL
    private let queue: DispatchQueue
    private let formatter: ISO8601DateFormatter
    private let maxFileSize: UInt64
    private var directoryEnsured = false

    init(
        fileURL: URL,
        queue: DispatchQueue = DispatchQueue(label: "com.quickey.diagnostic-log"),
        formatter: ISO8601DateFormatter = ISO8601DateFormatter(),
        maxFileSize: UInt64 = 512 * 1024
    ) {
        self.fileURL = fileURL
        self.queue = queue
        self.formatter = formatter
        self.maxFileSize = maxFileSize
    }

    func log(_ message: String) {
        queue.sync {
            // ensure directory, append one complete line, never interleave writes
        }
    }

    func rotateIfNeeded() {
        queue.sync {
            // same rotation logic, serialized with writes
        }
    }
}
```

Then simplify `Sources/Quickey/Services/DiagnosticLog.swift` into a facade:

```swift
enum DiagnosticLog: Sendable {
    static let subsystem = "com.quickey.app"
    private static let writer = DiagnosticLogWriter(fileURL: ...)

    static func log(_ message: String) { writer.log(message) }
    static func rotateIfNeeded() { writer.rotateIfNeeded() }
    static func logFileURL() -> URL { ... }
}
```

This keeps all file I/O serialized and gives tests a dedicated entry point.

- [ ] **Step 4: Re-run the focused diagnostic-log tests**

Run:

```bash
swift test --filter DiagnosticLogTests
```

Expected: PASS.

- [ ] **Step 5: Re-run the full suite**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Quickey/Services/DiagnosticLogWriter.swift \
  Sources/Quickey/Services/DiagnosticLog.swift \
  Tests/QuickeyTests/DiagnosticLogTests.swift
git commit -m "Serialize diagnostic log writes"
```

---

### Task 4: Final verification and handoff cleanup

**Files:**
- Modify: `docs/handoff-notes.md` (only if macOS validation is completed during this work)

- [ ] **Step 1: Run the full build-and-test pass**

Run:

```bash
swift build
swift test
swift build -c release
```

Expected: PASS.

- [ ] **Step 2: Package the app for real-macOS validation**

Run:

```bash
./scripts/package-app.sh
cp .build/release/Quickey build/Quickey.app/Contents/MacOS/Quickey
open build/Quickey.app
```

Expected: packaged app launches as an accessory/menu bar app.

- [ ] **Step 3: Re-run targeted macOS checks**

Verify on macOS:

1. Insights week/month charts and totals still match after rapidly switching tabs or waiting across a date boundary test setup.
2. Launch-at-login approval flow behaves as described in Task 2.
3. Diagnostic log still records launch/toggle/error messages, and no truncated/merged lines appear while provoking multiple logs quickly.

- [ ] **Step 4: Update handoff notes if validation completed**

If the macOS validation above is actually performed during this work, append the concrete result and date to `docs/handoff-notes.md`. If not performed, leave the note accurate by explicitly stating validation is still pending.

- [ ] **Step 5: Final commit (optional squashed handoff commit if desired by reviewer)**

```bash
git status --short
```

If the branch is meant to keep per-task commits, stop here. If the reviewer asks for a final consolidation commit, make it only after review.
