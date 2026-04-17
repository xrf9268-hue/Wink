# Handoff Notes

## Current State
On 2026-04-17, the PR governance baseline and deterministic review-state harness were added on the `codex/pr-governance-harness` line: `.github/workflows/review-gate.yml` now evaluates GitHub `reviewDecision` plus unresolved non-outdated inline review threads, `.github/scripts/validate-review-state.mjs` writes maintainable failure summaries instead of raw payload dumps, `.github/governance/main-ruleset.json` captures the desired `main` merge policy in-repo, and the supporting docs now distinguish repository-native review gates from separate macOS runtime-validation evidence. The remaining rollout step is administrative sequencing: merge the workflow/scripts to `main` first, then apply the checked-in ruleset so `Review Gate / Validate review state` exists before it becomes required. One important GitHub Actions caveat is now documented explicitly: Actions can rerun this check on PR/review/review-comment activity, but not on a pure review-thread resolve/unresolve event, so GitHub's own required conversation resolution remains the durable blocker for that edge.
Quickey was broadly validated on macOS 15.3.1 on 2026-03-20. On 2026-04-08, the shortcut-capture and toggle runtime were further refactored: standard shortcuts now use Carbon hotkeys, Hyper-dependent shortcuts remain on the active event tap, activation now defaults to front-process-only before escalating observation-driven window recovery, and toggle-off now uses `NSRunningApplication.hide()` with asynchronous confirmation. On 2026-04-08, targeted macOS re-validation was completed for the redesigned Safari/Hyper paths: Safari toggle-on/toggle-off now works again, Hyper-routed shortcuts survive fresh relaunches, and the post-fix runtime window shows `TOGGLE_HIDE_CONFIRMED` without new `TOGGLE_DEGRADED`, `hide_untracked`, event-tap-disable, or shortcut-capture resync-storm signatures. Broader app-matrix validation is still pending. A signed and notarized distributable is still unresolved.
On 2026-04-16, issue #138 realigned `docs/architecture.md` with the current codebase: stale `SettingsViewModel` references were removed, startup/add-shortcut/trigger flows now describe the actual `AppController -> ShortcutManager -> ShortcutCaptureCoordinator` and `SettingsWindowController -> ShortcutEditorState -> ShortcutManager.save()` pipelines, and the document now states explicitly that `FrontmostApplicationTracker` only captures the frontmost snapshot while `ToggleSessionCoordinator` owns durable `previousBundle` session state. This was a documentation-only alignment; no runtime behavior changed.
On 2026-04-16, issue #140 investigated the missing `System Settings > Privacy & Security > Input Monitoring` row that was seen during the packaged Hyper-only validation follow-up. The macOS 15.0 SDK headers for `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` only promise effective event-listening access, not System Settings row visibility, and the original validation already showed the authoritative runtime signals (`Input Monitoring permission: granted`, active event tap, passing Hyper E2E). Quickey now surfaces a non-blocking Settings banner note when Hyper capture is already active to clarify that the Input Monitoring pane can lag behind live access; troubleshooting guidance now treats `CGPreflightListenEventAccess()` plus event-tap health as the source of truth, while still calling out signature churn and launch-path mismatches as TCC confounders.
On 2026-04-16, GitHub workflow automation was added to close the issue/project drift exposed around #135: `.github/workflows/pr-metadata.yml` now blocks PRs that omit a closing keyword or a valid `Validation Status`, `.github/workflows/project-sync.yml` now reconciles `Quickey Backlog` `Status` (`Ready` / `In Progress` / `Done`) plus `Runtime Validation` (`None` / `macOS pending` / `macOS complete`), linked issues are auto-added to the project if missing, and scheduled/manual reconciliation now backfills any repository issues that were never added because earlier events or API writes failed. This workflow requires a repository secret named `PROJECT_AUTOMATION_TOKEN` with `repo`, `project`, and `read:org` scope; see `docs/github-automation.md`.
On 2026-04-16, issue #133 made shortcut persistence strict and non-destructive again: `PersistenceService.load()` now fails loudly for malformed or unsupported `shortcuts.json`, logs the file path plus failure reason, and preserves a `shortcuts.load-failure-*.json` copy instead of silently collapsing runtime state to `[]`. A tag audit showed `isEnabled` landed before `v0.2.0` and the later `internal-downloads` prerelease, so the current policy intentionally does not migrate payloads missing `isEnabled`. The packaged `build/Quickey.app` was then manually revalidated on macOS for malformed JSON, missing `isEnabled`, and unsupported-schema startup fixtures; in each case Quickey stayed running, logged the failure plus preserved-copy path, left the original `shortcuts.json` untouched, and started with an empty in-memory shortcut set instead of silently overwriting persisted data.
On 2026-04-16, issue #135 tightened truthful standard-shortcut readiness around per-binding Carbon registration: `CarbonHotKeyProvider` now tracks desired vs. registered standard bindings plus failed keyCode/modifier/status tuples, `ShortcutCaptureCoordinator` only reports `carbonHotKeysRegistered` / `standardShortcutsReady` when every enabled standard binding registered successfully, `SHORTCUT_TRACE_BLOCKED reason="missing_registration_or_system_conflict"` now includes failed-binding details, and the settings banner now warns instead of claiming standard shortcuts are active during partial registration failure. Packaged-app macOS runtime validation is now complete for the current standard-only fixture via `bash scripts/e2e-full-test.sh`; a live Carbon partial-registration reproduction on this machine is still pending because neither common system-reserved shortcuts nor a second hotkey-holder helper process induced `RegisterEventHotKey` failure here.
On 2026-04-16, issue #136 refreshed the Settings shortcut-readiness banner on app reactivation: `SettingsViewLifecycleHandler.handleAppDidBecomeActive()` now refreshes `shortcutCaptureStatus` in addition to launch-at-login state, and the regression is covered by `handleAppDidBecomeActiveRefreshesShortcutCaptureAndLaunchAtLoginStatus()`. Packaged-app runtime validation for the current build was re-run on macOS 15.3.1 with both the user's standard-only Safari fixture and a temporary mixed fixture (`Safari` standard + `IINA` Hyper), producing passing `bash scripts/e2e-full-test.sh` runs in both modes (`6/6 PASS, 1 warning` on the standard-only fixture because Hyper was a configuration skip; `6/6 PASS, 0 warnings` on the temporary mixed fixture). The destructive permission-flip path is now also complete: after `tccutil reset All com.quickey.app`, packaged `build/Quickey.app` reopened with the Settings banner showing `Accessibility permission required`; after re-granting permissions in System Settings and returning to the same Quickey Settings window without clicking `Refresh`, the banner automatically changed to `Shortcut capture ready` / `Standard and Hyper shortcuts are active.`
On 2026-04-16, issue #137 fixed the remaining launch-at-login bool-collapse in the menu bar: `MenuBarController` now derives an explicit multi-state menu presentation from `LaunchAtLoginSnapshot` instead of inverting `isEnabled`, `.requiresApproval` now presents as an approval CTA (`Approve Launch at Login...`) that opens Login Items settings instead of pretending to be a normal toggle, `.notFound` now distinguishes install-location guidance from real configuration failure in its disabled title, and the menu refreshes that state every time it opens so post-approval changes are not stuck on stale UI. Code-level regression coverage now lives in `MenuBarLaunchAtLoginPresentationTests`, while real macOS validation of the packaged-app menu path is still pending.
On 2026-04-16, the test suite's persistence isolation was hardened so `swift test` no longer touches the real `~/Library/Application Support/Quickey/shortcuts.json`. A shared `Tests/QuickeyTests/TestSupport/TestPersistenceHarness.swift` now vends temporary-directory-backed `PersistenceService` instances, the `ShortcutManager` / `AppPreferences` / `SettingsViewLifecycleHandler` / `ShortcutEditorState` test helpers now use that harness instead of live `PersistenceService()` defaults, and a regression test (`helperBuiltShortcutManagerCanPersistIntoInjectedHarness`) now guards the injected-storage path explicitly. This was verified by a passing full `swift test` run and identical pre/post `shasum` values for the real user shortcut payload.
On 2026-04-15, issue #134 narrowed Input Monitoring prompting to actual Hyper transport demand: startup now inspects the saved shortcut set plus persisted Hyper state before deciding whether to call `CGRequestListenEventAccess()`, runtime route changes (enabling Hyper, or adding/enabling Hyper-routed shortcuts) now trigger the prompt and event-tap resync only when the configuration crosses from standard-only into Hyper-required, and Hyper-required startup now defers the Input Monitoring request until Accessibility has actually been granted so the follow-up AX poll can re-prompt Input Monitoring reliably. macOS runtime validation for the new permission-prompt timing is now complete for the standard-only and Hyper-only paths below.
On 2026-04-09, toggle reliability recovery moved lifecycle ownership fully into `ToggleSessionCoordinator`: launch / activate / stable / deactivation state is now pid-aware, attempt-scoped, and no longer split between coordinator and `AppSwitcher`. Regular apps now require usable window evidence (`visibleWindowCount > 0` or focused/main-window evidence) before toggle-on can be recorded as stable success; only non-regular apps may succeed windowlessly. The same recovery also added attempt-linked `TOGGLE_TRACE_*` and accepted-trigger `SHORTCUT_TRACE_*` diagnostics so one log window can explain branch choice, reset reason, and confirmation outcome end-to-end.
On 2026-04-08, launch-at-login presentation was hardened so `SMAppService.Status.notFound` is no longer always treated as a packaging failure: when Quickey is running outside `/Applications` or `~/Applications`, the General tab now shows install-location guidance instead of the red bundle-misconfiguration warning.
On 2026-04-08, local DMG packaging and a tag-driven GitHub release workflow were added. The repo can now build `build/Quickey-<version>.dmg` locally and defines the credential-backed notarization/publish path. On 2026-04-08, the release workflow was further hardened to preflight required signing/notarization secrets and skip cleanly with a summary when Developer ID credentials are absent, and a separate internal-package workflow was added to upload unsigned DMG artifacts for trusted testers. The internal workflow now also maintains a stable `internal-downloads` tag-backed prerelease page with tester-facing install notes and the latest internal DMG asset, instead of deleting and recreating the release each run.
On 2026-04-09, packaged-app runtime validation moved past the original TCC blocker after `build/Quickey.app` was re-added to Accessibility and Input Monitoring. Manual Safari validation on the packaged app now shows the owned launch / relaunch path attaching the launched process back to the same attempt (`TOGGLE_TRACE_SESSION ... event=launch_attached reason="launch_completion_process_lookup"`), frontmost-without-window states staying in visibility recovery (`TOGGLE_TRACE_CONFIRMATION ... event=awaiting_window_evidence`) until usable window evidence appears, and second press hiding cleanly via `TOGGLE_HIDE_CONFIRMED` instead of falling through to `hide_untracked`. A follow-up investigation also closed the earlier `carbon=false eventTap=true` mystery after restart: at that point Safari itself was Hyper-routed, so the event-tap path was the correct transport. The current local fixture has since moved to a mixed transport setup (`command + shift + s` for Safari plus a Hyper-routed IINA shortcut), and the latest packaged-app verification now shows `checkPermission: ax=true im=true carbon=true eventTap=true` together with clean `TOGGLE_STABLE` / `TOGGLE_HIDE_CONFIRMED` chains and no fresh degraded/session-reset signatures in the recent log window.

