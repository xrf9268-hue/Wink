# AGENTS.md

Agent guidance for working on **Quickey**.

## Project overview

Quickey is a macOS menu bar utility that binds global shortcuts to target apps with Thor-like toggle semantics.

Use this file as a concise operating guide. Treat the detailed repository docs as the system of record:
- `docs/architecture.md` for architecture and module responsibilities
- `TODO.md` for current priorities
- `docs/handoff-notes.md` for recent validation status, open follow-up work, and operational lessons

## Environment and platform constraints

- macOS 14+, Swift 6, SPM-first structure
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
- EventTap lifecycle hardened with auto-recovery
- SkyLight private API for app activation (unreliable `NSRunningApplication.activate()` on macOS 14+)
- Shortcut readiness is not just permission state: require `AXIsProcessTrusted()`, `CGPreflightListenEventAccess()`, and successful active event-tap startup
- Do not reintroduce passive `.listenOnly` fallback for normal shortcut interception; it cannot consume events
- Preserve multi-state system API semantics when behavior/UI depends on them; do not collapse `SMAppService.Status` to a single bool

Before making large structural changes, read `docs/architecture.md`.

## Concurrency and actor boundaries

- Do not use `@MainActor` as the default for non-UI code
- Keep UI/window/SwiftUI state on the main actor
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
- `TODO.md`
- `docs/architecture.md`
- `docs/handoff-notes.md`

Keep `TODO.md` high-level. Do not duplicate the full issue tracker.

## Source of truth for planning

1. GitHub Issues
2. `TODO.md`
3. `docs/handoff-notes.md`

Historical completion logs are in `docs/archive/issue-priority-plan.md`.
