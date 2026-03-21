# Code Review Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the highest-confidence correctness and platform-integration issues found in the 2026-03-21 code review without broad refactors.

**Architecture:** Keep the current AppKit-first structure, but replace misleading bool-only state with small, testable status models where platform APIs have richer semantics. Fix correctness in three layers: analytics math, async refresh ordering, and runtime/platform state reporting for permissions, event taps, login items, and Hyper Key shell execution.

**Tech Stack:** Swift 6, macOS 14+, SPM, Swift Testing, AppKit, SwiftUI Observation, ServiceManagement, CoreGraphics/ApplicationServices, SQLite

**Inputs:** Review findings from 2026-03-21, GitHub issues `#60`, `#61`, `#62`, `#63`

---

### Task 1: Fix UsageTracker inclusive window math

**Files:**
- Modify: `Sources/Quickey/Services/UsageTracker.swift`
- Create: `Tests/QuickeyTests/UsageTrackerWindowTests.swift`

- [ ] **Step 1: Add failing boundary tests for 1/7/30-day windows**

Create `Tests/QuickeyTests/UsageTrackerWindowTests.swift` with focused date-window tests. Use `@testable import Quickey`.

```swift
import Foundation
import Testing
@testable import Quickey

@Suite("UsageTracker window boundaries")
struct UsageTrackerWindowTests {
    @Test
    func oneDayWindowIncludesTodayOnly() async {
        let tracker = UsageTracker(databasePath: ":memory:")
        let id = UUID()
        let today = isoDate("2026-03-21")
        let yesterday = isoDate("2026-03-20")

        await tracker.recordUsage(shortcutId: id, on: yesterday)
        await tracker.recordUsage(shortcutId: id, on: today)

        let counts = await tracker.usageCounts(days: 1, relativeTo: today)
        #expect(counts[id] == 1)
    }

    @Test
    func sevenDayWindowIncludesTodayPlusPreviousSixDays() async {
        let tracker = UsageTracker(databasePath: ":memory:")
        let id = UUID()
        let today = isoDate("2026-03-21")
        let eighthDayBack = isoDate("2026-03-13")

        await tracker.recordUsage(shortcutId: id, on: eighthDayBack)
        let total = await tracker.totalSwitches(days: 7, relativeTo: today)
        #expect(total == 0)
    }
}
```

Add a private test helper in the same file:

```swift
private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: "\(value)T12:00:00Z")!
}
```

- [ ] **Step 2: Run tests to verify the current implementation fails**

Run:

```bash
swift test --filter UsageTrackerWindowTests
```

Expected: at least the 1-day and 7-day assertions fail because the current cutoff is `today - days`.

- [ ] **Step 3: Add date-aware test seams and fix the cutoff helper**

In `Sources/Quickey/Services/UsageTracker.swift`, add internal overloads that tests can call directly:

```swift
func recordUsage(shortcutId: UUID, on date: Date)
func usageCounts(days: Int, relativeTo now: Date) -> [UUID: Int]
func dailyCounts(days: Int, relativeTo now: Date) -> [String: [(date: String, count: Int)]]
func totalSwitches(days: Int, relativeTo now: Date) -> Int
```

Refactor the cutoff logic into one helper:

```swift
private func windowStartString(days: Int, relativeTo now: Date) -> String {
    let clampedDays = max(days, 1)
    let start = Calendar.current.date(byAdding: .day, value: -(clampedDays - 1), to: now) ?? now
    return Self.dateFormatter.string(from: start)
}
```

Then make the existing public methods delegate to the date-aware overloads using `Date()`.

- [ ] **Step 4: Re-run the focused window tests**

Run:

```bash
swift test --filter UsageTrackerWindowTests
```

Expected: PASS.

- [ ] **Step 5: Re-run the full UsageTracker coverage**

Run:

```bash
swift test --filter UsageTracker
```

Expected: all existing UsageTracker tests plus the new boundary tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Quickey/Services/UsageTracker.swift \
  Tests/QuickeyTests/UsageTrackerWindowTests.swift
