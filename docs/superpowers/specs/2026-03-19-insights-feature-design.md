# Insights Feature Design

## Overview

Add usage statistics tracking and an Insights tab to HotApp Clone, allowing users to see how often they use each shortcut, identify unused shortcuts, and view usage trends over time.

## Goals

- Help users discover which shortcuts are heavily used vs. unused (practical cleanup/optimization value)
- Provide a sense of achievement by visualizing usage patterns (display value)

## Data Layer

### Storage

SQLite database at `~/Library/Application Support/HotAppClone/usage.db`. Chosen over JSON because usage tracking requires frequent writes (every shortcut trigger) and time-based aggregation queries.

### Schema

```sql
CREATE TABLE daily_usage (
    shortcut_id TEXT NOT NULL,    -- AppShortcut.id (UUID string)
    date        TEXT NOT NULL,    -- "2026-03-19" ISO format
    count       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (shortcut_id, date)
);
```

Daily aggregation only — no raw event storage. This keeps the database tiny (years of data under 1MB) while fully supporting all planned queries.

### UsageTracker Service

New service with the following interface:

- `recordUsage(shortcutId:)` — UPSERT: increment today's count for the given shortcut. Called from `ShortcutManager` when a shortcut triggers successfully.
- `dailyCounts(shortcutId:, days:) -> [(date: String, count: Int)]` — Returns per-day counts for the trend chart.
- `totalCount(shortcutId:, days:) -> Int` — Total usage in the given period. Used for inline stats on the Shortcuts list.
- `topShortcuts(days:, limit:) -> [(shortcutId: String, count: Int)]` — Sorted by usage count descending. Used for the Insights ranking list.
- `totalSwitches(days:) -> Int` — Sum of all shortcut usage in the period. Used for the headline number.
- `deleteUsage(shortcutId:)` — Remove all records for a shortcut. Called when a shortcut is deleted.

### Integration Point

In `ShortcutManager`, after a shortcut match triggers `AppSwitcher`, call `UsageTracker.recordUsage(shortcutId:)`.

When a shortcut is deleted via `SettingsViewModel`, call `UsageTracker.deleteUsage(shortcutId:)`.

## UI Design

### Tab System (New)

The current single-page `SettingsView` is restructured into a tabbed layout using SwiftUI `Picker` with `.segmented` style:

- **Shortcuts** — Existing shortcut recording and list UI (with inline usage stats added)
- **General** — Settings like Launch at Login
- **Insights** — New statistics view

Implementation:
- `@State var selectedTab` in `SettingsView`
- Extract existing content into `ShortcutsTabView`
- New `GeneralTabView` for settings
- New `InsightsTabView` for statistics

### Shortcuts Tab — Inline Usage Stats

Each shortcut row in the list displays a secondary line below the app name:

```
iTerm2
10× past 7 days          ⌃⌥⇧⌘D
```

- Gray secondary text, smaller font size
- Shows `totalCount(shortcutId:, days: 7)` value
- Format: `"{count}× past 7 days"`
- Shows `"0× past 7 days"` for unused shortcuts (helps identify candidates for cleanup)

### Insights Tab — Screen Time Style

Design follows Apple Screen Time's visual language: one headline number, one chart, one sorted list.

**Layout (top to bottom):**

1. **Headline area** (left-aligned):
   - Small uppercase label: "PAST 7 DAYS" (or "TODAY" / "PAST 30 DAYS")
   - Large number: `"234 switches"`
   - Right side: segmented picker `D / W / M` (Day, Week, Month)

2. **Bar chart**:
   - Horizontal axis: time periods (hours for Day, days for Week, days for Month)
   - Vertical axis: usage count (implicit, no labels needed)
   - Rounded bar tops, accent color with varying opacity
   - Day labels below bars (M/T/W/T/F/S/S for week view)

3. **App ranking list** (sorted by usage descending):
   - Each row: app icon placeholder + app name + proportional progress bar + count
   - Progress bar width is relative to the most-used shortcut (top one = 100%)
   - No numbered ranking — the visual order and progress bars are sufficient

**Time period options:**
- **D (Day)**: Today's usage, bars could show hourly breakdown (optional, can start with just a total)
- **W (Week)**: Past 7 days, bars show each day
- **M (Month)**: Past 30 days, bars show each day

## Architecture Notes

### New Files

| File | Purpose |
|------|---------|
| `Sources/HotAppClone/Services/UsageTracker.swift` | SQLite-based usage recording and querying |
| `Sources/HotAppClone/UI/InsightsTabView.swift` | Insights tab SwiftUI view |
| `Sources/HotAppClone/UI/InsightsViewModel.swift` | Data preparation for Insights view |
| `Sources/HotAppClone/UI/ShortcutsTabView.swift` | Extracted shortcuts tab content |
| `Sources/HotAppClone/UI/GeneralTabView.swift` | General settings tab |
| `Sources/HotAppClone/UI/BarChartView.swift` | Reusable bar chart component |

### Modified Files

| File | Change |
|------|--------|
| `SettingsView.swift` | Add tab picker, delegate to tab views |
| `SettingsViewModel.swift` | Add usage count data for inline stats; call deleteUsage on shortcut removal |
| `ShortcutManager.swift` | Call `UsageTracker.recordUsage()` on successful shortcut trigger |
| `AppController.swift` | Initialize UsageTracker, inject into dependencies |

### SQLite Access

Use the system SQLite C API directly (`import SQLite3`). No third-party ORM needed — the queries are simple enough that raw SQL is cleaner and avoids adding dependencies.

### Data Flow

```
Shortcut triggered
  → ShortcutManager matches key
  → AppSwitcher.toggleApplication()
  → UsageTracker.recordUsage(shortcutId)  // fire-and-forget
  → SQLite UPSERT on daily_usage

Insights tab opened
  → InsightsViewModel.refresh()
  → UsageTracker.totalSwitches(days:)     → headline number
  → UsageTracker.dailyCounts(days:)       → bar chart data
  → UsageTracker.topShortcuts(days:)      → ranking list
  → SwiftUI view updates

Shortcuts list displayed
  → SettingsViewModel loads shortcuts
  → For each: UsageTracker.totalCount(shortcutId:, days: 7)
  → Inline "N× past 7 days" text
```

## Out of Scope

- "Time saved" estimation — unreliable metric, excluded intentionally
- Hourly breakdown for Day view — can be added later if needed
- Data export — not needed for MVP
- CloudKit sync for usage data — local only
