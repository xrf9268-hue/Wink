# UI Improvements Design

**Date:** 2026-03-20
**Branch:** feature/UI-improvements
**Scope:** Visual polish, grouped card layout, app picker popover, shortcut enable/disable

## Overview

A comprehensive UI overhaul for the Settings window, covering all three tabs (Shortcuts, General, Insights). The goal is to introduce a "moderately polished" visual style using grouped cards (GroupBox-style) for clear section boundaries, alternating row colors for lists, and a new inline app picker popover to replace the current NSOpenPanel-based flow.

## Design Decisions

| Decision | Choice |
|----------|--------|
| Visual style | Moderate polish — grouped cards with rounded corners, system theme aware |
| App picker interaction | Popover (inline dropdown) |
| App picker detail level | Icon + app name + Bundle ID |
| App data source | All installed apps + recently used pinned to top |
| Bundle ID field | Hidden from editor form; shown only in shortcut list rows |
| Shortcut enable/disable | Per-row Toggle + master toggle in GeneralTabView |
| Alternating row colors | Applied to Shortcuts list and Insights ranking list |
| Cross-tab consistency | Unified card grouping style across all three tabs |

## 1. ShortcutsTabView

### 1.1 Permission Status Bar

- Replace the current loose `Circle + Text + Button` row with a compact status banner
- Green semi-transparent background + border when granted; orange when required
- Status text + Refresh button integrated in one row
- Smaller, less visually dominant than current implementation

### 1.2 "New Shortcut" Form Card

- Wrap the form in a GroupBox-style card (rounded background `#262626` dark / system grouped background light, 1px border, 8pt corner radius)
- Section title: "NEW SHORTCUT" (11px, semibold, uppercase, secondary color)
- **Row 1:** "Choose App ▾" button → triggers Popover (see Section 2). Selected app name displayed inline after selection.
- **Row 2:** Shortcut recorder field + Clear button + **Add button inline** (primary accent color, not a separate row)
- Bundle ID input field removed from this form entirely
- Conflict message displayed below the card if present

### 1.3 Shortcuts List

- Wrap in a card with "SHORTCUTS" section title
- **Alternating row backgrounds:** even rows `#262626`, odd rows `#2a2a2a` (dark mode); adapt for light mode using system alternating content background
- Each row layout:
  - App icon (via `NSWorkspace.shared.icon(forFile:)`, 28x28, rounded corners)
  - App name (primary text, medium weight)
  - Bundle ID (caption, secondary color) — moved here from the editor form
  - Usage count (caption, tertiary color): "N× past 7 days"
  - ShortcutLabel badge (monospaced text with background pill + optional Hyper badge)
  - **Enable/disable Toggle** (new)
  - Delete button: subtle ✕ instead of red trash icon

### 1.4 Per-Shortcut Enable/Disable

- Each shortcut row gets a Toggle switch between the ShortcutLabel and the delete button
- Visual order: `[Icon] [Name/BundleID/Usage] [Spacer] [ShortcutLabel] [Toggle] [✕]`
- When disabled: row content uses reduced opacity (0.5) to visually indicate inactive state
- Data model: `AppShortcut.isEnabled: Bool` (default `true`)
- `ShortcutManager` skips matching for shortcuts where `isEnabled == false`

## 2. App Picker Popover

### 2.1 Trigger

- Clicking "Choose App ▾" button opens a `.popover()` anchored to the button
- Approximate size: 320pt wide × 400pt tall

### 2.2 Structure

```
┌──────────────────────────┐
│ 🔍 Search apps...        │  ← Fixed, does not scroll
├──────────────────────────┤
│ RECENTLY USED            │  ← Sticky section header
│ [icon] Safari            │
│        com.apple.Safari  │
│ [icon] Terminal          │
│        com.apple.Terminal│
├──────────────────────────┤
│ ALL APPS                 │  ← Sticky section header
│ [icon] Calendar          │
│        com.apple.iCal    │
│ [icon] Messages          │
│        com.apple.MobileSMS│
│ ... (scrollable)         │
├──────────────────────────┤
│ Browse...                │  ← Fixed, fallback to NSOpenPanel
└──────────────────────────┘
```

### 2.3 Data Sources

- **Recently Used:** `NSWorkspace.shared.runningApplications` combined with the app's own `FrontmostApplicationTracker` history. Deduplicated, limited to ~10 most recent.
- **All Apps:** Scan `/Applications`, `~/Applications`, `/System/Applications` recursively for `.app` bundles. Cache the list; refresh on popover open if stale (> 60s).
- Each entry: app icon (32x32 via `NSWorkspace.shared.icon(forFile:)`), display name, bundle identifier.

### 2.4 Search

- Real-time filtering as user types
- Matches against both app name and bundle identifier (case-insensitive substring)
- When search is active, section headers ("Recently Used" / "All Apps") are hidden; results shown as flat filtered list

### 2.5 Keyboard Navigation

- `↑` / `↓`: Move highlight between rows
- `↵` (Return): Select highlighted row, close popover, populate app name + bundle ID
- `Esc`: Close popover without selection
- Highlighted row auto-scrolls into view
- Search field remains focused during keyboard navigation (keyDown forwarded from search field)