git commit -m "Fix insights date window boundaries"
```

---

### Task 2: Make Insights refresh last-selection-wins

**Files:**
- Create: `Sources/Quickey/Protocols/UsageTracking.swift`
- Modify: `Sources/Quickey/Services/UsageTracker.swift`
- Modify: `Sources/Quickey/UI/InsightsViewModel.swift`
- Modify: `Sources/Quickey/UI/SettingsView.swift`
- Modify: `Sources/Quickey/UI/InsightsTabView.swift`
- Create: `Tests/QuickeyTests/InsightsViewModelTests.swift`

- [ ] **Step 1: Add a protocol seam for InsightsViewModel**

Create `Sources/Quickey/Protocols/UsageTracking.swift`:

```swift
import Foundation

protocol UsageTracking: Sendable {
    func usageCounts(days: Int) async -> [UUID: Int]
    func dailyCounts(days: Int) async -> [String: [(date: String, count: Int)]]
    func totalSwitches(days: Int) async -> Int
}
```

In `Sources/Quickey/Services/UsageTracker.swift`, conform `UsageTracker` to `UsageTracking`.

- [ ] **Step 2: Add a failing overlap test**

Create `Tests/QuickeyTests/InsightsViewModelTests.swift` with a fake delayed tracker:

```swift
import Foundation
import Testing
@testable import Quickey

actor DelayedUsageTracker: UsageTracking {
    func usageCounts(days: Int) async -> [UUID: Int] {
        try? await Task.sleep(for: .milliseconds(days == 30 ? 80 : 5))
        return [:]
    }

    func dailyCounts(days: Int) async -> [String: [(date: String, count: Int)]] {
        try? await Task.sleep(for: .milliseconds(days == 30 ? 80 : 5))
        return [:]
    }

    func totalSwitches(days: Int) async -> Int {
        try? await Task.sleep(for: .milliseconds(days == 30 ? 80 : 5))
        return days
    }
}

@Test @MainActor
func latestPeriodWinsWhenRefreshesOverlap() async {
    let store = ShortcutStore()
    let viewModel = InsightsViewModel(usageTracker: DelayedUsageTracker(), shortcutStore: store)

    viewModel.period = .month
    viewModel.period = .day

    try? await Task.sleep(for: .milliseconds(150))

    #expect(viewModel.period == .day)
    #expect(viewModel.totalCount == 1)
}
```

- [ ] **Step 3: Run the new test and verify it fails**

Run:

```bash
swift test --filter latestPeriodWinsWhenRefreshesOverlap
```

Expected: FAIL because the slower `.month` request can overwrite the later `.day` selection.

- [ ] **Step 4: Serialize refresh scheduling in InsightsViewModel**

In `Sources/Quickey/UI/InsightsViewModel.swift`:
- Change the dependency type from `UsageTracker?` to `(any UsageTracking)?`
- Add a cancellable task property:

```swift
private var refreshTask: Task<Void, Never>?
```

- Replace `didSet { Task { await refresh() } }` with a scheduler:

```swift
var period: InsightsPeriod = .week {
    didSet { scheduleRefresh() }
}

func scheduleRefresh() {
    refreshTask?.cancel()
    let selectedPeriod = period
    refreshTask = Task { [weak self] in
        await self?.refresh(for: selectedPeriod)
    }
}
```

- Add:

```swift
func refresh(for period: InsightsPeriod) async
```

Inside `refresh(for:)`, capture `period.days` up front, load all async data, then guard cancellation before applying results:

```swift
guard !Task.isCancelled else { return }
guard self.period == period else { return }
```

- [ ] **Step 5: Update view call sites to use the scheduler**

In `Sources/Quickey/UI/SettingsView.swift`, replace:

```swift
Task { await insightsViewModel.refresh() }
```

with:

```swift
insightsViewModel.scheduleRefresh()
```

In `Sources/Quickey/UI/InsightsTabView.swift`, replace:

```swift
.task { await viewModel.refresh() }
```

with:

```swift
.task { viewModel.scheduleRefresh() }
```

- [ ] **Step 6: Re-run the overlap test**

Run:

```bash
swift test --filter latestPeriodWinsWhenRefreshesOverlap
```

Expected: PASS.

- [ ] **Step 7: Re-run the full Insights-related tests**

Run:

```bash
swift test --filter Insights
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/Quickey/Protocols/UsageTracking.swift \
  Sources/Quickey/Services/UsageTracker.swift \
  Sources/Quickey/UI/InsightsViewModel.swift \
  Sources/Quickey/UI/SettingsView.swift \
  Sources/Quickey/UI/InsightsTabView.swift \
  Tests/QuickeyTests/InsightsViewModelTests.swift
