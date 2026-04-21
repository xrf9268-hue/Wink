# Hotkey Recipes Reintegration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement issue #176 on top of current `main` by adding Wink-branded shortcut recipe import/export without regressing the renamed codebase, drag-to-reorder, or current shortcut-capture behavior.

**Architecture:** Reuse the core ideas from PR #188, but re-integrate them into the current Wink codebase instead of rebasing the old branch wholesale. Keep recipe serialization and import planning as focused services, wire the editor/UI around those services, and fold “unavailable target app” handling into `ShortcutManager` so imported unresolved shortcuts remain persisted without swallowing live hotkeys.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, AppKit (`NSOpenPanel`, `NSSavePanel`, `NSWorkspace`), Observation, UniformTypeIdentifiers

---

## File Map

- `Sources/Wink/Models/WinkRecipe.swift`
  Purpose: versioned, human-readable recipe payload for import/export.
- `Sources/Wink/Services/WinkRecipeCodec.swift`
  Purpose: encode/decode recipe JSON and validate schema versions.
- `Sources/Wink/Services/WinkRecipeImportPlanner.swift`
  Purpose: classify recipe entries into ready/conflict/unresolved buckets and apply import strategies deterministically.
- `Sources/Wink/Services/AppBundleLocator.swift`
  Purpose: injectable app availability lookup seam for live code and tests.
- `Sources/Wink/Services/AppListProvider.swift`
  Purpose: expose refresh/wait and lookup helpers needed by import planning.
- `Sources/Wink/Services/ShortcutEditorState.swift`
  Purpose: own export/import state, preview flow, and feedback strings.
- `Sources/Wink/Services/ShortcutManager.swift`
  Purpose: keep registered shortcuts aligned with currently available app targets and persisted imports.
- `Sources/Wink/UI/ShortcutsTabView.swift`
  Purpose: add Export/Import controls and preview UI while preserving the existing reorderable shortcut list.
- `Tests/WinkTests/WinkRecipeCodecTests.swift`
  Purpose: regression tests for payload shape and schema validation.
- `Tests/WinkTests/WinkRecipeImportPlannerTests.swift`
  Purpose: regression tests for resolution, conflict handling, and preview bucket correctness.
- `Tests/WinkTests/ShortcutEditorStateTests.swift`
  Purpose: regression tests for editor import/export flow.
- `Tests/WinkTests/ShortcutManagerStatusTests.swift`
  Purpose: regression tests for availability-gated registration and runtime resync.
- `Tests/WinkTests/TestSupport/TestAppBundleLocator.swift`
  Purpose: deterministic locator for editor/manager tests.
- `docs/architecture.md`
  Purpose: document recipe services and unavailable-target registration semantics.
- `docs/handoff-notes.md`
  Purpose: capture implementation status and macOS validation follow-up.

## Task 1: Add recipe model and codec

**Files:**
- Create: `Sources/Wink/Models/WinkRecipe.swift`
- Create: `Sources/Wink/Services/WinkRecipeCodec.swift`
- Test: `Tests/WinkTests/WinkRecipeCodecTests.swift`

- [ ] Write failing codec tests for round-trip encoding, `AppShortcut` export shape, and unsupported schema rejection.
- [ ] Run `swift test --filter WinkRecipeCodecTests` and confirm it fails because the recipe types/codecs do not exist yet.
- [ ] Implement the minimal `WinkRecipe` / `WinkRecipeShortcut` model plus codec support.
- [ ] Re-run `swift test --filter WinkRecipeCodecTests` and confirm it passes.

## Task 2: Add import planner on current main semantics

**Files:**
- Create: `Sources/Wink/Services/WinkRecipeImportPlanner.swift`
- Test: `Tests/WinkTests/WinkRecipeImportPlannerTests.swift`

- [ ] Write failing planner tests for bundle-id match, name fallback, unresolved handling, replace/skip conflict application, and the PR #188 review fix that unresolved preview buckets exclude conflicting entries.
- [ ] Run `swift test --filter WinkRecipeImportPlannerTests` and confirm it fails for the missing planner behavior.
- [ ] Implement the minimal planner and import plan helpers.
- [ ] Re-run `swift test --filter WinkRecipeImportPlannerTests` and confirm it passes.

## Task 3: Wire editor import/export flow without regressing current UI behavior

**Files:**
- Modify: `Sources/Wink/Services/AppBundleLocator.swift`
- Modify: `Sources/Wink/Services/AppListProvider.swift`
- Modify: `Sources/Wink/Services/ShortcutEditorState.swift`
- Modify: `Sources/Wink/UI/ShortcutsTabView.swift`
- Create: `Tests/WinkTests/TestSupport/TestAppBundleLocator.swift`
- Modify: `Tests/WinkTests/AppListProviderTests.swift`
- Modify: `Tests/WinkTests/ShortcutEditorStateTests.swift`

- [ ] Write failing editor/provider tests for export, import preview creation, strategy application, and the lookup helpers needed by the import flow.
- [ ] Run the targeted editor/provider tests and confirm they fail before implementation.
- [ ] Implement only the support seams and UI changes required to make import/export work on current `ShortcutsTabView`, keeping the existing `List` + `onMove` reorder behavior intact.
- [ ] Re-run the targeted tests and confirm they pass.

## Task 4: Keep capture registration aligned with app availability

**Files:**
- Modify: `Sources/Wink/Services/ShortcutManager.swift`
- Modify: `Tests/WinkTests/ShortcutManagerStatusTests.swift`

- [ ] Write failing tests that prove unavailable imported targets are excluded from registered shortcuts and that later availability changes trigger an index rebuild without another save/restart.
- [ ] Run `swift test --filter ShortcutManagerStatusTests` and confirm the new tests fail for current `main`.
- [ ] Implement availability-aware rebuild logic on top of the existing manager lifecycle, reusing current polling instead of adding a new hot-path cost.
- [ ] Re-run `swift test --filter ShortcutManagerStatusTests` and confirm it passes.

## Task 5: Update docs and verify end to end

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/handoff-notes.md`

- [ ] Update docs so the new recipe flow and unavailable-target behavior are truthful.
- [ ] Run targeted verification: `swift test --filter WinkRecipeCodecTests`, `swift test --filter WinkRecipeImportPlannerTests`, `swift test --filter ShortcutEditorStateTests`, `swift test --filter ShortcutManagerStatusTests`, `swift test --filter AppListProviderTests`.
- [ ] Run full verification: `swift test`.
- [ ] If available in the current host, note whether manual macOS spot-checks remain pending for `NSOpenPanel` / `NSSavePanel` behavior.