### 2.6 Fallback

- "Browse..." button at the bottom opens `NSOpenPanel` (current behavior) for apps not found in scan
- Fixed position, does not scroll with the list

### 2.7 Selection Behavior

- On selection: populate `selectedAppName` and `selectedBundleIdentifier` in `ShortcutEditorState`
- Popover dismisses automatically
- Focus moves to the shortcut recorder field

## 3. GeneralTabView

### 3.1 Card Layout

Three grouped cards replacing the current flat layout:

**Startup Card:**
- Section title: "STARTUP"
- Content: Launch at Login toggle

**Keyboard Card:**
- Section title: "KEYBOARD"
- Content:
  - **Enable All Shortcuts toggle** (new) — master switch that batch-sets `isEnabled` on all shortcuts
  - Enable Hyper Key toggle + inline monospace badge showing `Caps Lock → ⌃⌥⇧⌘`
  - Description text below Hyper Key toggle

**About Card:**
- Bottom-aligned, compact
- Centered: "Quickey v{version}"

### 3.2 Master Enable/Disable Toggle

- "Enable All Shortcuts" toggle in the Keyboard card
- When turned off: sets all `AppShortcut.isEnabled = false`, event tap can optionally be paused
- When turned on: restores all shortcuts to `isEnabled = true`
- State derived from shortcuts: ON if any shortcut is enabled, OFF if all disabled
- Mixed state (some enabled, some disabled): toggle shows ON (turning it off disables all)

## 4. InsightsTabView

### 4.1 Ranking List Improvements

- Wrap in a card with "TOP APPS" section title
- **Alternating row backgrounds** (same pattern as Shortcuts list)
- Each row layout:
  - Rank circle badge: circular background, bold number. #1 gets gold tint (`rgba(255,214,10,0.15)` bg, `#ffd60a` text), others get gray
  - App icon (via NSWorkspace, 20x20)
  - App name
  - Mini progress bar (60pt wide, 4pt tall) showing relative usage vs. the top-ranked app
  - Count label (monospaced, secondary color)

### 4.2 Other Elements

- Period picker and headline number: no changes (already well-designed)
- Bar chart: no changes
- Empty state: no changes

## 5. Cross-Tab Consistency

### 5.1 Card Style (Unified)

- Background: `Color(.controlBackgroundColor)` (adapts to light/dark)
- Border: 1px, `Color.secondary.opacity(0.2)`
- Corner radius: 8pt
- Internal padding: 14px
- Section title: 11px, semibold, uppercase, 0.5px letter-spacing, secondary foreground
- Card spacing: 12px between cards

### 5.2 Typography Scale

| Element | Font | Color |
|---------|------|-------|
| Section title | .system(size: 11, weight: .semibold), uppercase | .secondary |
| Primary text | .body, weight .medium | .primary |
| Secondary info | .caption | .secondary |
| Tertiary info | .caption | .tertiary |
| Shortcut badge | .system(.body, design: .monospaced) | .primary on subtle bg |
| Rank number | .system(size: 11, weight: .bold) | gold (#1) or .secondary |

### 5.3 Alternating Row Colors

- Even rows: card background (no extra tint)
- Odd rows: slightly lighter/darker variant
- Implementation: use row index modulo 2 to apply conditional background

## 6. Data Model Changes

### 6.1 AppShortcut

Add `isEnabled` property:

```swift
struct AppShortcut: Codable, Identifiable {
    let id: UUID
    var appName: String
    var bundleIdentifier: String
    var keyEquivalent: String
    var modifierFlags: [String]
    var isEnabled: Bool = true  // NEW
}
```

### 6.2 ShortcutEditorState

- Add `toggleShortcutEnabled(id: UUID)` method
- Add `setAllEnabled(_ enabled: Bool)` method
- Add `allEnabled: Bool` computed property (true if any enabled)

### 6.3 ShortcutManager

- Filter out `isEnabled == false` shortcuts when building trigger index
- Rebuild index when any shortcut's `isEnabled` changes

## 7. New Files

| File | Purpose |
|------|---------|
| `Sources/Quickey/UI/AppPickerPopover.swift` | Popover view with search, sections, keyboard nav |
| `Sources/Quickey/Services/AppListProvider.swift` | Scans installed apps, caches results, provides recent + all |

## 8. Modified Files

| File | Changes |
|------|---------|
| `ShortcutsTabView.swift` | Card layout, status banner, inline Add, alternating rows, per-row Toggle, app icon |
| `GeneralTabView.swift` | Card grouping, master enable toggle |
| `InsightsTabView.swift` | Card wrapper, alternating rows, rank circles, app icons, mini bars |
| `AppShortcut.swift` | Add `isEnabled: Bool` field |
| `ShortcutEditorState.swift` | Remove `chooseApplication()` (replaced by popover), add toggle/enable-all methods |
| `ShortcutManager.swift` | Filter disabled shortcuts from trigger index |
| `SettingsView.swift` | Pass additional dependencies if needed |