git commit -m "Serialize insights refreshes by period selection"
```

---

### Task 3: Surface launch-at-login approval states instead of a bool

**Files:**
- Modify: `Sources/Quickey/Services/LaunchAtLoginService.swift`
- Modify: `Sources/Quickey/Services/AppPreferences.swift`
- Modify: `Sources/Quickey/UI/GeneralTabView.swift`
- Modify: `Sources/Quickey/UI/MenuBarController.swift`
- Create: `Tests/QuickeyTests/LaunchAtLoginServiceTests.swift`

- [ ] **Step 1: Add a richer status model**

In `Sources/Quickey/Services/LaunchAtLoginService.swift`, add:

```swift
enum LaunchAtLoginStatus: Equatable {
    case enabled
    case requiresApproval
    case disabled
    case notFound
}
```

Replace the bool-only computed property with:

```swift
var status: LaunchAtLoginStatus
var isEnabled: Bool { status == .enabled || status == .requiresApproval }
func openSystemSettingsLoginItems()
```

Map `SMAppService.mainApp.status` like this:

```swift
switch service.status {
case .enabled: .enabled
case .requiresApproval: .requiresApproval
case .notRegistered: .disabled
case .notFound: .notFound
@unknown default: .notFound
}
```

- [ ] **Step 2: Add a focused mapping test**

Create `Tests/QuickeyTests/LaunchAtLoginServiceTests.swift` with an injected wrapper or closures around:
- current `SMAppService.Status`
- `register()`
- `unregister()`
- `SMAppService.openSystemSettingsLoginItems()`

Add at least:

```swift
@Test
func requiresApprovalMapsToApprovalNeededState()

@Test
func isEnabledIsTrueWhenApprovalIsStillPending()
```

- [ ] **Step 3: Run the new tests and verify they fail**

Run:

```bash
swift test --filter LaunchAtLoginServiceTests
```

Expected: FAIL because the current implementation only exposes `Bool`.

- [ ] **Step 4: Update AppPreferences and GeneralTabView**

In `Sources/Quickey/Services/AppPreferences.swift`:
- Add:

```swift
private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .disabled
```

- Initialize and refresh it from `launchAtLoginService.status`
- Keep `launchAtLoginEnabled` only as a UI convenience wrapper if needed

In `Sources/Quickey/UI/GeneralTabView.swift`, keep the toggle, but add status-specific secondary text:

```swift
switch preferences.launchAtLoginStatus {
case .requiresApproval:
    Text("Enabled in app, but still needs approval in System Settings > General > Login Items.")
    Button("Open Login Items Settings") { preferences.openLoginItemsSettings() }
case .notFound:
    Text("Login item could not be found in the packaged app.")
default:
    EmptyView()
}
```

- [ ] **Step 5: Update the menu bar item state**

In `Sources/Quickey/UI/MenuBarController.swift`, use menu item states consistently:
- `.on` for `.enabled`
- `.mixed` for `.requiresApproval`
- `.off` for `.disabled` / `.notFound`

After toggling, refresh from `launchAtLoginService.status` instead of re-reading only `isEnabled`.

- [ ] **Step 6: Re-run the focused tests**

Run:

```bash
swift test --filter LaunchAtLoginServiceTests
```

Expected: PASS.

- [ ] **Step 7: Run a full build/test pass**

Run:

```bash
swift build
swift test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/Quickey/Services/LaunchAtLoginService.swift \
  Sources/Quickey/Services/AppPreferences.swift \
  Sources/Quickey/UI/GeneralTabView.swift \
  Sources/Quickey/UI/MenuBarController.swift \
  Tests/QuickeyTests/LaunchAtLoginServiceTests.swift
