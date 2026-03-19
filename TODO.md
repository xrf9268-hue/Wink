# TODO

This file is the high-level execution board.
For detailed tasks, use the GitHub issues and `docs/issue-priority-plan.md`.

## Tier 0 — validate the app on real macOS
- [ ] Compile on macOS
- [ ] Run tests on macOS
- [ ] Package a runnable `.app`
- [ ] Grant permission and verify global shortcut capture end to end
- [ ] Validate toggle behavior against real apps

## Tier 1 — runtime reliability and architecture correctness
- [ ] Align the permission model with the actual CGEvent tap monitoring path
- [ ] Tighten event tap lifecycle ownership and cleanup
- [ ] Handle event tap disabled/timeout recovery
- [ ] Recover shortcut monitoring after permission changes without relaunch
- [ ] Replace linear shortcut scans with a precompiled trigger index
- [ ] Reduce unnecessary MainActor pressure in runtime shortcut services

## Tier 2 — validation depth and test confidence
- [ ] Add focused tests for key mapping, conflict logic, and toggle behavior
- [ ] Add a repeatable macOS build-validation path or CI baseline

## Tier 3 — product behavior and interaction quality
- [ ] Improve shortcut recorder UX
- [ ] Improve toggle behavior for minimized/full-screen/multi-window cases
- [ ] Improve Hyper-style shortcut support and validation
- [ ] Decide the app-shell direction: modern SwiftUI scene-based vs deliberate AppKit-first

## Tier 4 — packaging and product polish
- [ ] Automate `.app` packaging end to end
- [ ] Add launch-at-login support
- [ ] Add app icon and polish bundle metadata

## Tier 5 — release hardening and identity
- [ ] Document signing/notarization and release workflow
- [ ] Rename the project after product naming is finalized
