# Handoff Notes

## Current State
Quickey was broadly validated on macOS 15.3.1 on 2026-03-20. On 2026-03-24, the toggle-stability and event-tap reliability plan's Tasks 1-5 were already present in `main`, and Task 6 updated the architecture/runtime documentation and reran the automated verification suite. The landed runtime now uses `ApplicationObservation` snapshots to decide whether activation is truly stable, keeps per-target toggle state in `ToggleSessionCoordinator`, stores session-owned `previousBundle` values across activation/deactivation phases, invalidates those sessions from `NSWorkspace` notifications, and escalates repeated event-tap timeout storms from in-place re-enable to same-thread recreation and then degraded readiness reporting. A signed and notarized distributable is still unresolved. No new manual macOS runtime claims are made in this task; the targeted post-redesign validation matrix remains pending.

## Automated Verification (2026-03-24)
- `swift test` passed after the Task 6 documentation update; the suite reported 146 tests passed
- `swift build` passed after the Task 6 documentation update
- `swift build -c release` passed after the Task 6 documentation update
- `./scripts/package-app.sh` passed after the Task 6 documentation update, rebuilt `build/Quickey.app`, and reset TCC approvals for `com.quickey.app` as part of the ad-hoc packaging flow

## Validated on macOS
- Broad real-device validation completed on macOS 15.3.1 on 2026-03-20
- `swift build`, `swift test`, release build, and `./scripts/package-app.sh` passed
- Dual permission gating, active capture startup, and end-to-end shortcut interception were validated
- Runtime toggle behavior, restore/hide fallback, and window recovery paths were exercised successfully
- Insights persistence and restart behavior were confirmed during the macOS pass
- The 2026-03-24 toggle-stability/event-tap redesign has not yet had its targeted post-landing macOS validation pass

## Toggle Loop Fix and Cross-App Restore (2026-03-25, Issue #80)
- **Toggle loop root cause**: physical key repeat events spaced > 200ms bypassed debounce, causing activate/hide/activate cycles
- **Three-layer defense**: debounce 500ms + per-bundle toggle cooldown 800ms + re-entry guard
- **Cross-app restore bug found and fixed**: when App A's toggle-off restores App B, pressing App B's shortcut failed to toggle it off. Root cause: `stableActivationState` for B was cleared when A was toggled on, and never recreated when B was restored externally. Fixed by adding `ACTIVE_UNTRACKED` path that hides the app when it is frontmost but has no tracking state.
- **Additional hardening**: previousApp self-reference guard, coordinator invalidation logging, lastToggleTimeByBundle eviction, activate-path isActive warning

## Implemented Behavioral Guarantees
- Half-active frontmost mismatches are not promoted to stable: `ActivationObservationSnapshot.isStableActivation` requires target/frontmost agreement, `targetIsActive == true`, `targetIsHidden == false`, and supporting window evidence before `AppSwitcher` can promote a pending activation
- A second press during pending activation does not toggle off: `pendingActivationState` blocks `shouldToggleOff`, and a repeat accepted trigger refreshes confirmation generation instead of restoring away
- Confirmation failure does not trigger flicker-inducing restore-away rollback: failed confirmation either advances through the staged recovery path or drops the session back to idle/degraded without restoring the previous app automatically
- Stable toggle-off now uses session-owned `previousBundle`, attempts restore first, hides as fallback when the post-restore observation is still contradictory, and clears runtime session state coherently
- Event tap recovery now either recreates the tap successfully on the existing background RunLoop thread or leaves an explicit degraded readiness state after repeated recreation failures

## Follow-up Requiring macOS Validation
- Normal apps: Safari, Finder, Terminal
  Validate stable activation, second-press toggle-off back to the previous app, and coherent `TOGGLE_STABLE` / `TOGGLE_RESTORE_CONFIRMED` diagnostics
- System or window-weird apps: Home, Clock, System Settings
  Validate that visible-but-not-frontmost states do not promote to stable and that repeat presses during pending/degraded activation keep re-confirming instead of toggling away
- Hidden app reactivation
  Validate that an already-hidden target can return to `activeStable` and still restore the previous app on the next confirmed toggle-off
- Minimized window recovery
  Validate that unminimize/recovery stages settle before confirmation promotion and that missing visible-window evidence prevents false stable promotion
- Fast repeated same-shortcut presses
  Validate debounce plus pending-session behavior under rapid repeated input for the same target
- Event tap timeout/recovery stress
  If reproducible on macOS, trigger timeout churn and confirm: first timeout re-enables in place, 3 timeouts within 30 seconds escalate to recreation, and repeated recreation failures surface degraded readiness/logs
- Launch-at-login approval flow after the 2026-03-23 issue #67 approval-state UX update, especially `.requiresApproval` -> `.enabled` foreground refresh and `.notFound` behavior on real installs
- Active event-tap startup and readiness reporting after permission or lifecycle changes
- AppSwitcher fallback behavior after SkyLight failure now that it re-requests activation via `NSWorkspace`
- Hyper Key failure handling, especially persistence only after `hidutil` succeeds
- Insights date-window and refresh-race fixes
- Signed/notarized distributable workflow once a Developer ID certificate is available

## Operational Caveats
- CGEvent tap readiness depends on both Accessibility and Input Monitoring, plus a successfully started active event tap
- Ad-hoc signing changes can invalidate TCC state; use `tccutil reset` during development when needed
- Launch the app with `open`, not by executing the binary directly, so TCC matches the correct app identity
- SkyLight is a private API dependency for reliable activation from LSUIElement apps and may block App Store submission
- If SkyLight activation fails, Quickey now falls back to an `NSWorkspace` reopen request instead of the deprecated `activateIgnoringOtherApps` path
- Unified logging can hide useful runtime details; file-based debug logs (`~/.config/Quickey/debug.log`) are more reliable for diagnosis

## Residual Risks
- The new toggle guarantees are covered by code-level tests and by the automated suite, but they still need the targeted macOS matrix above before we can claim runtime correctness for Home, Clock, System Settings, or timeout-stress behavior
- Event tap recovery semantics are implemented with thresholded escalation and degraded reporting, but a reproducible on-device timeout-stress run is still needed to confirm the live logs are operationally sufficient
- Signed/notarized release validation is still blocked on Developer ID availability

## Immediate Next Actions
1. Run the targeted macOS validation matrix for Safari, Finder, Terminal, Home, Clock, System Settings, hidden/minimized paths, fast repeat-trigger flows, and event-tap timeout stress
2. Capture the real 2026-03-24 validation results in this file, including any degraded-state logs or app-specific exceptions that remain
3. Produce a signed and notarized `.app` once a Developer ID certificate is available
4. Fold any new validation findings back into this note, not into the feature overview docs
