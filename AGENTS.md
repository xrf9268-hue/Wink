# AGENTS.md

Agent guidance for working on **HotApp Clone**.

This file is for coding agents and automation tools. Use it together with:
- `README.md`
- `docs/README.md`
- `docs/issue-priority-plan.md`
- `docs/codex-review-summary.md`
- `TODO.md`

## Project overview

HotApp Clone is a macOS menu bar utility inspired by Thor and the recovered HotApp article.
It binds global shortcuts to target apps, activates them quickly, and toggles them away when pressed again.

Current state:
- strong prototype scaffold
- not yet validated on a real macOS toolchain
- architecture and issue planning are already established
- runtime reliability and macOS validation are higher priority than adding more speculative features

## Current priorities

Follow this order unless the user explicitly asks otherwise:

1. Real macOS validation
2. Runtime reliability and architecture correctness
3. Tests and repeatable validation
4. Product behavior and interaction quality
5. Packaging and product polish
6. Release hardening and naming

The current execution order is documented in `docs/issue-priority-plan.md`.

## Source of truth for planning

When deciding what to work on next, prefer these files in this order:

1. `docs/issue-priority-plan.md`
2. GitHub issues
3. `TODO.md`
4. `docs/roadmap.md`

Do not invent a new priority order unless the user explicitly asks for a re-prioritization.

## Environment and platform constraints

This repository targets:
- macOS 14+
- Swift 6
- SPM-first structure

Important constraint:
- This workspace may be edited from Linux, but the app **cannot be fully validated here**.
- Final build, permission, event-monitoring, and runtime behavior must be tested on macOS.

Do not claim macOS correctness from Linux-only inspection.

## Build and test commands

Use these commands when running on a machine with Swift/macOS tooling available:

```bash
swift build
swift test
swift build -c release
./scripts/package-app.sh
cp .build/release/HotAppClone build/HotAppClone.app/Contents/MacOS/HotAppClone
```

If working from a non-macOS host without Swift installed:
- do not pretend the project was built successfully
- state clearly that build/runtime validation is still pending on macOS

## Architecture expectations

The current code is a scaffold, not a final architecture.

Before making large structural changes, read:
- `docs/architecture.md`
- `docs/architecture-remediation-plan.md`
- `docs/codex-review-summary.md`

Known architecture themes already identified:
- permission model should align with CGEvent tap monitoring
- event tap lifecycle needs stronger ownership and recovery
- runtime hot path should move away from unnecessary `@MainActor` usage
- linear shortcut scans should become a precompiled trigger index
- app-shell direction should eventually be decided explicitly: modern SwiftUI scene-based vs deliberate AppKit-first

Do not re-discover these as if they were new findings.

## What to optimize first

Prefer improvements in this order:
1. correctness
2. runtime reliability
3. macOS validation
4. focused tests
5. performance improvements on real hot paths
6. UX polish
7. packaging and release polish

Do not prioritize naming, icon polish, or release cosmetics ahead of unresolved runtime-core issues unless the user explicitly asks.

## Performance guidance

For performance-sensitive work, prefer:
- precompiled lookup structures over repeated linear scans in keydown hot paths
- minimizing work done on the main actor during event handling
- explicit lifecycle cleanup for long-lived event infrastructure
- measured, concrete improvements over speculative micro-optimizations

Do not over-optimize persistence or file I/O before fixing event-path reliability.

## Testing guidance

When you change logic, add or update tests where practical.

Highest-value test targets in this repo:
- key mapping
- conflict detection
- trigger indexing
- toggle behavior logic
- permission/lifecycle behavior where test seams exist

If a change cannot be meaningfully verified on Linux, document what must still be verified on macOS.

## Editing rules

- Keep changes focused.
- Avoid broad refactors unless they are clearly justified by the current issue or task.
- Do not silently rename the product, bundle identifiers, or repo-wide strings unless the task is specifically about naming.
- Do not introduce private API paths by default.
- Do not claim App Store safety/compliance unless it has actually been verified.
- Do not remove or contradict the documented issue priority plan without updating the relevant docs.

## Documentation rules

If you materially change architecture, workflow, or validation expectations, update the relevant docs.

Most likely docs to update after meaningful changes:
- `README.md`
- `TODO.md`
- `docs/architecture.md`
- `docs/architecture-remediation-plan.md`
- `docs/codex-review-summary.md`
- `docs/issue-priority-plan.md`
- `docs/macos-validation-checklist.md`

Keep `TODO.md` high-level.
Do not turn `TODO.md` into a duplicate of the full issue tracker.

## Issues and planning

Before opening new issues, check whether the topic is already covered by:
- existing GitHub issues
- `docs/issues-backlog.md`
- `docs/codex-review-summary.md`

If creating a new issue, make it concrete:
- clear goal
- clear done-when conditions
- clear reason it matters

## Good outcomes for agent work

A strong contribution in this repo usually does one or more of the following:
- improves macOS validation readiness
- removes a runtime reliability risk
- makes the event path safer or faster in a meaningful way
- adds focused tests around core behavior
- clarifies the architecture or execution plan without creating doc sprawl

## Bad outcomes to avoid

Avoid these failure modes:
- adding features while leaving known runtime-core problems untouched
- claiming success without macOS validation where macOS validation is required
- adding speculative abstractions without immediate value
- scattering planning updates across multiple docs without keeping them consistent
- making the repo look more polished while the runtime core is still fragile

## Delivery checklist

Before wrapping up a change, check:
- Is the change aligned with the current priority plan?
- Did you update any docs that became stale?
- Did you avoid overstating validation that did not actually happen?
- Did you leave the next contributor with clearer state, not murkier state?
