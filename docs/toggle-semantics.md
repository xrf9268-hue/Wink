# Toggle Semantics

## Intended behavior
HotApp Clone should behave like a dedicated app switcher, not just a one-way launcher.

For a given shortcut bound to a target app:
1. If the target app is not frontmost, activate it.
2. If the target app is already frontmost, try to restore the previously frontmost non-target app.
3. If no previous app can be restored, hide the target app as a fallback.
4. If the target app is not running but installed, launch it.

## Current implementation
The current code tracks the last non-target frontmost bundle identifier before bringing a target app forward.
When the shortcut is pressed again while the target app is active, it first tries to reactivate that previous app and then falls back to hiding the target app.

## Limitations
- Previous-app restoration is best-effort and only tracks a single bundle identifier.
- This does not yet model per-shortcut history stacks.
- Edge cases like minimized windows, full-screen spaces, and multi-window apps are not deeply handled yet.
- Thor parity may require more nuanced heuristics after macOS-side testing.
