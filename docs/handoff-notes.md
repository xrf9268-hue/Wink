# Handoff Notes

## Current State
Quickey was broadly validated on macOS 15.3.1 on 2026-03-20. On 2026-04-08, the shortcut-capture and toggle runtime were further refactored: standard shortcuts now use Carbon hotkeys, Hyper-dependent shortcuts remain on the active event tap, activation now defaults to front-process-only before escalating observation-driven window recovery, and toggle-off now uses `NSRunningApplication.hide()` with asynchronous confirmation. On 2026-04-08, targeted macOS re-validation was completed for the redesigned Safari/Hyper paths: Safari toggle-on/toggle-off now works again, Hyper-routed shortcuts survive fresh relaunches, and the post-fix runtime window shows `TOGGLE_HIDE_CONFIRMED` without new `TOGGLE_DEGRADED`, `hide_untracked`, event-tap-disable, or shortcut-capture resync-storm signatures. Broader app-matrix validation is still pending. A signed and notarized distributable is still unresolved.
On 2026-04-08, launch-at-login presentation was hardened so `SMAppService.Status.notFound` is no longer always treated as a packaging failure: when Quickey is running outside `/Applications` or `~/Applications`, the General tab now shows install-location guidance instead of the red bundle-misconfiguration warning.
On 2026-04-08, local DMG packaging and a tag-driven GitHub release workflow were added. The repo can now build `build/Quickey-<version>.dmg` locally and defines the credential-backed notarization/publish path. On 2026-04-08, the release workflow was further hardened to preflight required signing/notarization secrets and skip cleanly with a summary when Developer ID credentials are absent, and a separate internal-package workflow was added to upload unsigned DMG artifacts for trusted testers. The internal workflow now also maintains a stable `internal-downloads` tag-backed prerelease page with tester-facing install notes and the latest internal DMG asset, instead of deleting and recreating the release each run.

## Automated Verification (2026-04-08)
- `swift test` passed after the DMG packaging and release workflow changes; the suite reported 173 tests passed
- `swift build` passed after the refactor
- `./scripts/package-app.sh` passed after the refactor, rebuilt `build/Quickey.app`, and re-signed it with the local `Quickey` identity
- `./scripts/package-dmg.sh` passed and produced `build/Quickey-0.2.0.dmg`
- Workflow regression checks passed for release preflight gating, manual `release_tag` dispatch, and internal-package artifact upload wiring

## Validated on macOS
- Broad real-device validation completed on macOS 15.3.1 on 2026-03-20
- `swift build`, `swift test`, release build, and `./scripts/package-app.sh` passed
- Dual permission gating, active capture startup, and end-to-end shortcut interception were validated
- Runtime toggle behavior, direct-hide confirmation, and window recovery paths were exercised successfully
- Insights persistence and restart behavior were confirmed during the macOS pass
- On 2026-04-08, targeted post-redesign validation confirmed Safari toggle-on/toggle-off behavior again on a real macOS session
- On 2026-04-08, Hyper-routed shortcuts were re-validated after a fresh relaunch; the startup-state replay fix restored live `HYPER_INJECT` / `EVENT_TAP_SWALLOW` behavior
- The post-fix runtime window showed repeated `HIDE_REQUEST` -> `TOGGLE_HIDE_CONFIRMED` pairs without fresh `TOGGLE_DEGRADED`, `TOGGLE_HIDE_DEGRADED`, `hide_untracked`, event-tap-disable diagnostics, or repeated "syncing shortcut capture" churn
- Broader 2026-04-08 app-matrix validation for system/window-weird apps remains pending

