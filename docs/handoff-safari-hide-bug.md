# Bug: Safari toggle-off fails when it's the only app

> Historical investigation note: this document captures the superseded restore-first / compatibility implementation that was removed on 2026-04-08. Keep it as failure evidence, not as implementation guidance.

## Symptom

When only Safari is open on the desktop, pressing Cmd+Shift+S to toggle-off (hide Safari) does not visually hide Safari. Repeated presses cause an activate-hide-activate oscillation where the user can never get Safari to disappear. Works fine when other windowed apps are open.

## Reproduction

1. Close all apps except Safari
2. Configure Quickey shortcut: Cmd+Shift+S -> Safari
3. Press Cmd+Shift+S to activate Safari (works)
4. Press Cmd+Shift+S again to hide Safari (fails - Safari stays visible)
5. Repeat pressing - Safari never hides

## Root Cause Analysis

The toggle-off path is `performCompatibilityToggle` in `Sources/Quickey/Services/AppSwitcher.swift:723-784`.

### What happens (traced from debug.log)

```
TOGGLE_RESTORE_ATTEMPT → Safari is frontmost, stable

1. AXUIElementSetAttributeValue(kAXHiddenAttribute, true)
   → returns .success BUT Safari is NOT actually hidden (async, takes 1-4 seconds)

2. restorePreviousApp("com.apple.finder") → SkyLight activate Finder
   → returns true BUT Finder has no windows, so frontmost change is slow

3. Post-snapshot taken at ~16-20ms
   → reads STALE state: Safari still frontmost, targetHidden=false

4. DEGRADED_RECOVERY: runningApp.hide()
   → returns false (accessory/LSUIElement app limitation on macOS 15)

5. Result: TOGGLE_RESTORE_DEGRADED
   → Safari eventually loses frontmost (~200-500ms later, SkyLight works)
   → Safari window remains VISIBLE on screen (not hidden, just behind Finder desktop)
   → targetHidden=false persists — neither AX hide nor NS hide actually hid Safari
```

### Why user perceives "can't hide"

1. Toggle-off fires but Safari window stays visible (behind Finder desktop, not hidden)
2. After 200-500ms, Finder becomes frontmost. Safari is NOT frontmost but NOT hidden
3. User presses shortcut again. Quickey sees "RUNNING NOT FRONT" → re-activates Safari
4. Net effect: every pair of presses = hide attempt + re-activate = no visible change

### The three hide methods and why they all fail

| Method | Return value | Actual effect |
|--------|-------------|---------------|
| `AXUIElementSetAttributeValue(kAXHiddenAttribute)` | `.success` | Async. Takes 1-4 seconds. Sometimes works, sometimes doesn't |
| `NSRunningApplication.hide()` | `false` | Documented to return false from LSUIElement apps on macOS 15 |
| SkyLight activate Finder | `true` | Makes Finder frontmost but doesn't hide Safari's window |

### Key log evidence

Every restore attempt shows:
```
IS ACTIVE lane=compatibility restored=true hidden=true nsHidden=false
POST_RESTORE_STATE targetFrontmost=true targetHidden=false visibleWindowCount=1
TOGGLE_RESTORE_DEGRADED
```

Meaning: all hide calls "succeed" at API level but Safari window stays visible.

## What was tried and failed

### Attempt 1: Polling loop before post-snapshot (200ms)
Added `RunLoop.main.run` polling to wait for frontmost change. Result: Finder DID become frontmost within 200ms, but `targetHidden=false` persisted. Safari window still visible. Also, the polling caused the DEGRADED_RECOVERY path to be skipped (since target was no longer frontmost), removing the `runningApp.hide()` call entirely.

### Attempt 2: Unconditional `runningApp.hide()` after restore
Always call `runningApp.hide()` regardless of frontmost state. Result: `nsHidden=false` consistently. No visible effect.

### Attempt 3: `runningApp.hide()` BEFORE SkyLight restore
Moved `runningApp.hide()` to execute first. Result: broke SkyLight restore (`restored=false`). Calling hide() first appears to interfere with `GetProcessForPID` or SkyLight PSN state.

## Key architectural context

- Quickey is an LSUIElement (accessory) app: `Info.plist: LSUIElement=true`
- Signed with stable "Quickey" self-signed certificate
- macOS 15, Swift 6, arm64
- SkyLight private API (`_SLPSSetFrontProcessWithOptions`) is the only reliable activation path
- `NSRunningApplication.activate(options:)` without `ignoringOtherApps` is cooperative (system may decline)
- The activate path (toggle-on) works reliably in ~91ms via `schedulePendingConfirmation`

## Files involved

- `Sources/Quickey/Services/AppSwitcher.swift` - main toggle logic
  - `performCompatibilityToggle()` line ~723 - the broken toggle-off path
  - `performFastLaneToggle()` line ~627 - fast lane (also falls back to compat)
  - `activateViaWindowServer()` line ~792 - SkyLight three-layer activation
  - `restorePreviousApp()` line ~613 - lookup + SkyLight activate previous
- `Sources/Quickey/Services/ObservationBroker.swift` - confirmation polling
- `Sources/Quickey/Services/FrontmostApplicationTracker.swift` - frontmost tracking
- `Sources/Quickey/Services/ApplicationObservation.swift` - snapshot/classification

## Possible directions to explore

1. **CGEvent Cmd+H post**: Post a synthetic Cmd+H keystroke to Safari's PID via `CGEventPostToPid`. This is how the system hides apps natively. Caveat: `CGEventPostToPid` doesn't traverse session event taps (per issue #80 findings), but that's fine here since we WANT to bypass the tap.

2. **`NSWorkspace.shared.hideOtherApplications()`**: Called from Quickey, would hide Safari. But has side effects with multiple apps.

3. **Window minimize via AX**: `AXUIElementPerformAction(kAXMinimizeAction)` on Safari's window. Visually removes the window but changes user state (window goes to Dock).

4. **Study Thor/Manico behavior**: These apps successfully hide from LSUIElement context. May be using a different private API or calling hide() with different timing relative to activation changes.

5. **Investigate WHY `NSRunningApplication.hide()` returns false**: The assumption "returns false from LSUIElement" may be wrong or version-specific. Test if it works in isolation (without AX hide or SkyLight calls preceding it).

6. **Defer the hide**: Instead of hiding synchronously in the toggle-off path, schedule the hide asynchronously (like activate path uses `schedulePendingConfirmation`). Let macOS settle, then hide.

## Build & test

```bash
swift build
swift test                    # 195 unit tests
./scripts/package-app.sh      # build + sign + package
./scripts/e2e-full-test.sh    # 6 E2E test modules
```

## Debug log location

```
~/.config/Quickey/debug.log
```
