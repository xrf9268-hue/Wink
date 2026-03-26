# Toggle Semantics

## Intended behavior
Quickey should behave like a dedicated app switcher, not just a one-way launcher.

For a given shortcut bound to a target app:
1. If the target app is not frontmost, activate it.
2. If the target app is already frontmost, try to restore the previously frontmost non-target app.
3. If no previous app can be restored, hide the target app as a fallback.
4. If the target app is not running but installed, launch it.

## Current implementation
The current code tracks the last non-target frontmost bundle identifier before bringing a target app forward.
When the shortcut is pressed again while the target app is active, it first tries to reactivate that previous app and then falls back to hiding the target app.

## Edge cases and their handling (updated 2026-03-25)

### Cross-app restore (ACTIVE_UNTRACKED)
When App A's toggle-off restores App B to the foreground, App B has no stableActivationState.
Pressing App B's shortcut triggers the `ACTIVE_UNTRACKED` path: hide the app and let macOS
choose the next foreground app. The previous-app info is unreliable in this state.

### External activation (Dock/Cmd-Tab)
If the user activates an app outside Quickey, the app has no tracking state. The first shortcut
press hides it (ACTIVE_UNTRACKED path). This matches toggle semantics: "app is frontmost → hide it."

### Launch path
The first shortcut press launches the app (no tracking state created). The second press hides it
(ACTIVE_UNTRACKED). The 800ms cooldown prevents accidental double-trigger.

### previousApp self-reference
When target B was restored by another toggle-off, `lastNonTargetBundleIdentifier` may still
point to B itself. A guard detects and clears this self-reference before recording it as previousApp.

## Limitations
- Previous-app restoration is best-effort and only tracks a single bundle identifier.
- This does not yet model per-shortcut history stacks.
- Edge cases like minimized windows, full-screen spaces, and multi-window apps are not deeply handled yet.
- ACTIVE_UNTRACKED path cannot restore to a specific previous app — it only hides.
- Thor parity may require more nuanced heuristics after macOS-side testing.