git commit -m "Surface login item approval states in the UI"
```

---

### Task 4: Only persist Hyper Key state after hidutil succeeds

**Files:**
- Modify: `Sources/Quickey/Services/HyperKeyService.swift`
- Create: `Tests/QuickeyTests/HyperKeyServiceTests.swift`

- [ ] **Step 1: Add failing state-persistence tests**

Create `Tests/QuickeyTests/HyperKeyServiceTests.swift` with an injected runner seam:

```swift
import Testing
@testable import Quickey

@Test @MainActor
func enableDoesNotPersistWhenHidutilFails() {
    let service = HyperKeyService(
        runner: { _ in false },
        defaults: UserDefaults(suiteName: "HyperKeyServiceTests.enable.failure")!
    )

    service.enable()
    #expect(service.isEnabled == false)
}

@Test @MainActor
func disableDoesNotClearPersistedStateWhenHidutilFails() {
    let defaults = UserDefaults(suiteName: "HyperKeyServiceTests.disable.failure")!
    defaults.set(true, forKey: "hyperKeyEnabled")

    let service = HyperKeyService(runner: { _ in false }, defaults: defaults)
    service.disable()

    #expect(service.isEnabled == true)
}
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```bash
swift test --filter HyperKeyServiceTests
```

Expected: FAIL because `enable()` and `disable()` currently mutate `isEnabled` unconditionally.

- [ ] **Step 3: Introduce a synchronous success/failure runner seam**

In `Sources/Quickey/Services/HyperKeyService.swift`, change the class to take injected collaborators:

```swift
typealias HidutilRunner = @Sendable ([String]) -> Bool

init(
    runner: @escaping HidutilRunner = HyperKeyService.runHidutil,
    defaults: UserDefaults = .standard
)
```

Make `runHidutil` wait for termination and return `Bool`:

```swift
private static func runHidutil(_ arguments: [String]) -> Bool {
    let process = Process()
    ...
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}
```

Update `enable()`, `disable()`, `reapplyIfNeeded()`, and `clearMappingIfEnabled()` to branch on the returned success value before mutating persisted state or logging success.

- [ ] **Step 4: Re-run the Hyper Key tests**

Run:

```bash
swift test --filter HyperKeyServiceTests
```

Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Quickey/Services/HyperKeyService.swift \
  Tests/QuickeyTests/HyperKeyServiceTests.swift
git commit -m "Persist Hyper Key state only after hidutil succeeds"
```

---

### Task 5: Align shortcut-capture readiness with dual permissions and active tap semantics

**Files:**
- Create: `Sources/Quickey/Protocols/PermissionServicing.swift`
- Create: `Sources/Quickey/Models/ShortcutCaptureStatus.swift`
- Modify: `Sources/Quickey/Services/AccessibilityPermissionService.swift`
- Modify: `Sources/Quickey/Protocols/EventTapManaging.swift`
- Modify: `Sources/Quickey/Services/EventTapManager.swift`
- Modify: `Sources/Quickey/Services/ShortcutManager.swift`
- Modify: `Sources/Quickey/Services/AppPreferences.swift`
- Modify: `Sources/Quickey/UI/ShortcutsTabView.swift`
- Create: `Tests/QuickeyTests/ShortcutManagerStatusTests.swift`

- [ ] **Step 1: Add a permission protocol and a status model**

Create `Sources/Quickey/Protocols/PermissionServicing.swift`:

```swift
protocol PermissionServicing: Sendable {
    func isTrusted() -> Bool
    func isAccessibilityTrusted() -> Bool
    func isInputMonitoringTrusted() -> Bool
    @discardableResult
    func requestIfNeeded(prompt: Bool) -> Bool
}
```

Make `AccessibilityPermissionService` conform in `Sources/Quickey/Services/AccessibilityPermissionService.swift`.

Create `Sources/Quickey/Models/ShortcutCaptureStatus.swift`:

```swift
struct ShortcutCaptureStatus: Equatable, Sendable {
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    let eventTapActive: Bool

