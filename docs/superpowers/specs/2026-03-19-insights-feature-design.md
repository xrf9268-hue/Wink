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

### Database Initialization

On first launch, `UsageTracker.init` will:
1. Ensure `~/Library/Application Support/HotAppClone/` directory exists (via `FileManager.createDirectory`)
2. Open (or create) `usage.db`
3. Run `CREATE TABLE IF NOT EXISTS daily_usage (...)`

No migration system needed for MVP — the schema is simple and stable. If future changes are needed, a `schema_version` pragma can be added later.

### UsageTracker Service

Declared as `actor UsageTracker` to run SQLite operations off the main thread. The key event handler in `ShortcutManager` must not block on disk I/O.

Interface:

- `recordUsage(shortcutId: UUID)` — UPSERT: increment today's count. Called only when `AppSwitcher.toggleApplication()` returns `true` (successful switch).
- `dailyCounts(days:) -> [String: [(date: String, count: Int)]]` — Returns per-day counts for all shortcuts in a single query. The chart view and ranking list both need this data, so a batched query avoids N+1.
- `usageCounts(days:) -> [UUID: Int]` — Returns total count per shortcut in one query. Used for inline stats on the Shortcuts list (avoids per-row async calls).
- `totalSwitches(days:) -> Int` — Sum of all shortcut usage in the period. Used for the headline number.
- `deleteUsage(shortcutId: UUID)` — Remove all records for a shortcut. Fire-and-forget on deletion (orphan stats are harmless if the async delete races).

### Integration Point

In `ShortcutManager`, after `AppSwitcher.toggleApplication()` returns `true`, call `Task { await usageTracker.recordUsage(shortcutId:) }`. Only record on successful switches to avoid inflating counts.

When a shortcut is deleted via `SettingsViewModel`, call `Task { await usageTracker.deleteUsage(shortcutId:) }`.

### Injection Chain

`AppController` creates `UsageTracker` and passes it to:
- `ShortcutManager.init(usageTracker:)` — for recording usage on key events
- `SettingsWindowController.init(usageTracker:)` → `SettingsViewModel.init(usageTracker:)` — for inline stats and deletion cleanup
- `InsightsViewModel.init(usageTracker:)` — for the Insights tab data

### Zero-Fill for Chart Data

`dailyCounts` returns only days with non-zero usage. The chart renderer must fill in missing days with count=0 to produce a complete date range for the selected period (7 or 30 days).

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
- **D (Day)**: Today's total usage count only (no hourly bars — current schema only stores daily aggregates, hourly breakdown would require a schema change)
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
| `SettingsViewModel.swift` | Add `usageTracker` dependency; load batched usage counts; call deleteUsage on shortcut removal |
| `ShortcutManager.swift` | Add `usageTracker` parameter; call `recordUsage()` gated on successful `toggleApplication()` return |
| `AppController.swift` | Initialize UsageTracker, inject into ShortcutManager and SettingsWindowController |
| `SettingsWindowController.swift` | Accept `usageTracker`, pass to SettingsViewModel and InsightsViewModel |
| `Package.swift` | Add `linkerSettings: [.linkedLibrary("sqlite3")]` to executable target |

### SQLite Access

Use the system SQLite C API directly (`import SQLite3`). No third-party ORM needed — the queries are simple enough that raw SQL is cleaner and avoids adding dependencies.

Requires adding `linkerSettings: [.linkedLibrary("sqlite3")]` to the executable target in `Package.swift`.

### Data Flow

```
Shortcut triggered
  → ShortcutManager matches key
  → let success = AppSwitcher.toggleApplication()
  → if success: Task { await usageTracker.recordUsage(shortcutId) }
  → UsageTracker (actor): SQLite UPSERT on daily_usage (off main thread)

Insights tab opened
  → InsightsViewModel.refresh()
  → await usageTracker.totalSwitches(days:)  → headline number
  → await usageTracker.dailyCounts(days:)    → bar chart data (zero-filled)
  → SwiftUI view updates

Shortcuts list displayed
  → SettingsViewModel loads shortcuts
  → await usageTracker.usageCounts(days: 7)  → [UUID: Int] dictionary
  → Each row looks up its count from the dictionary
  → Inline "N× past 7 days" text
```

## Out of Scope

- "Time saved" estimation — unreliable metric, excluded intentionally
- Hourly breakdown for Day view — would require schema change to store sub-daily data
- App icon loading in ranking list — MVP uses placeholder; real icons can be added later via `NSWorkspace.shared.icon(forFile:)` + `AppBundleLocator`
- Data export — not needed for MVP
- CloudKit sync for usage data — local only
