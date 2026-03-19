# Codex Review Summary

This summary captures a Codex review of the repository focused on architecture, Apple/macOS alignment, performance, and issue coverage.

> **Status update (2026-03-19):** All 5 recommended actions from the original Codex review have been completed. See the status notes below each section.

## Overall assessment (original)
Quickey was a solid prototype scaffold, but not yet a production-grade macOS menu bar utility.
The codebase was small, readable, and reasonably decomposed, but runtime robustness, platform alignment, and real macOS validation were still missing.

**Current:** Architecture remediation is complete. The remaining gap is end-to-end validation on a real macOS device and a signed/notarized distributable build.

## Main conclusions

### What is already good
- clean decomposition across lifecycle, UI, persistence, event capture, and switching
- appropriate `LSUIElement` baseline for a menu bar utility
- documentation and issue structure are well maintained

### What has been resolved
- ✅ Event tap lifecycle ownership and recovery — hardened in #25, #26
- ✅ Permission flow recovery after permission changes — no relaunch required (#28)
- ✅ Too much runtime logic under `@MainActor` — Sendable conformances added, MainActor coupling reduced (#32)
- ✅ Weak toggle heuristics — toggle semantics improved (#34); Hyper Key support added (#33, #36)
- ✅ Almost no meaningful tests — comprehensive tests added (#30)
- ✅ No real macOS build/runtime validation — CI via GitHub Actions added (#39)

### What still needs attention
- End-to-end real macOS device validation
- Signed/notarized distributable build

## Critical issues highlighted by Codex (all resolved)
1. ✅ Event tap ownership and cleanup — stricter lifecycle contract implemented (#25)
2. ✅ Event monitoring silent fail/timeout — auto-recovery implemented (#26)
3. ✅ Permission flow recovery — monitoring recovers after permission changes without relaunch (#28)
4. ✅ Runtime matching off main actor — O(1) trigger index, MainActor pressure reduced (#27, #32)
5. ✅ Toggle behavior beyond single global previous-app — toggle semantics improved (#34); per-shortcut history stacks remain a potential future improvement

## Apple/macOS alignment notes
The explicit architectural decision was made and documented: **AppKit-first with selective SwiftUI** (#24, `docs/plans/app-structure-direction.md`).

Rationale: hard constraints (`.accessory` activation policy, raw key capture via NSTextField subclass, CGEvent tap via CFRunLoop, NSWorkspace/NSRunningApplication) prevent a pure SwiftUI scene-based approach for this app.

## Performance notes (all resolved)
- ✅ Linear shortcut scans — replaced with O(1) precompiled trigger index (#27)
- ✅ Main-thread pressure in shortcut runtime path — MainActor coupling reduced (#32)
- ✅ EventTap resilience — hardened lifecycle with auto-recovery (#25, #26)

## Issue-tracker implications (all resolved)
All originally identified gaps have been addressed:
- ✅ Event tap disabled/timeout recovery (#26)
- ✅ Permission-grant recovery without relaunch (#28)
- ✅ Explicit app-structure direction decision (#24)
- ✅ macOS CI or repeatable build validation (#39)
- ✅ Tests prioritized with runtime-core changes (#30)

## Recommended next 5 actions from the review (all done)
1. ✅ Fix event tap ownership, teardown, and disabled/timeout recovery (#25, #26)
2. ✅ Move shortcut hot path off main actor and replace linear scans with precompiled index (#27, #32)
3. ✅ Redesign permission flow so monitoring recovers without relaunch (#28)
4. ✅ Add focused tests for matching, indexing, toggle semantics, and permission/lifecycle behavior (#30)
5. ✅ Decide app-structure direction: AppKit-first documented and justified (#24)
