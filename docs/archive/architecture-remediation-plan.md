# Architecture Remediation Plan

This document captures architectural improvements needed to move Quickey from a good scaffold to a stronger macOS-native design.

> **Status update (2026-03-19):** All P0 items and most P1 items are complete. See status markers.

## P0 — correctness, lifecycle, and hot-path fixes ✅ All done

### 1. Align permissions with the actual CGEvent tap model ✅ Done (#23)
Switched from Accessibility-style trust APIs to the correct Input Monitoring permission model for CGEventTap.

### 2. Replace linear shortcut scans with a precompiled O(1) lookup index ✅ Done (#27)
`ShortcutSignature` model and prebuilt dictionary keyed by keycode + modifiers implemented.

### 3. Tighten event tap lifecycle ownership and cleanup ✅ Done (#25)
Callback context allocation, retention, teardown, and run-loop removal all have a clear lifecycle contract. Lifecycle tests added.

### 4. Reduce unnecessary MainActor pressure in runtime services ✅ Done (#32)
Sendable conformances added. MainActor coupling reduced to UI-facing paths only.

## P1 — architecture quality and product behavior

### 5. Introduce clearer state boundaries
**Status:** Partially addressed via runtime state model documentation (#29).
Controller-centric structure remains; further separation is a future improvement.

### 6. Upgrade toggle behavior beyond a single global previous-app memory ✅ Done (#34)
Toggle semantics improved: activate → restore previous app → hide fallback. Per-shortcut history stacks remain a potential future enhancement.

### 7. Promote the recorder into a more native-feeling shortcut capture component ✅ Done (#37)
Unsupported-key handling improved, recorder UX polished.

### 8. Add test seams around event-independent core logic ✅ Done (#30)
Comprehensive tests for key mapping, conflict logic, and lifecycle behavior added.

## P2 — productization and modern macOS integration

### 9. Re-evaluate MenuBarExtra ownership
**Status:** Explicitly decided — AppKit-first retained. See `docs/plans/app-structure-direction.md` (#24). MenuBarExtra not adopted due to hard AppKit constraints.

### 10. Add launch-at-login via modern ServiceManagement APIs ✅ Done (#31)
`SMAppService.mainApp` integration implemented.

### 11. Turn packaging from scaffold into a real release flow ✅ Done (#38)
`scripts/package-app.sh` automates the full packaging flow.

### 12. Define the signing and notarization path ✅ Done (#49)
Full signing, notarization, and release workflow documented in `docs/signing-and-release.md`.

## What remains

- End-to-end real macOS device validation
- Signed/notarized distributable build (requires Developer ID cert)
- Per-shortcut toggle history stacks (beyond current best-effort single-memory approach)
- Private SkyLight low-latency activation path (intentionally deferred)
