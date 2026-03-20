# Issue Priority Plan

This plan groups the GitHub issues into a practical execution order with completion status.

## Tier 0 — prove the project is real on macOS ✅ Done
These issues converted the scaffold into a compilable, testable app.

1. ✅ **#1 Compile and validate Quickey on macOS** — Swift 6 strict concurrency fixed (#21), CI passing (#39)
2. ✅ **#2 Fix compile/runtime issues discovered during first macOS build** — EventTap memory leak, silent failure, and deprecation warnings fixed (#22)

Remaining: End-to-end validation on a real macOS device (shortcut capture, toggle, permissions) is still pending.

## Tier 1 — highest-value architecture and runtime reliability upgrades ✅ Done

3. ✅ **#10 Align permission model with CGEvent tap listen-event access APIs** — Switched to Input Monitoring model (#23)
4. ✅ **#12 Tighten EventTap lifecycle ownership and cleanup** — Stricter lifecycle + lifecycle tests added (#25)
5. ✅ **#16 Handle CGEvent tap disabled/timeout recovery** — Auto re-enable on disable/timeout (#26)
6. ✅ **#17 Recover shortcut monitoring after permission changes without relaunch** — Monitoring recovery without relaunch (#28)
7. ✅ **#11 Replace linear shortcut scans with a precompiled trigger index** — O(1) trigger index (#27)
8. ✅ **#13 Reduce MainActor pressure in runtime shortcut services** — Sendable conformances, MainActor coupling reduced (#32); runtime state model documented (#29)

## Tier 2 — tests and repeatable validation ✅ Done

9. ✅ **#7 Add tests for key mapping, conflicts, and toggle logic** — Comprehensive tests for key mapping, conflicts, lifecycle (#30)
10. ✅ **#19 Add macOS CI or repeatable build validation path** — GitHub Actions CI for macOS build validation (#39)

## Tier 3 — product behavior and interaction quality ✅ Done

11. ✅ **#3 Polish shortcut recorder UX and unsupported-key handling** — Recorder UX polished (#37)
12. ✅ **#4 Improve toggle semantics for minimized/full-screen/multi-window apps** — Toggle semantics improved (#34)
13. ✅ **#5 Add stronger Hyper-style shortcut support and validation** — Hyper Key UI and validation (#33, #36)
14. ✅ **#18 Decide app structure direction: SwiftUI scene-based vs deliberate AppKit-first** — AppKit-first decision documented (#24)

## Tier 4 — packaging and daily-utility readiness ✅ Done

15. ✅ **#6 Automate .app packaging end to end** — Packaging script automated (#38)
16. ✅ **#14 Add launch-at-login support with modern ServiceManagement APIs** — SMAppService integration (#31)
17. ✅ **#15 Add app icon, bundle polish, and release metadata** — Bundle metadata, menu bar icon, version display polished (#48)

## Tier 5 — release hardening and identity ✅ Done

18. ✅ **#8 Document signing/notarization and release workflow** — Full workflow documented in `docs/signing-and-release.md` (#49)
19. ✅ **#9 Rename project from HotAppClone to Quickey** — Product display name (#50) and internal rename (#51) complete

## Beyond original plan — additional features shipped

- ✅ **UsageTracker service** with SQLite daily aggregation (#44)
- ✅ **SettingsView tabbed layout** (Shortcuts / General / Insights) (#45)
- ✅ **Inline usage stats** in Shortcuts tab (#46)
- ✅ **Insights tab** with trend chart and app ranking (#47)

## What remains

- Real macOS device validation (end-to-end shortcut capture, toggle, permissions)
- Signed/notarized distributable (Developer ID cert required)
- Private SkyLight activation path (intentionally deferred)
- Toggle edge cases: fullscreen / multi-window / multi-display