## Automated Verification

### 2026-04-09
- `swift test` passed; the suite reported 187 tests passed
- `swift test --filter AppSwitcherTests` passed
- `swift test --filter AppControllerTests` passed
- `swift test --filter ShortcutManagerStatusTests` passed
- `swift test --filter ToggleSessionCoordinatorTests` passed
- `swift test --filter ToggleLaunchLifecycleTests` passed
- `bats scripts/e2e-lib.bats` passed
- `bash scripts/package-app.sh` passed, rebuilt `build/Quickey.app`, and re-signed it with the local `Quickey` identity
- `codesign --verify --deep --strict --verbose=2 build/Quickey.app` passed
- `bash scripts/e2e-full-test.sh` failed at packaged-app runtime preflight because TCC was not granted for `build/Quickey.app` in this environment (`trusted=false`, `ax=false`, `im=false`, event tap never started)
- a follow-up packaged-app spot-check validated standard external activation against the current `command + shift + s` Safari shortcut: `MATCHED`, `TOGGLE_TRACE_DECISION event=hide_untracked`, `TOGGLE_HIDE_UNTRACKED`, `HIDE_REQUEST`, and `TOGGLE_HIDE_CONFIRMED` all appeared with the same non-nil `attemptId` / `pid` / `phase`
- after the E2E harness was updated to use transport-aware readiness plus config-aware module skips, `bash scripts/e2e-full-test.sh` passed on the local fixture
- with the current mixed saved fixture (`Safari` standard + `IINA` Hyper), `bash scripts/e2e-full-test.sh` passed with `6/6 PASS` and `0 warnings`

