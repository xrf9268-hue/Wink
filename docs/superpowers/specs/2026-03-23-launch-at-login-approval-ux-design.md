# Launch-at-Login Approval UX Design

**Date:** 2026-03-23
**Branch:** main
**Issue:** `#67` Improve launch-at-login approval-state UX
**Scope:** Clarify `SMAppService` launch-at-login states in the General tab without collapsing them to a boolean

## Overview

Quickey already models `SMAppService.Status.requiresApproval` and `.notFound` truthfully, but the General tab still presents launch at login as a plain toggle. That leaves users guessing whether the setting is enabled, broken, or waiting for a system approval step.

This design keeps the existing `Launch at Login` toggle as the primary control in the General tab, adds state-specific explanation where needed, and preserves the current lightweight menu bar behavior.

## Goals

- Make `.enabled`, `.requiresApproval`, `.disabled`, and `.notFound` understandable from the General tab
- Give users a direct next action when approval is pending
- Preserve `SMAppService` multi-state semantics instead of regressing to bool-only modeling
- Keep the settings layout stable across normal and exceptional states

## Non-Goals

- Reworking the menu bar item into a full explanatory flow
- Changing the underlying `LaunchAtLoginService` state model
- Adding new packaging diagnostics beyond clearer `.notFound` messaging

## Current Context

- `LaunchAtLoginService` already maps `SMAppService.Status` into four states: `.enabled`, `.requiresApproval`, `.disabled`, and `.notFound`
- `AppPreferences.launchAtLoginEnabled` currently exposes only `status.isEnabled`, which is insufficient for the desired UI because `.requiresApproval` should still render the toggle as on
- `GeneralTabView` currently renders a plain toggle with no explanation or CTA
- `MenuBarController` already reflects `.requiresApproval` with a mixed state, and that behavior will remain in place

## Approved Product Decisions

| Topic | Decision |
|------|----------|
| Approval pending in General tab | Keep the toggle interactive, show approval copy, add `Open Login Items Settings` CTA |
| Menu bar behavior | Keep current mixed-state semantics; do not add extra explanatory menu items |
| `.notFound` behavior | Keep the toggle in place but disable it, and show error-style explanatory copy |
| Responsibility split | Keep `LaunchAtLoginStatus` as the source of truth; derive display semantics in `AppPreferences`; keep layout and styling in `GeneralTabView` |

## Approaches Considered

### 1. View-local branching

Let `GeneralTabView` directly switch on `LaunchAtLoginStatus` and decide which controls and copy to show.

Pros:
- Smallest code change
- Fastest to implement

Cons:
- Presentation rules and business semantics become tangled in the SwiftUI view
- Harder to test state-to-UI mapping cleanly

### 2. Presentation model derived in `AppPreferences`

Keep the service-level state model unchanged and derive a lightweight display model in `AppPreferences` for the General tab.

Pros:
- Preserves system semantics while making UI logic explicit and testable
- Keeps `GeneralTabView` focused on layout and composition
- Scales well if copy or CTA conditions change

Cons:
- Adds one small abstraction layer

### 3. Separate shared presentation helper type

Introduce a dedicated status presentation type intended for reuse across multiple UI entry points.

Pros:
- Cleanest long-term separation if multiple surfaces need the same explanation

Cons:
- Heavier than this issue needs
- The menu bar intentionally does not need the full explanatory model

### Recommendation

Use approach 2. It is the best fit for this issue: enough structure to keep the semantics honest and testable, without introducing unnecessary architecture for future reuse that is not currently needed.

## Design

### 1. State Model and Responsibilities

`LaunchAtLoginStatus` remains the system-facing source of truth and continues to represent only these states:

- `.enabled`
- `.requiresApproval`
- `.disabled`
- `.notFound`

`AppPreferences` derives a lightweight General-tab presentation model from that status. This model should answer display questions rather than restating system state:

- whether the toggle appears on
- whether the toggle is interactive
- whether helper copy is shown
- whether the `Open Login Items Settings` CTA is shown
- whether the helper copy is informational or error-style
- which user-facing message to display

This separation keeps responsibilities clear:

- `LaunchAtLoginService`: system truth and side effects
- `AppPreferences`: UI-facing interpretation of that truth for settings
- `GeneralTabView`: layout, styling, and wiring controls to actions
- `MenuBarController`: continue consuming raw `LaunchAtLoginStatus` directly

### 2. General Tab Interaction

The `Startup` card keeps `Launch at Login` in its current location as the primary control. State-specific behavior is:

