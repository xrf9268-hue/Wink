# AGENTS.md

Agent guidance for working on **Quickey**.

## Project overview

Quickey is a macOS menu bar utility that binds global shortcuts to target apps with Thor-like toggle semantics.

Use this file as a concise operating guide. Treat the detailed repository docs as the system of record:
- `docs/architecture.md` for architecture and module responsibilities
- `docs/README.md` for maintainer navigation
- `docs/handoff-notes.md` for recent validation status and open follow-up work
- `docs/lessons-learned.md` for operational and troubleshooting lessons
- `docs/loop-prompt.md` and `docs/loop-job-guide.md` for review gates and automation workflow

## Environment and platform constraints

- macOS 15+, Swift 6, SPM-first structure
- This workspace may be edited from Linux, but the app **cannot be fully validated there**
- Final build, permission, event-monitoring, and runtime behavior must be tested on macOS
- GitHub Actions can verify build/test/package on macOS, but not replace manual validation for TCC, event taps, login items, or app activation behavior
- Do not claim macOS correctness from Linux-only inspection

## Build and test commands

```bash
swift build
swift test
swift build -c release
./scripts/package-app.sh
cp .build/release/Quickey build/Quickey.app/Contents/MacOS/Quickey
```

If working from a non-macOS host: state clearly that build/runtime validation is pending.

## Architecture expectations

The codebase is feature-complete. Key architectural decisions:
- AppKit-first, selective SwiftUI (documented in `docs/archive/app-structure-direction.md`); for new app-shell work, evaluate `MenuBarExtra`/`Settings`/`openSettings` first
- O(1) precompiled trigger index for hot-path matching
- Standard shortcuts use Carbon `EventHotKey`; Hyper-dependent shortcuts use the active event tap
- EventTap lifecycle hardened with auto-recovery
- SkyLight private API (`_SLPSSetFrontProcessWithOptions`) for app activation: on macOS 15, the `NSApplicationActivateIgnoringOtherApps` option flag is deprecated since macOS 14.0 with **no effect** (Apple SDK: `API_DEPRECATED("ignoringOtherApps is deprecated in macOS 14 and will have no effect.", macos(10.6, 14.0))`). The cooperative model (`yieldActivation(to:)` + `activate(from:options:)`, both `API_AVAILABLE(macos(14.0))`) requires the currently active app to explicitly yield, which is impossible for an accessory utility like Quickey that doesn't control other apps. `NSRunningApplication.activate(options:)` without the flag is a cooperative request that the system may decline. SkyLight is the only reliable way for an `LSUIElement` app to force-activate arbitrary targets.
- For self-activation (e.g., showing the settings window), use `NSApp.activate()` (`API_AVAILABLE(macos(14.0))`). Do not use the soft-deprecated `activateIgnoringOtherApps:` (`API_DEPRECATED("This method will be deprecated in a future release. Use NSApp.activate instead.")`)
- Shortcut readiness is transport-specific, not just permission state: standard shortcuts require Accessibility plus successful Carbon registration; Hyper shortcuts additionally require `CGPreflightListenEventAccess()` and a successfully started active event tap
- Do not reintroduce passive `.listenOnly` fallback for normal shortcut interception; it cannot consume events (Apple SDK: `kCGEventTapOptionListenOnly = 0x00000001` is a passive listener)
- Preserve multi-state system API semantics when behavior/UI depends on them; do not collapse `SMAppService.Status` to a single bool

Before making large structural changes, read `docs/architecture.md`.

## App activation semantics (Apple SDK verified)

- `NSRunningApplication.activate(options:)` and `hide()` are **asynchronous requests**, not immediate state changes (Apple SDK on `activateFromApplication:options:`: "You shouldn't assume the app will be active immediately after sending this message. The framework also does not guarantee that the app will be activated at all."). Always confirm the result via observation, not assumption.
- `NSRunningApplication` properties (`isActive`, `isHidden`, etc.) are consistent **within** the current main run loop turn (Apple SDK: "properties persist until the next turn of the main run loop in a common mode"). `NSRunningApplication` is thread safe (properties returned atomically), but time-varying properties follow the main run loop policy. This justifies `@MainActor` for `AppSwitcher`.
- `isActive` = "Indicates whether the application is currently frontmost" (Apple SDK). `NSWorkspace.shared.frontmostApplication` is the workspace-level source of truth. Use `isActive`/`isHidden` as supporting signals, not sole toggle-off gates.
- macOS 15 cooperative activation (`yieldActivation(to:)` + `activate(from:options:)`) requires the **currently active app** to explicitly yield. An accessory/LSUIElement app cannot force other apps to yield. SkyLight `_SLPSSetFrontProcessWithOptions` is the only reliable forced-activation path.
- `SetFrontProcessWithOptions` and `GetProcessForPID` (Carbon/HIServices) are deprecated since macOS 10.9 (`AVAILABLE_MAC_OS_X_VERSION_10_0_AND_LATER_BUT_DEPRECATED_IN_MAC_OS_X_VERSION_10_9`). SkyLight requires PSN from `GetProcessForPID`; there is no modern replacement for obtaining a PSN. This is a necessary trade-off for reliable activation.