### 2026-04-15
- `swift test --filter ShortcutManagerStatusTests` passed; the suite reported 15 tests passed, including the new startup deferral regression case
- `swift test` passed; the suite reported 199 tests passed
- `bash scripts/package-app.sh` passed, rebuilt `build/Quickey.app`, and re-signed it with the local `Quickey` identity
- After `tccutil reset All com.quickey.app`, packaged `build/Quickey.app` cold-started under the Hyper-only IINA fixture with `start(): ready=false, ax=false, im=false, inputMonitoringRequired=true`
- After enabling Accessibility later on that same packaged build, the follow-up permission poll logged `Accessibility permission: granted`, `Input Monitoring permission: granted`, `Event tap started (background thread)`, and `attemptStart: shortcuts=1 triggerIndex=1 carbon=false eventTap=true`
- `bash scripts/e2e-test-hyper-key.sh` passed on the packaged build after that AX-grant recovery path (`7 passed`)
- After restoring the local standard-only Safari fixture, `bash scripts/e2e-full-test.sh` passed on the packaged build with `All 6 tests passed (1 warnings)`; the Hyper module warning was an expected fixture skip because the temporary IINA Hyper shortcut had been removed

### 2026-04-16
- `swift test --filter ShortcutManagerStatusTests` passed; the suite reported 16 tests passed, including the new partial-Carbon-registration regression coverage for issue #135
- `swift test --filter handleAppDidBecomeActiveRefreshesShortcutCaptureAndLaunchAtLoginStatus` failed first, then passed after the issue #136 lifecycle fix was applied
- `swift test --filter LaunchAtLogin` passed; the suite reported 18 launch-at-login focused tests passed, including the new menu-bar title/availability coverage for issue #137
- `swift test --filter SettingsView` passed
- `swift test --filter AppPreferences` passed
- `swift test` passed; the suite reported 208 tests passed
- `bash scripts/package-app.sh` passed and rebuilt `build/Quickey.app` after the issue #137 menu-bar change
- `bash scripts/e2e-full-test.sh` passed on packaged `build/Quickey.app` with the current standard-only Safari fixture (`6/6 PASS`, `1 warning` because the Hyper module was a configuration skip)
- after temporarily swapping `~/Library/Application Support/Quickey/shortcuts.json` to a mixed fixture (`Safari` standard + `IINA` Hyper) and restoring the user's original file afterward, `bash scripts/e2e-full-test.sh` passed again on packaged `build/Quickey.app` with `6/6 PASS` and `0 warnings`
- after temporarily swapping `~/Library/Application Support/Quickey/shortcuts.json` to the same mixed fixture, `tccutil reset All com.quickey.app` produced a packaged-app cold start with the Settings banner showing `Accessibility permission required` / `Accessibility permission is required for app switching.`
- after re-granting permissions in System Settings and clicking back into the same packaged Quickey Settings window without using the banner's `Refresh` button, AX inspection of the live SwiftUI window reported `Shortcut capture ready` / `Standard and Hyper shortcuts are active.`
- the same permission-flip run logged `Accessibility permission: granted`, `Input Monitoring permission: granted`, `Accessibility ready — syncing shortcut capture`, `Event tap started (background thread)`, and `attemptStart: shortcuts=2 triggerIndex=2 carbon=true eventTap=true`
- A targeted issue #135 runtime probe temporarily rewrote `shortcuts.json` to exercise partial standard-registration failure. Common system-reserved shortcuts (`command-space`, `control-space`, screenshot shortcuts, `command-tab`) and a separate helper process holding `command-shift-t` all still let Quickey report `carbon=true` on this machine, so a live Carbon conflict reproduction remains pending even though the packaged-app E2E suite and code-level regression coverage both passed.
- Packaged-app manual runtime validation for issue #133 passed with three startup fixtures written directly to `~/Library/Application Support/Quickey/shortcuts.json` one at a time, restoring the user's original fixture afterward:
  - malformed JSON payload
  - payload missing `isEnabled`
  - unsupported wrapper schema (`{"schemaVersion":2,"shortcuts":[]}`)
