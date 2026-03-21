# TODO

This file is the high-level execution board.
For detailed tasks, use GitHub Issues. Historical completion log: `docs/archive/issue-priority-plan.md`.

## Tier 0 — validate the app on real macOS
- [x] Compile on macOS (Swift 6 strict concurrency fixed in #21)
- [x] Run tests on macOS (comprehensive tests added in #30, CI added in #39)
- [x] Package a runnable `.app` (packaging automated in #38)
- [x] Grant permission and verify global shortcut capture end to end (validated 2026-03-20, dual permission Accessibility + Input Monitoring)
- [x] Validate toggle behavior against real apps (validated 2026-03-20, fixed: unminimize, no-window ⌘N, autorepeat filter)

## Tier 1 — runtime reliability and architecture correctness
- [x] Align the permission model with the actual CGEvent tap monitoring path (#23)
- [x] Tighten event tap lifecycle ownership and cleanup (#25)
- [x] Handle event tap disabled/timeout recovery (#26)
- [x] Recover shortcut monitoring after permission changes without relaunch (#28)
- [x] Replace linear shortcut scans with a precompiled trigger index (#27)
- [x] Reduce unnecessary MainActor pressure in runtime shortcut services (#32)

## Tier 2 — validation depth and test confidence
- [x] Add focused tests for key mapping, conflict logic, and toggle behavior (#30)
- [x] Add a repeatable macOS build-validation path or CI baseline (#39)

## Tier 3 — product behavior and interaction quality
- [x] Improve shortcut recorder UX (#37)
- [x] Improve toggle behavior for minimized/full-screen/multi-window cases (#34)
- [x] Improve Hyper-style shortcut support and validation (#33, #36)
- [x] Decide the app-shell direction: modern SwiftUI scene-based vs deliberate AppKit-first (#24)

## Tier 4 — packaging and product polish
- [x] Automate `.app` packaging end to end (#38)
- [x] Add launch-at-login support (#31)
- [x] Add app icon and polish bundle metadata (#48)

## Tier 5 — release hardening and identity
- [x] Document signing/notarization and release workflow (#49)
- [x] Rename the project after product naming is finalized (#50, #51)

## Post-Tier 5 — additional features shipped
- [x] UsageTracker service with SQLite daily aggregation (#44)
- [x] Insights tab with trend chart and app ranking (#47)
- [x] SettingsView refactored into tabbed layout (Shortcuts / General / Insights) (#45, #46)

## Remaining
- [x] Real macOS device validation — core flows verified 2026-03-20
- [x] Toggle stability refactor: async event tap, three-layer activation, windowless recovery (#57)
- [x] Hyper Key: built-in Caps Lock mapping via hidutil + CGEvent tap (#56)
- [x] Logging redesign: DiagnosticLog + os.log per Apple best practices (#55)
- [ ] Signed/notarized distributable build (workflow documented in #49, execution pending)
- [ ] Re-run targeted macOS validation for the 2026-03-21 remediation set:
  launch-at-login approval UI, active event tap readiness, Hyper Key failure handling, and Insights date/race fixes
