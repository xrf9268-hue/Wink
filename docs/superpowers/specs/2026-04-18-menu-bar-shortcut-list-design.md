# Menu Bar Shortcut List Design

## Summary

Quickey's menu bar menu currently exposes only static utility actions such as `Settings`, `Launch at Login`, and `Quit`. Issue #180 adds a high-frequency reference surface directly inside the menu: when the user clicks the menu bar icon, Quickey should show every saved shortcut at the top of the menu, including app icon, app name, shortcut text, disabled state, and whether the target app currently has a running instance.

The chosen design keeps `MenuBarController` as the single menu owner, but adds a dynamic shortcut section rendered with custom `NSView`-backed menu rows. Each row is read-only and optimized for fast scanning: app icon on the left, compact running-state dot beside the app name, shortcut text on the right, and a muted disabled presentation when the shortcut is turned off. The dynamic section is rebuilt each time the menu opens from a fresh `ShortcutStore` + running-app snapshot, then separated from the existing static actions with a divider.

## Goals

- Let the user inspect all configured shortcuts without opening Settings.
- Show shortcut metadata in a compact, scan-friendly menu layout.
- Indicate whether a target app currently has at least one running instance.
- Make disabled shortcuts visible without making them look active.
- Preserve the current static menu actions and keep the implementation consistent with the existing AppKit menu structure.

## Non-Goals

- Making shortcut rows clickable, editable, reorderable, or otherwise interactive.
- Showing usage stats, launch-at-login state, or richer runtime diagnostics in the shortcut rows.
- Replacing the entire menu with SwiftUI or adding persistent workspace observers just for menu status.
- Re-sorting shortcuts independently from the saved order shown elsewhere in the app.
- Claiming macOS visual/runtime correctness from Linux-only validation.

## Current State

As of 2026-04-18:

- `MenuBarController` builds a fixed `NSMenu` with `Settings`, `Launch at Login`, and `Quit`.
- `ShortcutStore` already owns the in-memory `[AppShortcut]` list on the main actor.
- `AppShortcut` already exposes the displayable shortcut string via `displayText`.
- Quickey already has AppKit patterns for resolving application icons and falling back to a generic app icon.
- No menu-level model currently exists for representing shortcut rows or running-app status.

## Approaches Considered

### 1. Plain `NSMenuItem` text rows

Use ordinary menu items with `title`, `image`, and `isEnabled`, then approximate the layout with string formatting.

Pros:

- Smallest code change.
- Minimal AppKit surface area.

Cons:

- Weak control over visual hierarchy.
- Harder to place the running-state dot cleanly next to the app name.
- Disabled marker and shortcut alignment become string-formatting problems instead of view layout.

### 2. Custom `NSView` menu rows

Create a dedicated read-only menu row view for each shortcut and host it inside `NSMenuItem.view`.

Pros:

- Matches the chosen compact layout exactly.
- Gives precise control over icon/name/dot/shortcut alignment.
- Keeps future room for small UI refinements without rewriting menu composition.

Cons:

- More AppKit code than plain menu items.
- Requires explicit view/model seams to keep logic testable.

### 3. Shortcut list in a submenu

Keep the top-level menu mostly unchanged and move all bindings under a `Shortcuts` submenu.

Pros:

- Shorter top-level menu.

Cons:

- Fails the issue goal of “click and immediately see all bound shortcuts.”
- Adds one extra navigation step to a supposed quick reference panel.

## Recommended Design

Use approach 2: custom `NSView` menu rows, rendered as a compact single-line list at the top of the existing menu.

The final row layout is:

- leading app icon
- optional green running-state dot beside the app name
- app name text
- optional `disabled` marker when the shortcut is turned off
- trailing shortcut text badge

Rows are informational only. Clicking them should do nothing.

## Data Semantics

### Shortcut Order

The dynamic shortcut section should preserve the current `ShortcutStore.shortcuts` order. Quickey should not apply an additional sort in the menu, because the menu is meant to be a fast reflection of the saved configuration rather than a second ordering system.

### Running-State Dot

The green dot means: **the target bundle currently has at least one running application instance**.

It does **not** mean:

- the app is frontmost
- the app is visible
- the app is active because Quickey launched or activated it

This keeps the status simple, truthful, and cheap to compute from a single workspace snapshot.

### Disabled Rows

Disabled shortcuts remain visible in the list. They should be visually muted and explicitly marked with `disabled`, but still show app identity and shortcut text so the menu remains a complete reference surface.

### Empty State

If no shortcuts are configured, the menu should still reserve the dynamic section with a single read-only placeholder row such as `No shortcuts configured`, then show the divider and existing static actions below it. This avoids the menu abruptly collapsing to a totally different structure.