- In all three cases Quickey logged `Failed to load shortcuts: path=... reason=... preservedCopyPath=...`, logged `Startup skipped shortcut restore because persistence loading failed`, kept running after launch, and reported `attemptStart: shortcuts=0 triggerIndex=0 carbon=false eventTap=false`
- In all three cases Quickey created exactly one `shortcuts.load-failure-*.json` copy, that copy matched the unreadable source payload byte-for-byte, and the original `shortcuts.json` remained unchanged both while the app was running and after it exited
- `swift test --filter PersistenceServiceDiskLoadingTests` passed; the suite reported 5 tests passed, including the new shared temporary-storage harness coverage
- `swift test --filter helperBuiltShortcutManagerCanPersistIntoInjectedHarness` passed
- `swift test` passed; the suite reported 214 tests passed
- `shasum ~/Library/Application\ Support/Quickey/shortcuts.json` was identical before and after `swift test`, confirming the test suite no longer mutates the live user shortcut fixture

### 2026-04-08
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
- On 2026-04-09, packaged `build/Quickey.app` was manually revalidated for Safari fresh-launch and relaunch after TCC was granted:
  - fresh launch produced `event=session_started activationPath=launch`, `event=launch_attached reason="launch_completion_process_lookup"`, `event=awaiting_window_evidence`, then `event=confirmed reason="activation_stable"`
  - the next press produced `TOGGLE_HIDE_ATTEMPT`, `HIDE_REQUEST`, and `TOGGLE_HIDE_CONFIRMED` with Finder frontmost afterward
  - relaunch after termination produced `TOGGLE_TRACE_RESET ... reason="termination"`, then a new owned `launch` attempt with a new pid, followed by the same stable-confirmed -> hide-confirmed sequence
