# AGENTS.md

Agent guidance for working on **Quickey**.

## Project overview

Quickey is a macOS menu bar utility that binds global shortcuts to target apps with Thor-like toggle semantics.

Current state (as of 2026-03-20):
- All originally planned issues (Tier 0-5) resolved
- Real-device validation completed on macOS 15.3.1
- Core flows verified: build, permissions, shortcut recording, toggle, Hyper Key, Insights
- SkyLight private API used for reliable app activation from LSUIElement background
- Dual permission model: Accessibility + Input Monitoring (both required for CGEvent tap on macOS 15)

## Current priorities

1. Remaining GitHub Issues: Launch at Login verification (#58)
2. Signed/notarized distributable build (Developer ID cert required)
3. New feature work or behavior improvements
4. Additional test coverage

## Environment and platform constraints

- macOS 14+, Swift 6, SPM-first structure
- This workspace may be edited from Linux, but the app **cannot be fully validated there**
- Final build, permission, event-monitoring, and runtime behavior must be tested on macOS
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
- Dual permission: `AXIsProcessTrusted()` + `CGPreflightListenEventAccess()`

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

If a change cannot be verified on Linux, document what must be verified on macOS.

## Editing rules

- Keep changes focused; avoid broad refactors unless clearly justified
- Do not silently rename the product, bundle identifiers, or repo-wide strings
- Do not introduce private API paths by default (SkyLight usage is a documented exception)
- Do not claim App Store safety unless actually verified

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