## Architecture

### `MenuBarController` Remains The Owner

`MenuBarController` should continue to own:

- menu creation
- menu refresh on open
- static menu items
- launch-at-login item updates

No additional controller should be introduced for this feature. The new behavior belongs to the existing menu composition boundary.

### Add A Small Presentation Model

The implementation should introduce a thin presentation model dedicated to menu rows. Its responsibility is to convert `AppShortcut` plus a running-app bundle set into view-friendly data such as:

- `appName`
- `bundleIdentifier`
- `shortcutText`
- `isEnabled`
- `isRunning`
- `isPlaceholder`

This keeps state derivation separate from AppKit view construction, which makes the feature easier to test without snapshot-heavy UI tests.

### Add A Dedicated Row View

Each shortcut row should be rendered by a focused custom AppKit view, for example a small `NSView` subclass or helper view builder hosted inside `NSMenuItem.view`.

The row view should be responsible only for presentation:

- icon display with fallback icon behavior
- single-line compact layout
- green dot visibility
- disabled styling
- shortcut badge styling

It should not own menu refresh logic or query global application state directly.

## Refresh Flow

### Rebuild On `menuWillOpen(_:)`

Each time the menu opens:

1. Read the current `ShortcutStore.shortcuts`.
2. Read a workspace snapshot of currently running applications.
3. Build the presentation rows from those two inputs.
4. Remove the existing dynamic shortcut items and their dedicated divider.
5. Insert the newly built shortcut rows at the top of the menu.
6. Leave the static actions (`Settings`, `Launch at Login`, `Quit`) intact below the divider.
7. Refresh the launch-at-login item as Quickey already does today.

This approach intentionally avoids persistent observation for this feature. The menu only needs to be correct when shown, so a cheap open-time snapshot is the simplest truthful solution.

### Rebuild Rather Than Diff

The shortcut section should be rebuilt wholesale instead of diffed in place.

Reasons:

- The menu is small.
- Rebuild-on-open avoids index bookkeeping errors.
- Full replacement makes repeated menu opens deterministic.
- The logic is easier to test than partial mutation.

## Error Handling And Fallbacks

- If the app icon cannot be resolved for a bundle, use the generic application fallback icon.
- If a running application snapshot has no bundle identifier, ignore it for running-state computation.
- If no running instance exists for a shortcut bundle, omit the green dot and leave the row otherwise unchanged.
- If the shortcut list is empty, show the placeholder row instead of omitting the entire section.
- The dynamic rows should be disabled from interaction regardless of whether the represented shortcut itself is enabled.

## Testing Strategy

The primary tests should target deterministic model and menu-composition behavior rather than brittle visual snapshots.

### Presentation Model Tests

Add tests that prove:

- shortcut order matches `ShortcutStore.shortcuts`
- running bundles map to `isRunning == true`
- disabled shortcuts remain present and marked correctly
- empty shortcut input produces a placeholder row

### Menu Composition Tests

Add tests around `MenuBarController` (or extracted menu-composition helpers) that prove:

- dynamic shortcut rows appear above the existing static items
- the divider between dynamic rows and static items is present
- repeated `menuWillOpen(_:)` calls do not duplicate rows
- static item ordering remains stable after rebuilds

### Fallback Tests

Add targeted coverage for:

- unresolved icon path fallback
- empty running-app snapshot
- mixed enabled/disabled shortcut sets

## File-Level Plan Surface

This design is expected to touch the following areas during implementation.

### Existing Files To Modify

- `Sources/Quickey/UI/MenuBarController.swift`
- `Sources/Quickey/AppController.swift`
- `Tests/QuickeyTests/MenuBarLaunchAtLoginPresentationTests.swift` or a new menu-bar-specific test file if the row model deserves dedicated coverage

### New Files Likely To Add

- a menu row presentation model file under `Sources/Quickey/UI/`
- a custom menu row view file under `Sources/Quickey/UI/`
- a dedicated test file for menu shortcut row modeling / menu rebuild behavior under `Tests/QuickeyTests/`

## Validation Notes

This feature is UI-facing but not deeply runtime-sensitive in the same sense as event taps or activation control. Still, the final behavior must be visually validated on macOS because AppKit menu row layout and icon rendering cannot be fully trusted from Linux-only inspection.

At minimum, macOS validation for the eventual implementation should confirm:

- dynamic shortcut rows render above the static menu items
- enabled and disabled rows are visually distinct
- the green dot appears only for currently running bundles
- the menu remains stable across repeated opens
- empty-state rendering looks intentional

Until that validation runs on macOS, runtime/UI validation remains pending.