| State | Toggle visual state | Toggle interactivity | Helper copy | CTA |
|------|----------------------|----------------------|-------------|-----|
| `.enabled` | On | Enabled | None | None |
| `.disabled` | Off | Enabled | None | None |
| `.requiresApproval` | On | Enabled | Approval-pending explanation | `Open Login Items Settings` |
| `.notFound` | Off | Disabled | Error-style explanation | None |

#### `.requiresApproval` semantics

In `.requiresApproval`, the toggle must appear on even though the login item is not fully active yet. The displayed meaning is:

> Quickey has requested launch at login, but macOS still requires user approval before it can run automatically.

This state keeps the toggle interactive so the user can still turn it off and unregister the login item instead of being trapped in a pending state.

The helper copy should be short and direct. It must explain that:

- launch at login is not fully active yet
- a system approval step is still required
- the CTA opens the relevant Login Items settings page

#### `.notFound` semantics

`.notFound` should be presented as an environment or packaging problem, not as a user preference that failed to save. The toggle remains in its normal position for layout stability but is disabled to avoid implying that retrying the switch is the primary recovery path.

The helper copy should point users toward installation, packaging, or distribution problems rather than toward System Settings approval.

### 3. Visual Presentation

The extra messaging should remain inline within the `Startup` card rather than becoming a large banner. The intent is clarity without turning a localized state into a disruptive warning.

Recommended visual treatment:

- `.requiresApproval`: subtle secondary or warning-tinted explanatory block
- `.notFound`: stronger error-tinted explanatory block within the card
- CTA: secondary button placed directly below the approval-pending explanation

This keeps the card stable while still making exceptional states obvious.

### 4. Data Flow and Refresh Behavior

The existing action flow remains:

1. User interacts with the toggle in `GeneralTabView`
2. `GeneralTabView` calls `AppPreferences.setLaunchAtLogin(_:)`
3. `AppPreferences` delegates to `LaunchAtLoginService`
4. `AppPreferences.refreshLaunchAtLoginStatus()` refreshes the source-of-truth state
5. The derived presentation model updates from the refreshed status

CTA behavior remains simple:

- `Open Login Items Settings` only opens the system Login Items settings page
- It does not optimistically change local state

Refresh expectations:

- Refresh after every toggle action
- Refresh when the settings view appears
- Refresh when the app becomes active again after the user returns from System Settings, using a single app-activation hook such as `NSApplication.didBecomeActiveNotification`

The last requirement is important because it allows `.requiresApproval` to update to `.enabled` after approval without requiring an app relaunch or a manual settings tab reset.

### 5. Menu Bar Behavior

The menu bar launch-at-login item keeps its current lightweight behavior:

- `.enabled` -> checked
- `.requiresApproval` -> mixed
- `.disabled` / `.notFound` -> unchecked

No extra menu item or explanatory copy is added there. The General tab is the source of detailed explanation.
Expanding menu bar approval-state behavior beyond the existing mixed-state indicator is out of scope for this issue.

### 6. Testing Strategy

The highest-value automated tests are presentation-mapping tests around the new `AppPreferences`-level display model.

Required coverage:

- `.enabled` maps to an interactive on-toggle with no helper copy
- `.disabled` maps to an interactive off-toggle with no helper copy
- `.requiresApproval` maps to an interactive on-toggle, approval helper copy, and CTA visibility
- `.notFound` maps to a disabled toggle and error-style helper copy

If the view layer gets direct tests, focus them on visibility and wiring for the exceptional states:

- approval helper copy and CTA render in `.requiresApproval`
- error helper copy renders and the toggle is disabled in `.notFound`

The core rule is that state interpretation should live in a testable layer outside the SwiftUI branching as much as possible.

### 7. Validation Requirements

This issue still requires real macOS validation. Static inspection or non-macOS builds are not enough to claim correctness.

Manual validation targets:

- packaged app enters and displays `.requiresApproval` accurately
- `Open Login Items Settings` opens the correct system destination
- approving the login item in System Settings is reflected after returning to the app
- `.notFound` displays the intended packaging/setup guidance in an environment where that state can be reproduced

## Acceptance Criteria

- Users can distinguish `.enabled`, `.requiresApproval`, `.disabled`, and `.notFound` from the General tab
- Approval-pending state offers a clear path to System Settings
- Copy remains concise and faithful to current macOS behavior
- The UI continues to reflect `SMAppService` semantics instead of reducing launch at login to a boolean

## Implementation Notes For Planning

- `launchAtLoginEnabled` is no longer sufficient as the sole General-tab binding because `.requiresApproval` must render as on
- The new presentation model should remain lightweight and UI-oriented; avoid moving colors, fonts, or layout constants into `AppPreferences`
- Refresh-on-foreground may require a small lifecycle hook in the settings or app shell layer; this should be planned explicitly
