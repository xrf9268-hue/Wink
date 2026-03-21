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
- `ShortcutEditorState`
- `AppPreferences`
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
- surface truthful shortcut readiness via `ShortcutCaptureStatus`
- surface launch-at-login state via `LaunchAtLoginStatus`
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
- `ShortcutCaptureStatus`
- `scripts/package-app.sh`
- `Sources/Quickey/Resources/Info.plist`

Responsibilities:
- request/check Accessibility + Input Monitoring permission for global shortcuts
- report shortcut readiness from both permissions plus active event-tap state
- recover monitoring after permission changes without relaunch
- manage launch-at-login state via `SMAppService`, including approval-needed state
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
  -> EventTapManager.start() // active tap only, no passive listenOnly fallback
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
- **AppKit-first with selective SwiftUI**: deliberate architectural decision documented in `docs/archive/app-structure-direction.md`; hard AppKit requirements (`.accessory` policy, raw key capture, CGEvent tap, NSWorkspace) prevent a pure SwiftUI scene-based approach
- **Truthful shortcut readiness**: `ShortcutCaptureStatus` reports Accessibility, Input Monitoring, and active event-tap state separately
- **O(1) trigger index**: `ShortcutSignature` dictionary replaces linear scans in the hot path
- **Hardened EventTap lifecycle**: explicit ownership, auto-recovery on disable/timeout, run-loop cleanup
- **Active tap only**: passive `.listenOnly` mode is not used in the normal interception path because it cannot consume shortcut events
- **SkyLight activation path**: private API is used for reliable foreground switching from LSUIElement context
- **Best-effort toggle semantics**: activate → restore previous app → hide fallback
- **UsageTracker**: SQLite-backed daily usage aggregation off the main actor
- **Launch-at-login status modeling**: `LaunchAtLoginStatus` preserves enabled / approval-needed / disabled / not-found states

## Known architectural gaps
- No dedicated per-shortcut toggle history stack (single global previous-app memory is current approach)
- No test seam around event-tap capture itself (core logic is testable; tap infrastructure requires real macOS)
- Signed/notarized release build not yet produced (workflow documented in `docs/signing-and-release.md`)
- Targeted manual macOS validation is still recommended for the 2026-03-21 remediation changes (launch-at-login approval flow, active event-tap startup, Hyper Key failure cases)
