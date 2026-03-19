# Architecture

## High-level overview
Quickey is a menu bar macOS utility that stores app-shortcut bindings, captures global key events, matches them to stored shortcuts, and toggles target apps.

```text
+--------------------+
|   Menu Bar App     |
|  AppDelegate/Main  |
+---------+----------+
          |
          v
+--------------------+
|   AppController    |
| bootstraps modules |
+----+----+----+-----+
     |    |    |
     |    |    +-----------------------------+
     |    |                                  |
     v    v                                  v
+---------+--------+              +----------------------+
| ShortcutManager  |<------------>|    ShortcutStore     |
| event + trigger  |              | in-memory shortcuts  |
+----+--------+----+              +----------+-----------+
     |        |                              |
     |        v                              v
     |   +------------------+        +-------------------+
     |   | Persistence      |        | Settings UI       |
     |   | JSON save/load   |        | SwiftUI + AppKit  |
     |   +------------------+        +-------------------+
     |
     v
+--------------------+
|  EventTapManager   |
| CGEvent tap input  |
+---------+----------+
          |
          v
+--------------------+
|    KeyMatcher      |
| key/modifier match |
+---------+----------+
          |
          v
+--------------------+
|    AppSwitcher     |
| activate/toggle    |
+---------+----------+
          |
          v
+---------------------------+
| FrontmostApplicationTracker |
| previous app restore state |
+---------------------------+
```

## Main modules

### App lifecycle
- `main.swift`
- `AppDelegate`
- `AppController`

Responsibilities:
- start the accessory/menu bar app
- load persisted shortcuts
- start global shortcut handling
- install menu bar UI
- open settings window

### Settings and user interaction
- `SettingsWindowController`
- `SettingsView` (tabbed: Shortcuts / General / Insights)
- `SettingsViewModel`
- `ShortcutRecorderView`
- `ShortcutsTabView`
- `GeneralTabView`
- `InsightsTabView`
- `InsightsViewModel`
- `BarChartView`

Responsibilities:
- choose target applications
- record shortcuts
- display saved bindings with inline usage stats
- surface permission state and launch-at-login toggle
- show conflicts before saving
- display usage trends and app ranking via Insights tab

### Shortcut domain
- `AppShortcut`
- `RecordedShortcut`
- `ShortcutConflict`
- `ShortcutStore`
- `ShortcutValidator`

Responsibilities:
- represent saved shortcut bindings
- represent recorder output
- detect duplicate/conflicting bindings
- hold in-memory state used by the event path and UI

### Event capture and matching
- `EventTapManager`
- `KeyMatcher`
- `KeySymbolMapper`

Responsibilities:
- listen for global keyDown events via `CGEvent.tapCreate`
- normalize captured key events
- map between key codes and human-readable shortcut symbols
- match incoming events against stored bindings

### Activation and toggle logic
- `AppSwitcher`
- `FrontmostApplicationTracker`
- `AppBundleLocator`

Responsibilities:
- activate target apps
- launch installed apps if not already running
- restore previous app when toggling away
- hide target app as fallback
- reveal selected application in Finder when needed

### Usage tracking
- `UsageTracker`

Responsibilities:
- record shortcut activations with SQLite daily aggregation
- provide usage counts per shortcut for Insights UI
- run off the main actor via Swift actor isolation

### Permissions and packaging
- `AccessibilityPermissionService`
- `LaunchAtLoginService`
- `scripts/package-app.sh`
- `Sources/Quickey/Resources/Info.plist`

Responsibilities:
- request/check Input Monitoring permission for CGEvent tap
- recover monitoring after permission changes without relaunch
- manage launch-at-login state via SMAppService
- provide LSUIElement app bundle scaffold
- automate `.app` packaging via script

## Runtime event flow

### 1. Startup flow
```text
App launch
  -> AppController.start()
  -> PersistenceService.load()
  -> ShortcutStore.replaceAll()
  -> ShortcutManager.start()
  -> AccessibilityPermissionService.requestIfNeeded()
  -> EventTapManager.start()
  -> MenuBarController.install()
```

### 2. Add shortcut flow
```text
User opens settings
  -> choose app
  -> record shortcut
  -> SettingsViewModel builds AppShortcut
  -> ShortcutValidator checks conflicts
  -> ShortcutManager.save()
  -> ShortcutStore.replaceAll()
  -> PersistenceService.save()
```

### 3. Trigger flow
```text
Global keyDown event
  -> EventTapManager emits KeyPress
  -> ShortcutManager.handleKeyPress()
  -> KeyMatcher finds matching AppShortcut
  -> AppSwitcher.toggleApplication()
  -> activate / restore previous app / hide fallback
```

## Current design choices
- **SPM-first**: simple repo layout and source organization
- **AppKit-first with selective SwiftUI**: deliberate architectural decision documented in `docs/plans/app-structure-direction.md`; hard AppKit requirements (`.accessory` policy, raw key capture, CGEvent tap, NSWorkspace) prevent a pure SwiftUI scene-based approach
- **Input Monitoring permission**: aligned with the real CGEvent tap monitoring path (not Accessibility trust)
- **O(1) trigger index**: `ShortcutSignature` dictionary replaces linear scans in the hot path
- **Hardened EventTap lifecycle**: explicit ownership, auto-recovery on disable/timeout, run-loop cleanup
- **Public API baseline**: no private SkyLight dependency; low-latency private activation path intentionally deferred
- **Best-effort toggle semantics**: activate → restore previous app → hide fallback
- **UsageTracker**: SQLite-backed daily usage aggregation off the main actor

## Known architectural gaps
- No dedicated per-shortcut toggle history stack (single global previous-app memory is current approach)
- No test seam around event-tap capture itself (core logic is testable; tap infrastructure requires real macOS)
- Signed/notarized release build not yet produced (workflow documented in `docs/signing-and-release.md`)
- No private low-latency SkyLight activation tier (intentionally deferred)
- End-to-end device validation still pending on real macOS hardware
