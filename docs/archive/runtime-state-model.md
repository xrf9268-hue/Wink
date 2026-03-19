# Architecture Decision: Runtime State Model and Ownership Boundaries

**Issue**: #20 — Design a clearer runtime state model and ownership boundary
**Status**: Decided
**Date**: 2026-03-19

## Current State Ownership Map

```
AppController (owner: creates all components)
│
├── ShortcutStore          ← in-memory source of truth for [AppShortcut]
│   └── shortcuts: [AppShortcut]   (mutable, shared reference)
│
├── PersistenceService     ← stateless disk I/O
│   └── shortcuts.json
│
├── ShortcutManager        ← orchestrator (event tap + permission + matching)
│   ├── refs: ShortcutStore, PersistenceService, EventTapManager
│   ├── triggerIndex       ← derived state (rebuilt on save/start)
│   ├── permissionTimer    ← runtime polling state
│   └── lastPermissionState
│
├── EventTapManager        ← low-level event tap lifecycle
│   ├── eventTap, runLoopSource, retainedBox  ← system resources
│   └── isRunning          ← computed from eventTap
│
├── MenuBarController      ← UI shell (stateless callbacks)
│
└── SettingsWindowController → SettingsViewModel (per-open instance)
    ├── shortcuts          ← COPY of ShortcutStore.shortcuts (snapshot)
    ├── draft state        ← selectedAppName, bundleIdentifier, recordedShortcut
    └── accessibilityGranted ← snapshot, manually refreshed
```

## State Categories

### 1. Persistent state (disk)
| Data | Location | Owner |
|------|----------|-------|
| `[AppShortcut]` | `~/Library/Application Support/Quickey/shortcuts.json` | PersistenceService |

**Read**: once at launch (`AppController.start()`)
**Write**: on every save (`ShortcutManager.save()`)

### 2. In-memory source of truth
| Data | Location | Owner | Consumers |
|------|----------|-------|-----------|
| `shortcuts: [AppShortcut]` | ShortcutStore | AppController (creates) | ShortcutManager, SettingsViewModel |

**Current issue**: ShortcutStore is not Observable. SettingsViewModel takes a snapshot on init — if shortcuts change via another path, the VM's copy goes stale.

### 3. Derived state (computed from source of truth)
| Data | Location | Derived from |
|------|----------|-------------|
| `triggerIndex` | ShortcutManager | ShortcutStore.shortcuts |
| `isRunning` | EventTapManager | eventTap != nil |

**Current behavior**: triggerIndex is manually rebuilt in `save()` and `start()`. Correct but fragile — any new mutation path must remember to call `rebuildIndex()`.

### 4. Runtime system state
| Data | Location | Description |
|------|----------|------------|
| `eventTap: CFMachPort?` | EventTapManager | System resource, created/destroyed explicitly |
| `permissionTimer: Timer?` | ShortcutManager | Polling timer, invalidated on stop() |
| `lastPermissionState: Bool` | ShortcutManager | Tracks permission changes |

### 5. UI ephemeral state
| Data | Location | Lifetime |
|------|----------|----------|
| Draft shortcut fields | SettingsViewModel | Per settings-window open |
| `accessibilityGranted` | SettingsViewModel | Snapshot, manually refreshed |
| `conflictMessage` | SettingsViewModel | Cleared on next add |

## Identified Issues

### Issue A: SettingsViewModel holds a stale copy
`SettingsViewModel.init()` copies `shortcutStore.shortcuts` (line 22). If shortcuts were modified outside (hypothetical: import, sync), the VM wouldn't know. Currently safe because the only writer is SettingsViewModel itself via `shortcutManager.save()`, but fragile for future changes.

**Resolution**: Acceptable for now. If a second writer is added, make ShortcutStore an ObservableObject and observe it.

### Issue B: Dual write path in save()
`ShortcutManager.save()` writes to both ShortcutStore AND PersistenceService AND rebuilds triggerIndex. This is the single canonical save path — all mutations go through it. This is correct.

**Resolution**: No change needed. Document that `ShortcutManager.save()` is the ONLY write path.

### Issue C: triggerIndex rebuild is manual
`rebuildIndex()` must be called after any shortcut mutation. Currently called in `save()` and `attemptStartIfPermitted()`.

**Resolution**: Acceptable. The index is rebuilt in both mutation points. Adding a third would be a code smell suggesting ShortcutStore should own the index — defer until needed.

## Ownership Rules (formalized)

1. **ShortcutStore** is the single in-memory source of truth for shortcuts
2. **ShortcutManager.save()** is the ONLY path for mutating shortcuts (store + disk + index)
3. **AppController** owns the object graph and wires dependencies
4. **EventTapManager** owns system resources (tap, source, box) — explicit start/stop lifecycle
5. **ShortcutManager** owns derived state (triggerIndex) and runtime state (permission timer)
6. **SettingsViewModel** owns UI-ephemeral state only; reads shortcuts as snapshot on init
7. **PersistenceService** is stateless — it reads/writes but does not cache

## Follow-up implications

- **If adding shortcut import/sync**: Make ShortcutStore Observable so SettingsViewModel can react
- **If adding multiple windows/views**: Extract draft state from SettingsViewModel to avoid conflicts
- **If adding menu bar shortcut display**: Will need to observe ShortcutStore changes
- **No immediate refactoring needed**: Current model is correct for the single-writer, single-UI architecture