- On 2026-04-09, packaged `build/Quickey.app` was also manually revalidated for Safari external activation under the current Hyper configuration:
  - externally fronting Safari, then triggering the persisted Hyper shortcut, produced `TOGGLE_TRACE_DECISION event=hide_untracked reason="external_untracked_hide"`, followed by a real `HIDE_REQUEST` and `TOGGLE_HIDE_CONFIRMED`
  - the current packaged-app configuration is Hyper-routed, so `checkPermission: ax=true im=true carbon=false eventTap=true` is expected in that state, not a Carbon regression
- On 2026-04-09, packaged `build/Quickey.app` was then manually revalidated again for Safari external activation after switching the persisted shortcut back to the standard `command + shift + s` route:
  - externally fronting Safari, then triggering the standard shortcut, produced `MATCHED`, `TOGGLE_TRACE_DECISION event=hide_untracked`, `TOGGLE_HIDE_UNTRACKED`, `HIDE_REQUEST`, and `TOGGLE_HIDE_CONFIRMED`
  - the very first `hide_untracked` trace and lifecycle lines now carried the same non-nil `attemptId`, `pid`, and `phase=deactivating` as the later hide request / confirmation lines, confirming that the coordinator-owned deactivation session is allocated before logging that branch
- On 2026-04-09, the frontmost/no-window policy was also observed live on Safari: Quickey logged `awaiting_window_evidence` and recovery stages while Safari was frontmost without usable window evidence, and only promoted to stable once visible/focused/main-window evidence appeared
- On 2026-04-09, a later mixed-transport validation pass also exercised Safari standard toggles and IINA Hyper toggles in the same packaged session:
  - the saved shortcut fixture contained both Safari standard and IINA Hyper bindings, so `checkPermission: ax=true im=true carbon=true eventTap=true` was the expected steady-state readiness snapshot
  - the recent runtime log window showed repeated `TOGGLE_STABLE` -> `TOGGLE_HIDE_CONFIRMED` pairs for both apps, plus expected cooldown blocks under rapid repeat input, but no fresh `TOGGLE_DEGRADED`, `TOGGLE_HIDE_DEGRADED`, `phase=no_session`, `hide_untracked`, or capture-blocked signatures
- On 2026-04-15, issue #134's permission-scope change was revalidated on packaged `build/Quickey.app` in both transport modes:
  - with the restored standard-only Safari fixture, Quickey was previously revalidated under `tccutil reset All` followed by granting only Accessibility, producing `checkPermission: ax=true im=false carbon=true eventTap=false` and a passing `bash scripts/e2e-full-test.sh` run with the Hyper module skipped as configuration-only
  - with a temporary Hyper-only IINA fixture, a fresh `tccutil reset All` cold start produced `start(): ready=false, ax=false, im=false, inputMonitoringRequired=true`; granting Accessibility later in the same session then produced `Input Monitoring permission: granted`, `Event tap started (background thread)`, and a passing `bash scripts/e2e-test-hyper-key.sh`