## Toggle state management

- Apps can become frontmost through paths Quickey does not control (Dock click, Cmd-Tab, macOS choosing the next app after a hide, or another app flow returning them). Do not assume every frontmost app was activated by Quickey.
- The `ACTIVE_UNTRACKED` path handles apps that are active+frontmost but have no `stableActivationState` or `pendingActivationState`. It hides the app and lets macOS choose the next foreground app. This is the correct fallback when tracking state is missing.
- `previousApp` session context can self-reference the target bundle. Always guard `previousApp != shortcut.bundleIdentifier` before recording or using it.
- Session-owned `previousBundle` in `ToggleSessionCoordinator` is durable activation/deactivation context. `FrontmostApplicationTracker` captures snapshots; the coordinator owns the value across phases.
- Toggle cooldown (400ms per-bundle) and debounce (200ms) are safety nets behind the primary Layer 1 autorepeat filter (`kCGKeyboardEventAutorepeat`). Changes to these values require verification via `scripts/e2e-full-test.sh` and physical key repeat testing.

## Concurrency and actor boundaries

- Do not use `@MainActor` as the default for non-UI code
- Keep UI/window/SwiftUI state on the main actor
- `AppSwitcher` is `@MainActor` because `NSRunningApplication` property consistency is tied to the main run loop (see "App activation semantics" above)
- Runtime logic (matching, indexing, event-processing) should justify any main-actor coupling
- Completion handlers from system APIs (e.g., `NSWorkspace.openApplication`) call back on background queues; extract values and mark `@Sendable`

## What to optimize first

1. Correctness
2. Runtime reliability
3. Focused tests around core behavior
4. Performance on real hot paths
5. UX polish
6. Packaging and release polish

## Testing guidance

Highest-value test targets:
- Key mapping and conflict detection
- Trigger indexing
- Toggle behavior logic
- Permission/lifecycle behavior where test seams exist
- Date-window boundary semantics for Insights/usage queries
- Async view-model refresh ordering and cancellation ("last selection wins")

If a change cannot be verified on Linux, document what must be verified on macOS.
- End-to-end shortcut testing on macOS: `osascript` key events are useful for driving the live shortcut pipeline; `cliclick` does not cover the same path reliably. Use `osascript -e 'tell application "System Events" to key code ...'` for E2E validation of shortcut capture → match → toggle, and remember that Hyper coverage still exercises the event-tap path while standard shortcuts route through Carbon.
- `kCGKeyboardEventAutorepeat` (Apple SDK: "non-zero when this is an autorepeat of a key-down") must be filtered in the event tap callback to prevent held-key loops.

## macOS runtime validation policy

Runtime-sensitive changes = event taps, app activation, permissions/TCC, Accessibility/Input Monitoring, login items, launch behavior, packaging/signing.

- Development merges may rely on CI + review gates alone
- Runtime-sensitive PRs must carry `macOS runtime validation pending` until validated on macOS, then update to `macOS runtime validation complete`
- Release-candidate signoff requires all pending items validated
- Never rewrite history to imply pending validation was completed

## Investigation before implementation

- Do not change code before you understand the failure mode or behavior gap.
- Read logs, inspect the relevant code, reproduce the issue where possible, and verify your assumptions before editing.
- Avoid speculative fixes. If the root cause is still uncertain, write down the hypothesis and prove or disprove it with logs, tests, or targeted instrumentation.
- When working with system APIs, external commands, or permission state, verify the actual platform semantics first. Do not confuse "can observe" with "can intercept", and do not confuse "permission granted" with "feature ready".

## Editing rules

- Keep changes focused; avoid broad refactors unless clearly justified
- Do not silently rename the product, bundle identifiers, or repo-wide strings
- Do not introduce private API paths by default (SkyLight usage is a documented exception)
- Do not claim App Store safety unless actually verified
- For user-visible state that depends on external side effects (for example `hidutil` mappings or login-item registration), persist the state only after the underlying operation succeeds

## Documentation rules

If you materially change architecture, workflow, or validation expectations, update the relevant docs.

Key docs to update after meaningful changes:
- `README.md`
- `docs/README.md`
- `docs/architecture.md`
- `docs/handoff-notes.md`
- `docs/loop-prompt.md` and `docs/loop-job-guide.md` (if changing review gates or automation workflow)

## Source of truth for planning

1. GitHub Issues are the only planning and task-tracking source of truth.
2. `docs/handoff-notes.md` provides supporting context for current state, validation, and follow-up work.
3. `docs/README.md` provides maintainer navigation and entry points, not planning status.

Historical completion logs are in `docs/archive/issue-priority-plan.md`.