    var permissionsGranted: Bool {
        accessibilityGranted && inputMonitoringGranted
    }

    var ready: Bool {
        permissionsGranted && eventTapActive
    }
}
```

- [ ] **Step 2: Add failing status tests**

Create `Tests/QuickeyTests/ShortcutManagerStatusTests.swift` with fakes for `EventTapManaging` and `PermissionServicing`.

Add at least:

```swift
@Test @MainActor
func captureStatusShowsInputMonitoringMissingSeparately() {
    let manager = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: false),
        eventTapManager: FakeEventTapManager()
    )

    let status = manager.shortcutCaptureStatus()
    #expect(status.accessibilityGranted == true)
    #expect(status.inputMonitoringGranted == false)
    #expect(status.ready == false)
}
```

Also add:

```swift
@Test @MainActor
func failedActiveTapDoesNotReportReady() {
    let tap = FakeEventTapManager(startResult: .failedToCreateTap)
    let manager = makeShortcutManager(
        permissionService: FakePermissionService(ax: true, input: true),
        eventTapManager: tap
    )

    manager.start()
    #expect(manager.shortcutCaptureStatus().ready == false)
}
```

- [ ] **Step 3: Run the status tests and verify they fail**

Run:

```bash
swift test --filter ShortcutManagerStatusTests
```

Expected: FAIL because the current model only exposes one misleading bool and the event tap can fall back to `.listenOnly`.

- [ ] **Step 4: Remove `.listenOnly` from the interception path**

In `Sources/Quickey/Protocols/EventTapManaging.swift`, change the API to return start status:

```swift
enum EventTapStartResult: Equatable, Sendable {
    case started
    case failedToCreateTap
}

@MainActor
protocol EventTapManaging {
    var isRunning: Bool { get }
    func start(onKeyPress: @escaping (KeyPress) -> Bool) -> EventTapStartResult
    ...
}
```

In `Sources/Quickey/Services/EventTapManager.swift`:
- Remove the `.listenOnly` fallback block entirely
- If `CGEvent.tapCreate(..., options: .defaultTap, ...)` returns `nil`, log the failure and return `.failedToCreateTap`
- Only set `eventTap`, `runLoopSource`, and `retainedBox` when the active tap is actually created

This matches Apple’s distinction between active filters and passive listeners.

- [ ] **Step 5: Expose a truthful readiness snapshot from ShortcutManager**

In `Sources/Quickey/Services/ShortcutManager.swift`:
- Change `permissionService` to `any PermissionServicing`
- Replace `hasAccessibilityAccess()` with:

```swift
func shortcutCaptureStatus() -> ShortcutCaptureStatus
```

- Inside `attemptStartIfPermitted()`, store the `EventTapStartResult`
- When startup fails, keep `eventTapManager.isRunning == false`
- Build `ShortcutCaptureStatus` from:

```swift
ShortcutCaptureStatus(
    accessibilityGranted: permissionService.isAccessibilityTrusted(),
    inputMonitoringGranted: permissionService.isInputMonitoringTrusted(),
    eventTapActive: eventTapManager.isRunning
)
```

- [ ] **Step 6: Update AppPreferences and the Shortcuts tab**

In `Sources/Quickey/Services/AppPreferences.swift`:
- Replace `accessibilityGranted` with:

```swift
private(set) var shortcutCaptureStatus: ShortcutCaptureStatus
```

- Initialize and refresh from `shortcutManager.shortcutCaptureStatus()`

In `Sources/Quickey/UI/ShortcutsTabView.swift`, replace the single status row with explicit messaging:

```swift
Text(preferences.shortcutCaptureStatus.accessibilityGranted ? "Accessibility granted" : "Accessibility required")
Text(preferences.shortcutCaptureStatus.inputMonitoringGranted ? "Input Monitoring granted" : "Input Monitoring required")
Text(preferences.shortcutCaptureStatus.ready ? "Global shortcuts are ready" : "Global shortcuts are not ready yet")
```

Keep the existing Refresh button, but have it refresh the full status snapshot instead of one mislabeled bool.

- [ ] **Step 7: Re-run the focused status tests**

Run:

```bash
swift test --filter ShortcutManagerStatusTests
```

Expected: PASS.

- [ ] **Step 8: Run a full build/test pass**

Run:

```bash
swift build
swift test
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/Quickey/Protocols/PermissionServicing.swift \
  Sources/Quickey/Models/ShortcutCaptureStatus.swift \
  Sources/Quickey/Services/AccessibilityPermissionService.swift \
  Sources/Quickey/Protocols/EventTapManaging.swift \
  Sources/Quickey/Services/EventTapManager.swift \
  Sources/Quickey/Services/ShortcutManager.swift \
  Sources/Quickey/Services/AppPreferences.swift \
  Sources/Quickey/UI/ShortcutsTabView.swift \
  Tests/QuickeyTests/ShortcutManagerStatusTests.swift