- On 2026-04-16, issue #133's persistence failure handling was manually revalidated on packaged `build/Quickey.app`:
  - malformed JSON, missing-`isEnabled`, and unsupported-schema fixtures all produced a startup-time `Failed to load shortcuts` log with `path`, `reason`, and `preservedCopyPath`
  - Quickey kept running after each failed load and started with `attemptStart: shortcuts=0 triggerIndex=0 carbon=false eventTap=false`, confirming that unreadable persistence no longer materializes as an in-memory shortcut set
  - each failed load preserved a byte-identical `shortcuts.load-failure-*.json` copy and left the original `shortcuts.json` untouched

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
- `ToggleSessionCoordinator` is now the canonical toggle owner: launch / activate / stable / deactivating state, pid rollover handling, and durable `previousBundle` memory no longer depend on split local `AppSwitcher` state
- Relaunches now allocate an owned `launching` session before `NSWorkspace` open returns, so the next press cannot fall through to `hide_untracked` merely because the process was between lifetimes
- `NSWorkspace.openApplication` completion is now used as a process-identity seam: the returned `NSRunningApplication` feeds pid attachment and the same confirmation pipeline used by activate/unhide, instead of leaving launch as fire-and-forget
- Regular apps cannot silently succeed toggle-on without usable window evidence; only targets with `activationPolicy != .regular` may remain stable without visible/focused/main-window proof
- `hide_untracked` now creates an explicit coordinator-owned `deactivating` session before dispatching `hide()`, so external activation still gets a real `HIDE_REQUEST` / confirmation pair instead of only logging the branch

## Toggle Reliability Recovery (2026-04-09)
- `ToggleSessionCoordinator` now owns pid-aware attempt sessions with explicit `launching`, `activating`, `activeStable`, `deactivating`, `degraded`, and `idle` phases.
- `AppSwitcher` derives pending/stable views from the coordinator instead of keeping its own mutable lifecycle owner.
- `ToggleDiagnosticEvent` centralizes `TOGGLE_TRACE_*` formatting so attempt-linked branch logs stay cheap and consistent.
- `ShortcutManager` emits `SHORTCUT_TRACE_*` only for matched shortcuts or explicit blocked-capture states, not for unrelated key events.

### Trace signatures to treat as success
- Toggle-on settled: `TOGGLE_TRACE_CONFIRMATION attemptId=... event=confirmed reason="activation_stable"`
- Toggle-off settled: `TOGGLE_TRACE_CONFIRMATION attemptId=... event=confirmed reason="hide_confirmed"`
- Owned launch path started correctly: `TOGGLE_TRACE_SESSION attemptId=... event=session_started activationPath=launch reason="not_running_launch_request"`
- Owned launch attached to the real process: `TOGGLE_TRACE_SESSION attemptId=... event=launch_attached activationPath=launch reason="launch_completion_process_lookup"`
- Hyper-routed IINA in the current local config: `SHORTCUT_TRACE_DECISION event=matched bundle=com.colliderli.iina route=hyper`

### Trace signatures to treat as failure or follow-up
- Regular app frontmost but still unusable: `TOGGLE_TRACE_CONFIRMATION attemptId=... event=awaiting_window_evidence reason="frontmost_without_window_evidence"`
- Hide request degraded instead of settling: `TOGGLE_TRACE_CONFIRMATION attemptId=... event=degraded reason="partial_hide_degraded"`
- Session reset: `TOGGLE_TRACE_RESET attemptId=... event=session_cleared reason="termination" | "pid_rollover" | "launch_failed" | "activation_recovery_exhausted"`
- Stale tracking corrected: `TOGGLE_TRACE_RESET attemptId=... event=session_invalidated reason="stale_state_invalidated"`
- Capture path blocked before toggle dispatch: `SHORTCUT_TRACE_BLOCKED reason="missing_registration_or_system_conflict" | "input_monitoring_missing" | "event_tap_inactive"`