## Toggle Loop Fix and Cross-App Restore (2026-03-25, Issue #80)
- **Toggle loop root cause**: physical key repeat events spaced > 200ms bypassed debounce, causing activate/hide/activate cycles
- **Three-layer defense**: debounce 200ms + per-bundle toggle cooldown 400ms + re-entry guard (reduced from 500ms/800ms in issue #82; Layer 1 autorepeat filter is the primary defense)
- **Cross-app restore bug found and fixed**: when App A's toggle-off restores App B, pressing App B's shortcut failed to toggle it off. Root cause: `stableActivationState` for B was cleared when A was toggled on, and never recreated when B was restored externally. Fixed by adding `ACTIVE_UNTRACKED` path that hides the app when it is frontmost but has no tracking state.
- **Additional hardening**: previousApp self-reference guard, coordinator invalidation logging, lastToggleTimeByBundle eviction, activate-path isActive warning

## Capture / Activation / Hide Refactor (2026-04-08)
- Standard shortcuts now register through Carbon `EventHotKey`; the active event tap remains only for Hyper-routed shortcuts.
- Input Monitoring no longer blocks standard-shortcut readiness when the current shortcut set does not require the Hyper path.
- Stable activation now defaults to front-process activation only. `makeKeyWindow`, `AXRaise`, and reopen/new-window recovery run only if observation shows the activation is not yet settled.
- Stable toggle-off no longer restores the previous app first for normal app-level hides.
- Toggle-off now uses the official `NSRunningApplication.hide()` request, then keeps the session in `deactivating` until hide is actually confirmed.
- Deactivation confirmation is notification-first: `NSWorkspace.didHideApplicationNotification` completes the session immediately when available, with a short observation window as a bounded backstop.
- A target is not considered toggled off merely because another app became frontmost; confirmation requires the target to be not frontmost and either hidden or windowless, which closes the Safari-visible-behind-Finder gap documented in `docs/handoff-safari-hide-bug.md`.
- Repeat presses while the target is still deactivating no longer clear stable state or reactivate the target.

## Implemented Behavioral Guarantees
- Half-active frontmost mismatches are not promoted to stable: `ActivationObservationSnapshot.isStableActivation` requires target/frontmost agreement, `targetIsActive == true`, `targetIsHidden == false`, and supporting window evidence before `AppSwitcher` can promote a pending activation
- A second press during pending activation does not toggle off: `pendingActivationState` blocks `shouldToggleOff`, and a repeat accepted trigger refreshes confirmation generation instead of restoring away
- Confirmation failure does not trigger flicker-inducing restore-away rollback: failed confirmation either advances through the staged recovery path or drops the session back to idle/degraded without restoring the previous app automatically
- Stable toggle-off now enters an explicit `deactivating` phase, requests `hide()` on the target app, and clears runtime session state only after hide confirmation succeeds
- Event tap recovery now either recreates the tap successfully on the existing background RunLoop thread or leaves an explicit degraded readiness state after repeated recreation failures
- Standard shortcuts and Hyper shortcuts now report readiness independently, so missing Input Monitoring only degrades Hyper capture instead of the whole app

## Follow-up Requiring macOS Validation
- Normal apps beyond Safari: Finder, Terminal
  Validate stable activation, second-press toggle-off via `hide()`, and coherent `TOGGLE_STABLE` / `TOGGLE_HIDE_CONFIRMED` diagnostics
- System or window-weird apps: Home, Clock, System Settings
  Validate that visible-but-not-frontmost states do not promote to stable and that repeat presses during pending/degraded activation keep re-confirming instead of toggling away
- Hidden app reactivation
  Validate that an already-hidden target can return to `activeStable` and still hide cleanly on the next confirmed toggle-off
- Minimized window recovery
  Validate that `makeKeyWindow` / `AXRaise` / reopen recovery stages settle before confirmation promotion and that missing focused/main-window evidence prevents false stable promotion
- Fast repeated same-shortcut presses
  Validate debounce plus pending-session behavior under rapid repeated input for the same target
- Event tap timeout/recovery stress
  If reproducible on macOS, trigger timeout churn and confirm: first timeout re-enables in place, 3 timeouts within 30 seconds escalate to recreation, and repeated recreation failures surface degraded readiness/logs
- Shortcut transport split
  Validate that standard shortcuts keep working without Input Monitoring, while Hyper shortcuts correctly require it and recover when the permission is granted later
- Launch-at-login approval flow after the 2026-03-23 issue #67 approval-state UX update, especially `.requiresApproval` -> `.enabled` foreground refresh and `.notFound` behavior on real installs
- Launch-at-login validation should use a packaged app installed in `/Applications` or `~/Applications`; repo-local `build/Quickey.app` runs now surface install-location guidance instead of masquerading as a broken bundle
- Active event-tap startup and readiness reporting after permission or lifecycle changes
- AppSwitcher fallback behavior after SkyLight failure now that it re-requests activation via `NSWorkspace`
- Hyper Key failure handling, especially persistence only after `hidutil` succeeds
- Insights date-window and refresh-race fixes
- Signed/notarized distributable workflow once a Developer ID certificate is available
- Credential-backed validation of `.github/workflows/release.yml`, including certificate import, notarization, stapling, `spctl`, and GitHub Release upload
- Internal-package workflow download/install validation on a clean macOS machine

## Operational Caveats
- Standard shortcuts require Accessibility plus successful Carbon registration; Hyper shortcuts additionally require Input Monitoring plus a successfully started active event tap
- Ad-hoc signing changes can invalidate TCC state; use `tccutil reset` during development when needed
- Launch the app with `open`, not by executing the binary directly, so TCC matches the correct app identity
- SkyLight is a private API dependency for reliable activation from LSUIElement apps and may block App Store submission
- If SkyLight activation fails, Quickey now falls back to an `NSWorkspace` reopen request instead of the deprecated `activateIgnoringOtherApps` path
- Unified logging can hide useful runtime details; file-based debug logs (`~/.config/Quickey/debug.log`) are more reliable for diagnosis

## Residual Risks
- The new capture split and toggle guarantees are covered by code-level tests and by the automated suite, but they still need the targeted macOS matrix above before we can claim runtime correctness for Safari-only toggle-off, standard-vs-Hyper parity, Home, Clock, System Settings, or timeout-stress behavior
- Event tap recovery semantics are implemented with thresholded escalation and degraded reporting, but a reproducible on-device timeout-stress run is still needed to confirm the live logs are operationally sufficient
- Signed/notarized release validation is still blocked on Developer ID availability; until those credentials exist, only the internal-package DMG artifact path can be verified end-to-end

## Immediate Next Actions
1. Expand the targeted macOS validation matrix from the now-confirmed Safari/Hyper relaunch paths to Finder, Terminal, Home, Clock, System Settings, hidden/minimized paths, and event-tap timeout stress
2. Verify standard-shortcut vs Hyper parity on the same target apps beyond the already revalidated Safari/Hyper cases, and capture any remaining app-specific exceptions in this file
3. Use the internal-package workflow for tester-facing DMG artifacts until Developer ID credentials are available
4. Run the DMG release workflow with real Developer ID and notary credentials on a `v*` tag once those credentials exist
5. Validate the published DMG on a clean macOS machine and confirm drag-install to `/Applications`
6. Fold any new validation findings back into this note, not into the feature overview docs