git commit -m "Align shortcut readiness with dual permissions and active taps"
```

---

### Task 6: Update docs and perform macOS-only validation

**Files:**
- Modify: `README.md`
- Modify: `TODO.md`
- Modify: `docs/architecture.md`
- Modify: `docs/handoff-notes.md`

- [ ] **Step 1: Update the documentation to match the post-fix architecture**

In `README.md`:
- Clarify that shortcut readiness depends on both permissions plus an active event tap
- Document the launch-at-login approval-needed state

In `docs/architecture.md`:
- Replace stale `SettingsViewModel` references with current `ShortcutEditorState` / `AppPreferences`
- Replace outdated “public API baseline / SkyLight deferred / real-device validation pending” text with the current architecture
- Document `LaunchAtLoginStatus` and `ShortcutCaptureStatus`

In `docs/handoff-notes.md`:
- Note the removal of `.listenOnly` fallback from the interception path
- Note the Insights date-window fix

In `TODO.md`:
- Replace any outdated “remaining” items that this work actually closes

- [ ] **Step 2: Run a final documentation diff review**

Run:

```bash
git diff -- README.md TODO.md docs/architecture.md docs/handoff-notes.md
```

Expected: docs match the current code and no stale claims remain.

- [ ] **Step 3: Perform macOS-only validation for platform behaviors**

On macOS, run:

```bash
swift build
swift test
swift build -c release
./scripts/package-app.sh
cp .build/release/Quickey build/Quickey.app/Contents/MacOS/Quickey
```

Then manually verify:
1. Launch app with only Accessibility granted: Shortcuts tab shows Input Monitoring missing, shortcuts not ready.
2. Launch app with only Input Monitoring granted: Shortcuts tab shows Accessibility missing, shortcuts not ready.
3. Launch app with both granted: status shows ready, shortcut press is consumed and does not leak into the frontmost app.
4. Revoke a permission while the app is running: status updates after Refresh and event tap stops.
5. Toggle Launch at Login on a clean macOS account: if System Settings approval is required, the app surfaces that state and the “Open Login Items Settings” action works.
6. Enable and disable Hyper Key: state persists only when the mapping actually succeeds.
7. Open Insights and switch D/W/M rapidly: the final selection’s totals and bars remain on screen.
8. Confirm “Today” excludes yesterday, “Past 7 Days” excludes the 8th day back, and “Past 30 Days” excludes the 31st day back.

- [ ] **Step 4: Record validation notes**

Append the results to `docs/handoff-notes.md` with:
- macOS version
- whether launch-at-login required approval
- whether event tap startup ever failed with both permissions granted
- whether Hyper Key enable/disable succeeded

- [ ] **Step 5: Commit**

```bash
git add README.md TODO.md docs/architecture.md docs/handoff-notes.md
git commit -m "Update docs after code review remediation"
```