### Trace signatures that are only valid in specific ownership cases
- `TOGGLE_TRACE_DECISION event=hide_untracked reason="external_untracked_hide"` is acceptable only for genuinely external activation. It is a regression if it appears immediately after an owned launch or relaunch.
- When `hide_untracked` is valid, it must still be followed by a real hide lane (`HIDE_REQUEST` and `TOGGLE_HIDE_CONFIRMED` or explicit degraded confirmation). A lone `hide_untracked` log without a deactivation session is a bug.
- `TOGGLE_TRACE_DECISION event=blocked reason="activation_pending_not_stable"` is the correct second-press behavior while an owned launch/activation is still settling.
- `checkPermission: ax=true im=true carbon=false eventTap=true` is only suspicious if the current enabled shortcut set is supposed to be standard-only. If the persisted shortcut is Hyper-routed and `hyperKeyEnabled` is on, that snapshot is expected.
- `checkPermission: ax=true im=true carbon=true eventTap=true` is the expected steady-state snapshot when the saved fixture mixes standard and Hyper shortcuts.
- `scripts/e2e-full-test.sh` and `scripts/e2e-lib.sh` now preflight packaged-app startup with transport-aware readiness: standard-only configs accept `carbon=true eventTap=false`, Hyper-only configs require an active event tap, and mixed fixtures require both transports to be ready before modules start.
- E2E modules should treat missing fixture shortcuts as configuration skips, not runtime failures. When both Safari standard and IINA Hyper are present in `shortcuts.json`, the current local full suite should run without warnings.

## Follow-up Requiring macOS Validation
- If you want to validate one transport in isolation, trim the saved fixture to that transport first. The current local fixture is mixed, so combined validation should expect both Carbon and event-tap readiness.
- Fresh-launch path
  Validate: target not running -> shortcut launches it -> second press hides it without `hide_untracked` or `phase=no_session`
- Relaunch path
  Validate: target stabilizes -> target quits -> shortcut relaunches it -> second press still hides cleanly
- External activation path
  Validate: user fronts the target outside Quickey -> Quickey only uses `hide_untracked` when the session is truly unowned, and that branch still emits a real `HIDE_REQUEST` / `TOGGLE_HIDE_CONFIRMED` pair
- Frontmost/no-window path
  Validate: target becomes frontmost without visible/focused/main-window evidence -> Quickey stays in visibility recovery or degraded state instead of recording stable success
- Hotkey-latency regression
  Validate: repeated matched shortcuts do not show perceptible latency after the new attempt/session diagnostics
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
- Standard Carbon partial-registration conflict path
  Validate that when one standard binding is blocked by an actual Carbon/system shortcut conflict, Quickey reports `carbon=false`, keeps `standardShortcutsReady=false`, surfaces the banner warning, and logs the failed keyCode/modifier tuple in `SHORTCUT_TRACE_BLOCKED`
- Launch-at-login approval flow after the 2026-03-23 issue #67 approval-state UX update and the 2026-04-16 issue #137 menu-bar fix, especially `.requiresApproval` -> `.enabled` foreground refresh, the menu-bar Login Items CTA path, and `.notFound` behavior on real installs
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
- The new 2026-04-09 attempt/session diagnostics, launch attachment, and untracked-hide session ownership are implemented and test-covered, and Safari fresh-launch / relaunch / external-activation were manually validated on packaged `build/Quickey.app`; broader app-matrix and standard-vs-Hyper parity work still remain
- Event tap recovery semantics are implemented with thresholded escalation and degraded reporting, but a reproducible on-device timeout-stress run is still needed to confirm the live logs are operationally sufficient
- Signed/notarized release validation is still blocked on Developer ID availability; until those credentials exist, only the internal-package DMG artifact path can be verified end-to-end

## Immediate Next Actions
1. Keep the intended shortcut fixture explicit before interpreting readiness logs. The current local fixture is mixed (Safari standard + IINA Hyper), so `carbon=true eventTap=true` and a warning-free `bash scripts/e2e-full-test.sh` run are now the expected baseline.
2. Expand the targeted macOS validation matrix from the now-confirmed Safari fresh-launch / relaunch / external-activation paths to Finder, Terminal, Home, Clock, System Settings, hidden/minimized paths, and event-tap timeout stress
3. Verify standard-shortcut vs Hyper parity on the same target apps beyond the already revalidated Safari cases, and capture any remaining app-specific exceptions in this file
4. Use the internal-package workflow for tester-facing DMG artifacts until Developer ID credentials are available
5. Run the DMG release workflow with real Developer ID and notary credentials on a `v*` tag once those credentials exist
6. Validate the published DMG on a clean macOS machine and confirm drag-install to `/Applications`
7. Fold any new validation findings back into this note, not into the feature overview docs
