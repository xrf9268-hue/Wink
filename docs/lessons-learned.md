# Wink Troubleshooting Guidance

> **Last reviewed:** 2026-04-25 (issue #230 documentation audit). **Last updated:** 2026-04-26 (PR #236 UI v2 settings layout parity follow-up). **Next audit due:** 2026-07-25.
>
> This file accumulates operational lessons over time. Without periodic pruning it becomes another archive. When a section's lesson no longer reflects current code, move it to `archive/lessons-learned-historical.md` (create on first prune) rather than rewriting it in place — the original framing is part of the evidence.

## Documentation Drift Produces High-Confidence Reviewer Errors

**Issue**
During the 2026-04-25 review cycle, an `Explore` agent flagged a missing self-reference guard on `previousBundle` as a 🔴 Critical "violates AGENTS.md hard constraint" finding. The judgement was logically consistent with the then-current `AGENTS.md` wording, but the underlying field had already degraded from "runtime decision input" to "telemetry field," so the worst-case impact was a malformed log line, not a critical bug. Issue #229 later removed the stale previous-app telemetry entirely.

**Cause**
`AGENTS.md` and several entries under `docs/` describe behavior that the code no longer implements. Reviewers (human or AI) build their mental model from those documents and then map it onto the code. When the doc is wrong, the review is confidently wrong. The same review cycle also surfaced a fictitious type name (`ActivationObservationClientCallbacks`, when the actual type is `ApplicationObservation.Client`) being repeated downstream because nobody re-grepped before quoting it.

**Practical guidance**
- When a code reviewer (especially an agent) cites an `AGENTS.md` "hard constraint," cross-check that the constraint still matches the code before acting on the finding. If it does not, fix the doc as part of the same change set.
- Before forwarding an agent report, `grep` every type / file / line reference it cites. "Agent gave a `file:line` pointer" is not the same as "agent verified the code." Treat unverified citations as hypotheses.
- For state-machine fields, do not judge the impact of a missing guard from declaration + assignment alone. Trace the value to the sink it flows into (log? activate call? persistence?). The downstream consumer determines the severity, not the field's name or the doc's tone.
- The Explore agent is well-suited to "find all places matching pattern X." It is not well-suited to "verify that the code obeys constraint list Y" — surface-level pattern matches will miss whether a value actually drives behavior. Keep constraint-vs-code judgements with a reader who is also tracing the data flow.
- Doc bloat is itself a contributor: when there are 14 top-level files and several subdirectories without a one-line role description, "which doc is current?" becomes ambiguous, and the failure mode above repeats. Maintaining `docs/README.md` as a navigation index with explicit current/historical separation is part of preventing this class of bug.

(See issue #230 for the systemic write-up that produced this lesson, and issue #229 for the follow-up that removed the stale `previousBundle` / `previousApp` telemetry.)

## Menu Bar Validation Can Use `System Events` Directly

**Issue**
Menu bar extras are easy to overcomplicate during macOS validation: once the app has no normal window, it is tempting to fall back to pixel guessing, screenshot cropping, or indirect UI probing.

**Cause**
Status-bar utilities do not behave like normal document apps, so generic desktop automation entrypoints can time out or expose little useful structure. That can hide the simpler path: the status item may still be directly addressable as an accessibility menu-bar extra.

**Practical guidance**
Before resorting to coordinate guessing, try `System Events` against the target process itself. In Wink's issue #180 validation, the status item was directly visible as `menu bar item 1 of menu bar 1 of process "Wink"` with AX description `Wink` and subrole `AXMenuExtra`, which let us open the menu and inspect real menu items deterministically:

```applescript
tell application "System Events"
    tell process "Wink"
        click menu bar item 1 of menu bar 1
        get title of every menu item of menu 1 of menu bar item 1 of menu bar 1
    end tell
end tell
```

Treat this as the preferred validation path for menu-bar-only behavior when it works: it is more truthful and repeatable than screenshot-based coordinate guessing.

## Template Menu Bar Icons Must Be Checked In Highlighted State

**Issue**
A menu bar icon can pass the wrong checks and still look blank to the user. In issue #228, the template resource was non-empty, the packaged app exposed an `AXMenuExtra`, and the status item could be clicked, but the selected menu bar slot still rendered as an empty gray placeholder.

**Cause**
Those checks proved that a status item existed, not that the exact reported visual state was correct. The missing check was the opened/highlighted menu bar state. The high-level `MenuBarExtra` image overload also left too little control over the AppKit template-image path for this case, so regenerating PNGs alone did not fix the runtime rendering. The fix needed the official custom-label initializer path, with an explicit AppKit `NSImage` marked as a template image and rendered through SwiftUI as a template label.

**Practical guidance**
For menu bar icon changes, validate four separate things before signing off:
- the generated resource is not empty, using alpha/bounds metrics as a regression guard
- the packaged app uses the intended runtime API path, not just the intended files
- the closed menu bar item is visibly correct
- the opened/highlighted menu bar item is visibly correct

When template rendering matters, prefer `MenuBarExtra(isInserted:content:label:)` with a custom label so Wink can explicitly set `NSImage.isTemplate = true`, use `Image(nsImage:)`, apply `.renderingMode(.template)`, and provide the accessibility label. Consult Apple's `MenuBarExtra` and `NSImage.isTemplate` documentation before changing overloads or asset semantics.

Keep using `System Events` for structure, but do not treat it as visual signoff by itself. It is useful to confirm the item identity and geometry:

```applescript
tell application "System Events"
    tell process "Wink"
        get {role, subrole, description, name, position, size} of every menu bar item of menu bar 2
    end tell
end tell
```

For the final evidence, open the popover and capture the highlighted menu bar item. The issue #228 regression was only obvious in that state. A resource coverage test prevents shipping an empty image; a highlighted-state screenshot proves the user-visible bug is actually gone.

## View-Backed Menu Items Should Stay Renderable, Not Disabled

**Issue**
A custom `NSMenuItem.view` can look correct in unit tests yet disappear from the real menu.

**Cause**
AppKit does not reliably render view-backed menu items when the menu item itself is disabled. In issue #180, the shortcut row views existed in tests and menu composition state, but the packaged app only showed the static menu items until the backing `NSMenuItem` stopped being disabled.

**Practical guidance**
For read-only custom menu rows, keep the menu item renderable and inert rather than disabled. A no-op target/action is safer than `item.isEnabled = false` when the row uses `item.view`. Validate the packaged app menu after any such change, because this is exactly the kind of AppKit behavior that isolated unit tests can miss.

## Visual UI Validation Needs The Real Packaged Window

**Issue**
Settings/UI polish work can look "done" in code review or synthetic rendering, but still miss the real visual mismatch the issue was asking to fix.

**Cause**
SwiftUI structure and regression tests are necessary, but they do not replace the final perception check. Off-screen rendering also skips the real packaged-app window chrome, current appearance, and live spacing/alignment context. On top of that, local macOS debugging can easily leave multiple `Wink` instances running at once, so a screenshot can accidentally come from an older binary.

**Practical guidance**
For presentation-sensitive work, validate the packaged app itself and capture the real `Wink` window before closing the task. Before trusting a screenshot, make sure only the intended `build/Wink.app` instance is running; otherwise you may end up comparing the issue reference against stale UI from an older process. Treat synthetic rendering as a helper, not the sign-off artifact.

## SwiftUI Row Alignment Needs A Layout Contract

**Issue**
A row can still look misaligned even after individual controls get fixed widths. In PR #226, the `Your Shortcuts` keycaps, switches, and row action menus continued to drift because the row accessory controls were fixed locally but the row content itself did not have a reliable width contract inside the scroll view.

**Cause**
SwiftUI stacks only align children within the space the parent proposes. A trailing `Spacer` or per-control `.frame(width:)` is not enough when the row content is still allowed to size to its intrinsic content inside a scroll view. Different app names, metadata, and optional badges can then move the entire accessory cluster, even if each accessory has a fixed width.

**Practical guidance**
For table-like rows, make the layout contract explicit:
- Size the scroll content to the viewport width.
- Let the primary text column expand with `.frame(maxWidth: .infinity, alignment: .leading)` and truncate text there.
- Put trailing controls in one fixed-width accessory group, with fixed subcolumns for optional badges, keycaps, switches, and menus.
- Give the accessory group enough layout priority that narrow widths compress text before controls drift.
- Prefer `LazyVStack` for repeated rows inside `ScrollView`, and consult Apple SwiftUI layout documentation (`frame`, `LazyVStack`, `layoutPriority`, and stack layout behavior) when the layout semantics are unclear.

Do not sign off row alignment from code inspection alone. Capture the final packaged Settings window and check several rows with different content shapes, including at least one Hyper row and one non-Hyper row.

## UI Checklists Must Retire Bad Evidence

**Issue**
A validation report can accidentally keep citing an older screenshot as "final" even after that screenshot visibly contains the bug under discussion.

**Cause**
Long UI validation passes often produce multiple screenshots: exploratory captures, pre-rebase captures, post-rebase captures, and final captures. If the report only records "screenshot exists" instead of a checklist of expected facts, stale evidence can survive after the implementation changes.

**Practical guidance**
For visual regressions, write the checklist at the start of the fix, before editing code or taking the final screenshot. The checklist should come directly from the user's reported issues plus any review-thread risks, and it should drive implementation, screenshots, and PR closeout. Update it as findings appear, but do not wait until the end to invent it from memory. Each claimed screenshot should state the expected UI facts and whether they were observed. If a later inspection proves a screenshot is stale or wrong, mark it as superseded or invalid in the validation artifact instead of leaving it in the evidence chain. In PR #226 the useful checklist should have been created up front with:
- no outer Shortcuts page scrollbar
- stable right-side columns for keycaps, switches, and ellipsis menus
- import preview details own their internal scroller
- row action menu exposes only `Delete Shortcut`
- sidebar width matches the design target while the system sidebar toggle remains intentionally visible

## Design Parity Needs Layout Contracts, Not Just Visual Tweaks

**Issue**
Small design mismatches can keep reappearing after an apparently correct UI polish pass. In PR #236, the Settings UI still had four concrete misses after the first pass: the Insights weekday label `MON` wrapped and increased heatmap row height, `Your Shortcuts` kept a fixed 180pt viewport that left a large empty region below the card, the heatmap needed to keep spanning the card width, and the General page needed to avoid nested/right-side scrolling.

**Cause**
These were not color or spacing-only issues. They were missing layout contracts. A narrow weekday label let SwiftUI wrap text. A fixed shortcut-list height capped the card even when the detail pane had more vertical space. Screenshot inspection caught the symptom, but only regression tests that assert row spacing, scroll-view count, and list viewport bounds keep the same bug from returning.

**Practical guidance**
For UI v2 parity work, turn each screenshot complaint into a concrete layout invariant before signoff:
- Labels that must not wrap should have a single-line contract and enough fixed label width.
- Repeated content should fill the proposed viewport width/height when the design expects it, then scroll internally only when content exceeds that region.
- For fixed-format visual blocks like heatmaps, assert both row compactness and horizontal span in layout tests.
- For pages that should not show an extra scrollbar, assert the expected number of vertical `NSScrollView`s.
- Re-capture the final packaged app after the last source change, then reopen the saved screenshots and verify the named facts again.

Static design comparison tells the direction; a packaged-window screenshot plus layout regression tests are the closeout evidence.

## Custom SwiftUI Controls Need Native Accessibility Semantics

**Issue**
Replacing a native control with a custom visual primitive can quietly regress accessibility. In PR #236, `WinkSegmented` looked like the design's segmented control, but it was implemented as plain buttons. A reviewer correctly flagged that VoiceOver and keyboard users would not get the same selected-state and segmented-control semantics as the previous native segmented picker.

**Cause**
Visual parity and accessibility semantics are separate surfaces. A custom SwiftUI `HStack` of buttons can match the mock visually while exposing the wrong role, selected state, and navigation model to assistive technology.

**Practical guidance**
When replacing native macOS controls with custom design-system primitives, preserve the native accessibility model explicitly. For segmented controls, use an accessibility representation backed by a native `Picker` with `.pickerStyle(.segmented)` and provide a meaningful label at the call site. Keep the visual layer custom only if the accessibility layer remains equivalent to the native control being replaced. Treat review feedback in this area as functional, not cosmetic.

## Async View-Model Tests Should Await The Work They Need

**Issue**
A test can pass locally and fail repeatedly in CI even when the product code is fine. In PR #236, two `MenuBarPopoverViewTests` cases waited up to two seconds for `todayActivationCount` / histogram state to change after `MenuBarPopoverModel` started an internal usage refresh task. Focused local runs passed quickly, but full CI runs repeatedly timed out with the model still showing the initial zero values.

**Cause**
The test was polling an observed side effect with a short wall-clock timeout instead of awaiting the actual async work it depended on. Under full-suite CI scheduling, the main-actor task did not always finish inside the polling window. That made the test timing-sensitive even though the model had a clear internal task boundary.

**Practical guidance**
For view models that start internal refresh tasks, expose a narrow testing seam that awaits the task directly, following the existing `AppListProvider.waitForRefreshForTesting()` pattern. Prefer:

```swift
await model.waitForUsageRefreshForTesting()
```

over repeated `Task.sleep` polling of observable properties. Polling is still useful for UI effects with no owned task boundary, but when the code owns a refresh task, wait on that task. This makes CI failures point at real work failures instead of scheduler timing.

## Cancelled Review Gate Runs Can Look Like Current Failures

**Issue**
The PR checks panel can show "1 failing check" for `Review Gate / Validate review state (pull_request_review)` even after the review thread has been fixed, resolved, and a later Review Gate run has passed.

**Cause**
The Review Gate workflow uses a per-PR concurrency group with `cancel-in-progress: true`. Replying to and resolving a review thread can trigger multiple events close together, such as `pull_request_review` and `pull_request_review_comment`. The older run can be cancelled while a newer run on the same head SHA completes successfully. GitHub's UI may still surface the cancelled run in the rollup, which looks like a failure at first glance.

**Practical guidance**
Do not diagnose this from the PR sidebar alone. Check the run event, head SHA, conclusion, and any later run for the same workflow:

```bash
gh pr view <pr> --json headRefOid,statusCheckRollup
gh run list --branch <branch> --limit 12 \
  --json databaseId,event,headSha,status,conclusion,workflowName,createdAt,url
```

If the failed/cancelled run is superseded by a successful Review Gate run on the same head SHA and unresolved actionable review threads are zero, the remaining blocker is not code. The PR may still be `REVIEW_REQUIRED`, but that is an external approval gate rather than an actionable Review Gate failure.

## DMG Mock Chrome Must Be Reconciled With Real Finder Chrome

**Issue**
An installer mock can include Finder-like chrome that reads well in the design file but does not necessarily belong in the shipped DMG. In issue #184, the editorial DMG mock showed an empty toolbar strip above the content, while the mounted package looked better and behaved more predictably with Finder's real toolbar hidden and no fake toolbar strip painted into the background.

**Cause**
A DMG is rendered inside the user's Finder, not inside the design file. Finder toolbar visibility, sidebar behavior, title-bar chrome, labels, aliases, and appearance can vary by system state. Treating mock chrome as literal product background can create a decorative layer that neither behaves like Finder nor stays visually aligned with it. The same pass also showed that `/Applications` should not be judged from the raw symlink/alias default icon alone: if the design calls for a clear blue folder target, the packaging script needs to create a real Finder alias and apply the custom icon deliberately.

**Practical guidance**
For DMG installer updates, validate the mounted volume window itself before signing off:
- Decide explicitly which mock elements are product content and which only simulate Finder chrome.
- Prefer hiding Finder's toolbar and sidebar for a controlled installer surface unless there is a functional reason to expose them.
- Do not paint fake Finder controls or toolbar strips into the background just to match a static mock.
- Match the background bitmap to the actual no-toolbar Finder content height, otherwise bottom gaps can appear even when the SVG looks correct.
- Use Finder-accurate label sizing and bottom-anchored icon positions, then confirm them in a saved screenshot.
- If the Applications target needs custom presentation, create a Finder alias and apply the icon resource in the packaging script rather than relying on a plain symlink's default appearance.

Record the final mounted screenshot and the exact asset sizes in a validation artifact. Static design comparison is useful for direction, but the mounted Finder window is the sign-off surface.

## Remove Dead Presentation Data When The UI No Longer Needs It

**Issue**
A UI cleanup can still leave hidden maintenance cost behind if the removed surface's data pipeline keeps running in the view model.

**Cause**
It is easy to delete the visible chart/card/rank chrome first and forget that the view model is still fetching, aggregating, and testing data that nothing renders anymore.

**Practical guidance**
Whenever a presentation layer is removed, immediately search for the matching view-model state, background queries, helper types, and regression assertions. If nothing else uses that path, delete it in the same change instead of carrying it forward "just in case." This keeps the feature boundary honest and avoids paying ongoing complexity for dead UI.

## Hyper State Must Be Replayed After Event-Tap Startup

**Issue**
After splitting shortcut capture into Carbon-for-standard and event-tap-for-Hyper, Hyper shortcuts can appear "enabled" while doing nothing immediately after launch or restart.

**Cause**
The desired Hyper state may be set before the event tap has actually started. If the provider forwards `setHyperKeyEnabled(true)` before `EventTapManager.start()` creates its internal callback box, the new tap comes up without Hyper armed even though the app preference and hidutil mapping are both already enabled.

**Practical guidance**
Treat Hyper enablement as desired provider state, not just a fire-and-forget imperative call. Persist it in the event-tap-backed provider and replay it immediately after `start()` succeeds. When validating, do not stop at "eventTap=true" in logs; also confirm live Hyper behavior via `HYPER_INJECT` / `EVENT_TAP_SWALLOW` or real shortcut matches after a fresh launch.

## `NSRunningApplication.hide()` Return Value Is Not the Success Signal

**Issue**
`NSRunningApplication.hide()` can log `apiReturn=false` even when the target app actually hides successfully.

**Cause**
On macOS, hide is an asynchronous request. The immediate API return does not reliably express whether the app will disappear a few milliseconds later.

**Practical guidance**
Log the direct hide request for transport visibility, but treat `TOGGLE_HIDE_CONFIRMED` as the operational success signal. Confirm hide via `NSWorkspace.didHideApplicationNotification` and workspace/frontmost plus hidden-or-windowless observation, not via the raw boolean return value.

## Permission Polling Must Not Imply Capture Re-Registration

**Issue**
A healthy permission poll can still create noisy logs and unnecessary provider churn if every timer tick re-syncs shortcut capture.

**Cause**
Permission health and capture re-registration are separate questions. Polling every few seconds is acceptable for observability, but blindly calling the start/sync path on every poll couples monitoring to mutation.

**Practical guidance**
Keep the periodic permission snapshot lightweight. Only re-sync providers when Accessibility or Input Monitoring actually changed, or when the capture status shows a genuine degraded/not-ready state. In steady state, repeated `checkPermission` lines are acceptable; repeated `attemptStart` / "syncing shortcut capture" lines are not.

## CGEvent Tap Permissions

**Issue**
`AXIsProcessTrusted()` can return true while `CGEvent.tapCreate()` still fails.

**Cause**
On macOS 15, the active event-tap path requires both Accessibility and Input Monitoring. Either permission alone is not enough for Hyper/event-tap capture, but this does not apply to Carbon-registered standard shortcuts.

**Practical guidance**
Check both `AXIsProcessTrusted()` and `CGPreflightListenEventAccess()` before starting the Hyper/event-tap path, but keep readiness split by transport: standard shortcuts can still be ready with Accessibility + Carbon alone, while Hyper shortcuts are only ready after the active event tap starts successfully.

## Input Monitoring Pane Visibility Is Not The Source Of Truth

**Issue**
System Settings can appear to show no Wink row under `Privacy & Security > Input Monitoring` even after Hyper capture has started working.

**Cause**
The macOS 15 SDK contract for `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` only promises whether event-listening access is effective for the current process. It does not promise that System Settings will immediately show, persist, or refresh a visible row for that process. In Wink's 2026-04-15 packaged-app validation, the authoritative runtime signals were already green (`Input Monitoring permission: granted`, active event tap, passing Hyper E2E) even though the pane still looked empty.

**Practical guidance**
When investigating Hyper capture, trust the live runtime signals first: `CGPreflightListenEventAccess()`, the Wink Settings banner, `Event tap started`, and an actual Hyper end-to-end pass. Treat the System Settings pane as helpful but non-authoritative UI that may lag behind live access. Signature churn and launch-path mismatches still matter, so validate with `open Wink.app` and remember that rebuilding or re-signing can change the TCC identity that System Settings associates with the app.

## Suppress Automatic Permission Prompts During E2E Harness Launches

**Issue**
Repeated packaged-app reruns during local runtime validation can stack duplicate macOS permission sheets if each cold start immediately calls the startup prompt path before the previous sheet is resolved.

**Cause**
The product's normal startup path may intentionally use the Accessibility/Input Monitoring prompt APIs, but the E2E harness is a rerun-heavy workflow. When a validation run fails for local TCC reasons and the operator relaunches repeatedly, each fresh launch can enqueue another system sheet instead of producing a clean fail-fast result.

**Practical guidance**
Keep normal product behavior unchanged, but let the repository E2E harness launch Wink with a dedicated `--suppress-automatic-permission-prompts` argument. In that mode, startup still checks live permission state, but it must not call the automatic prompt path; explicit user actions in Settings can still request access when needed. This keeps rerun-heavy validation from creating multiple overlapping system dialogs while preserving truthful readiness failures in the harness.

## A Suppressed Harness Launch Can Still Fail Cleanly On TCC

**Issue**
After adding `--suppress-automatic-permission-prompts`, a freshly rebuilt packaged app may still start with `ax=false im=false carbon=false eventTap=false` and the harness may fail in startup readiness.

**Cause**
The launch argument only suppresses the automatic startup prompt path. It does not change TCC identity matching, and it does not grant permissions by itself. After an ad-hoc rebuild, the first rerun can fail cleanly because the current bundle no longer matches the previous TCC record.

**Practical guidance**
Do not treat that first clean failure as proof that the suppress flag is broken. Treat it as a better diagnostic result: the harness is reporting the local TCC blocker without piling on more permission sheets. Re-grant the exact current packaged bundle, then rerun the suite.

## Duplicate Permission Sheets After Suppression Usually Mean Another Launch Path Exists

**Issue**
You still see repeated macOS permission dialogs even though the E2E harness now launches Wink with `--suppress-automatic-permission-prompts`.

**Cause**
Another launch path is still active. Typical causes are:
- a second `Wink.app` copy launched from another worktree or path
- a system-driven `Quit and Reopen` relaunch that reopened the wrong bundle
- an explicit in-app permission request action, which should still be allowed to prompt

**Practical guidance**
When repeated permission sheets still appear, do not immediately remove the suppression behavior. First verify the running executable path with `pgrep -fal`, inspect the debug log for multiple `Wink starting` lines, and confirm whether the prompt came from an explicit permission request rather than the startup path. Fix the duplicate launch path or wrong bundle relaunch first, then rerun validation.

## Ad-hoc Signing and TCC

**Issue**
Permissions appear enabled in System Settings, but Wink is still not trusted after a rebuild.

**Cause**
TCC binds permissions to the app's code signature. Ad-hoc signatures change between builds, so a new binary no longer matches the old TCC record.

**Practical guidance**
After rebuilding locally, reset and regrant permissions if the app stops matching its previous TCC state:

```bash
tccutil reset Accessibility com.wink.app
tccutil reset ListenEvent com.wink.app
```

For long-lived releases, use a stable Developer ID signature.

## A Visible `Wink` TCC Row Can Still Be Stale

**Issue**
System Settings still shows a `Wink` row, but a freshly rebuilt packaged app launches with readiness logs such as `ax=false im=false carbon=false eventTap=false`.

**Cause**
The visible row can still point at an older bundle path or a previous ad-hoc signature identity. After rebuilding `build/Wink.app`, macOS may keep showing a `Wink` entry even though that record no longer matches the exact current app bundle.

**Practical guidance**
If a newly packaged build still looks untrusted, do not treat the visible `Wink` row as proof that TCC matches the current app. Remove the existing `Wink` row, add the exact current `build/Wink.app` again in the relevant panes, and relaunch the bundle via `open`. For standard-only fixtures that means Accessibility; for Hyper validation, re-add Input Monitoring too.

## Launch Via `open`

**Issue**
Launching the app binary directly can produce different permission behavior than launching the app bundle.

**Cause**
TCC and app identity matching are tied to the bundle launch path. Directly running `./Wink.app/Contents/MacOS/Wink` can bypass the launch context used during permission registration.

**Practical guidance**
Validate permission-sensitive behavior by starting the app with `open Wink.app`, not by executing the binary directly.

## File-Based Diagnostics

**Issue**
`log stream` and `log show` may not expose the diagnostics needed during local debugging.

**Cause**
Unified logging is filtered and can hide the messages you expect to see.

**Practical guidance**
Use a file-backed log for troubleshooting, such as `~/.config/Wink/debug.log`. Create the parent directory first, then append short diagnostic lines there.

## `@Sendable` Completion Handlers

**Issue**
`NSWorkspace.openApplication` can crash or assert when its completion handler touches main-actor state.

**Cause**
The completion callback may arrive on a background queue, while captured values from `@MainActor` context remain isolated unless they are extracted safely.

**Practical guidance**
Copy any needed values before the call, and mark the completion handler `@Sendable`. Keep the closure free of implicit main-actor assumptions.

## SkyLight Activation

**Issue**
`NSRunningApplication.activate()` is unreliable for bringing an LSUIElement app to the foreground on macOS 14+.

**Cause**
The cooperative activation path can report success without actually activating the app.

**Practical guidance**
Use the SkyLight-based activation path when Wink must reliably front the target app. Treat it as the validated route for LSUIElement activation behavior.

## Frontmost Truth for Toggle Semantics

**Issue**
An app can appear visually present while Wink still should not treat it as safely toggleable.

**Cause**
App activation on macOS is transitional. `NSRunningApplication.activate()` only attempts activation, and `NSRunningApplication.isActive` can briefly disagree with `NSWorkspace.shared.frontmostApplication` during odd system-app or window-recovery flows.

**Practical guidance**
For app-level toggle behavior, treat `NSWorkspace.shared.frontmostApplication` as the primary truth because Apple defines it as the app receiving key events. Use `isActive`, `isHidden`, and window visibility as supporting signals, not as the sole toggle-off gate.

## Stable Activation Beats Instantaneous Activation

**Issue**
Repeated shortcut presses can flap between "activate" and "toggle off" if Wink decides from a single immediate state snapshot.

**Cause**
The first trigger may only have started activation, while the second trigger arrives before the app has reached a stable frontmost state with a usable window.

**Practical guidance**
Do not let "activation requested" mean "activation complete". Require a short post-activation confirmation pass and only allow toggle-off from a stable active state. During pending or degraded activation, a repeat trigger should re-confirm or re-attempt activation instead of making hide/reactivate decisions from a transient snapshot.

## Retiring Previous-App Memory When It Stops Driving Behavior

**Issue**
State-machine fields become review traps when they no longer feed runtime decisions but still look authoritative in code and docs.

**Cause**
Wink used to need previous-app memory for restore-oriented toggle-off designs. After the runtime moved to `NSRunningApplication.hide()` plus observation-based confirmation, that value only flowed into logs and snapshots. Keeping it made reviewers treat telemetry drift as a behavior bug.

**Practical guidance**
Trace state-machine values to their final sink before assigning severity. If a field only feeds diagnostics and no runtime branch consumes it, either rename it as telemetry or remove it outright. Do not keep a compatibility field just because older plans mention it.

## Bundle-Only Tracking Fails Across Process Lifetimes

**Issue**
Launch -> quit -> relaunch flows can leave Wink believing a target is both "stable" and "missing" at the same time.

**Cause**
When bundle-keyed session tracking is duplicated across multiple owners, termination or pid rollover can clear one owner while the other still holds stale stable/pending state. That is how relaunch paths degrade into `phase=no_session`, `hide_untracked`, or other ownership confusion right after an otherwise valid launch.

**Practical guidance**
Make `ToggleSessionCoordinator` the only lifecycle owner. Keep pid, attempt id, phase, activation path, and timing on that single session object, and reset or replace the session on termination and pid rollover. `AppSwitcher` may expose derived read-only views, but it must not become a second mutable lifecycle owner.

Do not throw away the `NSRunningApplication` returned by `NSWorkspace.openApplication`. The launch completion is the cleanest process-identity seam Wink gets for a just-launched target. Attach that pid back onto the existing `launching` session immediately and run the same confirmation pipeline used by activate/unhide, or the next press can still fall through to `hide_untracked` despite an otherwise successful launch.

## Frontmost Without Window Evidence Is Not Success For Regular Apps

**Issue**
A regular app can become frontmost and active without restoring a usable window, making toggle-on look "successful" even though the user still sees no target window to work with.

**Cause**
Treating all frontmost non-hidden apps as stable collapses accessory utilities and normal windowed apps into the same success path. That hides exactly the failure mode users care about: the app is technically foregrounded, but still not actually usable.

**Practical guidance**
Only allow windowless stable success for targets whose `activationPolicy != .regular`. For `.regular` apps, require at least one of `visibleWindowCount > 0`, `hasFocusedWindow == true`, or `hasMainWindow == true` before promoting to `activeStable`. If that evidence never arrives, stay in pending/visibility-recovery or degrade explicitly; do not silently coerce the state into success.

## Attempt-Scoped Trace Logs Beat Outcome-Only Logging

**Issue**
Outcome logs such as `TOGGLE_STABLE` or `TOGGLE_HIDE_DEGRADED` are not enough to explain which branch Wink took when launch, relaunch, deactivation, and ownership invalidation happen close together.

**Cause**
Without an attempt-level identifier, log readers have to infer which launch, confirmation, and reset lines belong together. That breaks down quickly around relaunches, pid changes, or repeated key presses.

**Practical guidance**
Emit trace logs with `attemptId`, `bundle`, `pid`, `phase`, `event`, `activationPath`, and `reason`. Keep them at the matched-shortcut and lifecycle-transition boundaries, not on every raw key event. The goal is that one failed attempt window in `~/.config/Wink/debug.log` is enough to reconstruct the branch choice end-to-end.

## Notification-Driven Toggle Invalidation

**Issue**
Stable toggle state can become stale as soon as the user changes apps outside Wink.

**Cause**
Polling or one-shot snapshots miss external activation and termination changes, especially while a toggle session is still marked `activeStable` or `deactivating`.

**Practical guidance**
Use `NSWorkspace.didActivateApplicationNotification` to drop stable/deactivating sessions when another app becomes frontmost, and `NSWorkspace.didTerminateApplicationNotification` to clear sessions for terminated targets. This keeps runtime state aligned with user-visible app focus without adding polling noise.

## System Apps Need Honest Downgrade Rules

**Issue**
Apps such as Home can produce visible windows without behaving like normal key-window-driven document apps.

**Cause**
Some system utilities use nonstandard scene, hide/unhide, or window activation behavior that does not match assumptions baked into regular AppKit apps.

**Practical guidance**
Do not force all apps through one generic "front app with visible window means success" rule. Keep a degraded-success path for system or window-weird apps, log why the app is degraded, and avoid counting degraded activation as safe toggle-off state.

## Untracked Frontmost Apps Need a Direct Hide Path

**Issue**
An app can be frontmost and apparently stable even though Wink has no active stable session for it.

**Cause**
Apps can become frontmost through paths Wink does not own: Dock click, Cmd-Tab, macOS choosing the next app after a hide, or another app flow returning them to the foreground. `stableActivationState` only exists for apps Wink itself recently stabilized, so these externally surfaced apps may otherwise fall through to the activate path.

**Practical guidance**
When the target app is already active and frontmost but has no tracking state, treat it as an untracked toggle-off: hide the app and let macOS bring the next app forward. Log the `hide_untracked` path with coordinator phase and observation state for post-hoc analysis.

The hide-untracked branch still needs a real owned deactivation session. Logging `hide_untracked` alone is not enough: if the branch does not allocate a coordinator-owned `deactivating` session first, later `HIDE_REQUEST` / hide-confirmation guards can no-op and the target will remain frontmost even though Wink chose the correct branch in logs.

## Verify The Persisted Shortcut Route Before Debugging Capture Readiness

**Issue**
`checkPermission: ax=true im=true carbon=false eventTap=true` can look like Carbon registration drift even when the capture stack is actually behaving correctly.

**Cause**
Wink's active transport depends on the current saved shortcut set plus `hyperKeyEnabled`. If the persisted shortcut is a Hyper combo, then `carbon=false eventTap=true` is the expected readiness snapshot. In the 2026-04-09 Safari investigation, the real culprit was not permission loss or Carbon failure: `shortcuts.json` had already been switched to `command` + `option` + `control` + `shift` + `s`, and `hyperKeyEnabled` was still enabled.

**Practical guidance**
Before debugging transport readiness, inspect the actual persisted shortcut config and Hyper toggle state. Do not assume the active shortcut is still standard because an older session used `Shift+Cmd+S`. Interpret `carbon` / `eventTap` logs against the current saved shortcut route, not against stale expectations.

## Restore Hyper State Before Starting Capture

**Issue**
Startup diagnostics can report a transport that is already obsolete by the time the app is actually accepting shortcuts.

**Cause**
If `ShortcutManager.start()` runs before the persisted Hyper state is replayed, the first readiness log reflects the pre-restore transport instead of the real steady-state routing. That is how a valid Hyper configuration can briefly print `attemptStart: ... carbon=true eventTap=false` and look like transport drift.

**Practical guidance**
Replay the persisted Hyper enablement before starting shortcut capture. The first `attemptStart` / readiness snapshot should describe the transport Wink will actually use after launch, not a transient bootstrapping state that disappears one call later.

## Validation Readiness Must Be Transport-Specific

**Issue**
An E2E harness can falsely report startup failure even while the configured shortcut transport is healthy.

**Cause**
Standard shortcuts and Hyper shortcuts have different readiness predicates. Waiting unconditionally for `Event tap started` treats event-tap availability as a universal startup requirement, but a standard-only shortcut set is valid with `carbon=true eventTap=false`.

**Practical guidance**
Drive validation off the active transport, not a one-size-fits-all startup marker. For standard shortcuts, require Accessibility plus successful Carbon registration. For Hyper shortcuts, require Input Monitoring plus an active event tap. Keep the validation rule aligned with the same transport-specific readiness semantics used in production code.
For mixed fixtures, expect both transports to be ready at once (`carbon=true` and `eventTap=true`) and make the harness wait for both before declaring startup healthy.

## E2E Fixtures Must Match The Saved Shortcut Set

**Issue**
An end-to-end module can fail even when the product is healthy if the machine's saved shortcuts do not contain the fixture shortcut the module is trying to exercise.

**Cause**
The E2E shell modules historically assumed a fixed local fixture, such as Safari on `Shift+Cmd+S` and IINA on a Hyper combo. When `shortcuts.json` drifts away from that fixture, the module reports a product failure even though Wink is simply following the saved config.

**Practical guidance**
Teach each E2E module to inspect the current saved shortcuts before asserting on runtime behavior. If the required shortcut is absent for the expected route, report `SKIP`/`WARN` instead of `FAIL`. Reserve hard failures for mismatches between the configured shortcut and the observed runtime behavior.

## Tests Must Not Use Live Application Support Persistence

**Issue**
`swift test` can silently mutate the real `~/Library/Application Support/Wink/shortcuts.json`, contaminating the developer's local shortcut fixture and making test runs unsafe.

**Cause**
Some test helpers built `ShortcutManager` or `AppPreferences` with a default `PersistenceService()`. The live default storage path resolves through `StoragePaths.appSupportDirectory()`, so any test save path that does not inject `storageURLProvider` writes into the user's real Application Support directory.

**Practical guidance**
Treat the default `PersistenceService()` initializer as runtime-only. Any test that exercises save/load behavior through `ShortcutManager`, `AppPreferences`, or related helpers must inject an isolated persistence service backed by a temporary directory. Reuse a shared test harness instead of open-coding ad hoc temp paths so new tests inherit isolation by default. When verifying this boundary, compare the real `shortcuts.json` checksum before and after `swift test`; unchanged bytes are the acceptance signal.

## Previous-App Self-Reference Was A Symptom, Not The Runtime Contract

**Issue**
Old previous-app telemetry could self-reference the target bundle and make review output sound more severe than the runtime effect actually was.

**Cause**
The previous-app field had drifted from a decision input to a log-only value. Once normal toggle-off stopped restoring that bundle, self-reference no longer changed behavior; it only made diagnostics noisy and docs misleading.

**Practical guidance**
Do not solve telemetry-only drift with more guard logic unless the telemetry is still worth keeping. In issue #229 the correct fix was to remove the previous-app field from sessions, pending state, and trace/lifecycle logs.

## DiagnosticLog.log() Uses queue.async to Avoid Blocking

**Issue**
`DiagnosticLogWriter.log()` originally used `queue.sync` which blocked the calling thread until file I/O completed. When called from `toggleApplication` on the main actor, each call blocked the main thread for a FileHandle open/seek/write/close cycle.

**Cause**
The `queue.sync` pattern was chosen for ordered log output, but the cost was blocking I/O on the calling thread.

**Resolution**
Switched to `queue.async`. The serial queue still guarantees ordered output. Timestamp is captured before dispatch to preserve accurate timing. A `flush()` method is available for tests that need to read logs immediately after writing.

## Reference: alt-tab-macos Activation Strategy (2026-03-25)

**Context**
Compared Wink's toggle implementation with alt-tab-macos (https://github.com/lwouis/alt-tab-macos), the most mature macOS window switcher.
This comparison predates the 2026-04-08 capture split and front-process-first activation hot path, so read it as historical reference, not as a full description of the current runtime.

**Key findings**
- alt-tab uses a "show-select-focus" model, not toggle. No stableActivationState equivalent — just a `appIsBeingUsed` boolean.
- Three-layer activation (SkyLight + makeKeyWindow 0xf8 + AXRaise) is identical to Wink's approach.
- alt-tab runs SkyLight/AX calls on a background queue (`BackgroundWork.accessibilityCommandsQueue`), not the main thread. Wink runs them on the main actor.
- alt-tab tracks frontmost app via AX notifications (`kAXApplicationActivatedNotification`) rather than NSWorkspace notifications. More real-time but more complex.
- alt-tab maintains full MRU window ordering (`lastFocusOrder`), not just a single previous app.
- alt-tab has `redundantSafetyMeasures()` that polls hardware modifier state after each key event to detect lost keyUp events.
- alt-tab has no debounce/cooldown — its show-select-focus model doesn't need it.

**Hammerspoon 对比 (https://github.com/Hammerspoon/hammerspoon):**
- 激活方案更保守：NSRunningApplication + Carbon PSN 双层（无 SkyLight）
- 窗口焦点：纯 AXUIElement (becomeMain + raise)，无 SkyLight makeKeyWindow
- 前台监控：NSWorkspace 通知（与 Wink 一致）
- Event tap 在**主线程**运行（Wink 在后台线程更好）
- 专门为 Finder 写了 0.3s 延迟 workaround — 说明纯 AX 方案不够可靠
- Hotkey 用 Carbon RegisterEventHotKey 而非 CGEventTap（更轻量但功能受限）

**Practical guidance**
仍然成立的结论有两点：Wink 需要 SkyLight 作为 LSUIElement 的可靠强激活基础；后台线程 event tap 仍优于主线程 tap。已经过时的部分是“完整三层激活始终在热路径上”和“所有快捷键都要靠 event tap”这两个心智模型。当前更准确的做法是：标准快捷键优先走 Carbon，Hyper 才走 event tap；激活热路径先做 front-process 激活，只在观察显示未稳定时再逐级升级到 `makeKeyWindow` / `AXRaise` / window recovery。

## CGEvent.timestamp Is Nanoseconds, Not Mach Ticks

**Issue**
Code comments or variable names may refer to `CGEvent.timestamp` as "Mach absolute ticks", leading to incorrect unit assumptions.

**Cause**
Apple's `CGEventTypes.h` defines `CGEventTimestamp` as "roughly, nanoseconds since startup." On Apple Silicon, raw `mach_absolute_time()` ticks are ~41.67 ns/tick (24 MHz clock, per QA1398), which is a different unit. `CGEvent.timestamp` is pre-converted to nanoseconds by the system.

**Practical guidance**
Always treat `CGEvent.timestamp` values as nanoseconds. When computing elapsed time between events (e.g., for the 80ms Caps Lock toggle quirk threshold), use `80_000_000` (80M nanoseconds), not Mach ticks. Note that test-created CGEvents via `CGEvent(keyboardEventSource:virtualKey:keyDown:)` may have a timestamp of 0, so do not use timestamp `> 0` as a sentinel for "has been set."

## Dual Event Paths for Remapped Keys Need Mutual Exclusion

**Issue**
When Caps Lock is remapped to F19 via `hidutil`, the system may generate both `keyDown`/`keyUp` and `flagsChanged` events for the same physical key press.

**Cause**
`hidutil` remapping changes the key code but does not fully suppress the modifier-flag machinery. On some macOS versions, the remapped key produces `keyDown`/`keyUp` (primary path), while the underlying Caps Lock toggle still fires `flagsChanged` events.

**Practical guidance**
If both event types are handled in a CGEvent tap callback, the two code paths must be mutually exclusive for the same key code. Use a flag (e.g., `_f19ReceivedViaKeyDown`) to detect which path is active and skip the other. The `flagsChanged` path should still swallow the event (return nil) to prevent it from reaching applications, but must not modify shared state that the `keyDown`/`keyUp` path owns. Reset the mutual-exclusion flag when the feature is disabled so the fallback path remains available after re-enable.

## osascript `key code` 无法模拟按住按键

**Issue**
E2E 测试中 `send_hyper_combo` 用 osascript `key code 80; key code 0` 测 Hyper Key，测试"偶然"通过但实际没测到真实场景。

**Cause**
osascript `key code N` 发送完整的 keyDown+keyUp 对，无法模拟"按住 F19 同时按字母"。旧测试能通过纯粹是因为 deferred keyUp 机制（80ms 阈值）恰好兜住了 F19 的瞬时 keyUp。一旦 osascript 处理延迟 >80ms，测试就会失败。

**Practical guidance**
需要独立控制 keyDown/keyUp 时，用编译的 Swift helper 通过 `CGEvent.post(tap: .cghidEventTap)` 发送事件。遵循业界做法：
- **Event Source**: `CGEventSource(stateID: .hidSystemState)`（Karabiner-Elements、KeyboardSimulator 均使用）
- **Tap Location**: `.cghidEventTap`（Apple CGEvent.h: 事件从 HID 层流过所有下游 session tap）
- **Timing**: modifier→key 10ms, key down→up 1ms（Karabiner-Elements appendix/cg_post_event 的模式）
- **Combo 序列**: holdKey↓ → 10ms → tapKey↓ → 1ms → tapKey↑ → 10ms → holdKey↑

参考项目：Karabiner-Elements (`appendix/cg_post_event`)、Hammerspoon (`eventtap/libeventtap.m`)、skhd (`src/synthesize.c`)。

## HID Usage Code ≠ Carbon Virtual KeyCode

**Issue**
hidutil `UserKeyMapping` 声称映射 Caps Lock → F19，`hidutil property --get` 也显示映射活跃，但物理 Caps Lock 按键在 CGEvent tap 中产生 F13 (keyCode=105) 而非 F19 (keyCode=80)。

**Cause**
HID usage code 和 Carbon virtual key code 是两套完全不同的编码系统。常见陷阱：
- F13 HID usage = `0x68` → 完整 HID usage = `0x700000068`
- F19 HID usage = `0x6E` → 完整 HID usage = `0x70000006E`
- F13 Carbon keyCode = `105` (kVK_F13 = 0x69)
- F19 Carbon keyCode = `80` (kVK_F19 = 0x50)

原始代码将 `f19Usage` 错误设为 `0x700000068`（实际是 F13），导致 hidutil 把 Caps Lock 映射到 F13，但 event tap 在监听 keyCode=80 (F19)。两者完全不匹配。

**Practical guidance**
在 Apple TN2450 的 HID usage table 中查找正确的 usage 值。不要混淆 HID usage (0x07 page) 和 Carbon virtual key code (Events.h)。编写映射代码时，用物理按键测试验证映射结果——osascript `key code N` 直接注入 CGEvent，绕过 HID 层，无法测出 HID usage 错误。验证 hidutil 映射时，必须使用物理按键 + event tap 日志确认实际收到的 keyCode。

**Reference**
- Apple TN2450: HID usage codes (0x07 page)
- Carbon Events.h: virtual key codes (kVK_*)
- HID Keyboard page: F13=0x68, F14=0x69, F15=0x6A, F16=0x6B, F17=0x6C, F18=0x6D, F19=0x6E, F20=0x6F
- Carbon: kVK_F13=0x69(105), kVK_F19=0x50(80)

## Do NOT Use Headless Mode (claude -p) for Loop Jobs

**Issue**
The original loop job used `claude -p` (headless mode) with `--output-format stream-json --verbose`, producing unreadable JSON noise in terminal output.

**Cause**
Headless mode (`-p`) disables all interactive features: skills (`/code-review`, `/simplify`), clean output formatting, and session-level capabilities. The `stream-json` format dumps raw JSON with session_id, token statistics, and cost metadata on every line. Adding `--verbose` (required by `stream-json`) makes it worse. There is no output format option in `-p` mode that provides both real-time visibility and human readability.

**Practical guidance**
Always use `/loop` for recurring automated work. `/loop` runs in interactive mode where skills work natively, output is clean, and no shell scripting infrastructure (tmux, stdbuf, tee, signal traps, circuit breakers) is needed. Example:

```
/loop 30m Follow the instructions in docs/loop-prompt.md
```

## Review Tool Behavior Differences in Loop Jobs

**Issue**
The three review tools have different output destinations. Treating them uniformly leads to missed findings or empty checks.

**Cause**
- `/code-review` ([code-review plugin](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/code-review)) **posts PR comments** via `gh pr comment`. Findings use confidence scoring (≥80 threshold). Readable across iterations via `gh pr view --comments`.
- `@chatgpt-codex-connector[bot]` (Codex Review) **posts PR comments** with P0/P1/P2 priority tags. Also readable via `gh pr view --comments`.
- `/codex:review` ([Codex Plugin CC](https://github.com/openai/codex-plugin-cc)) outputs results **only within the Claude Code session**. Results live in session memory, not on the PR.

**Practical guidance**
- `/code-review` and bot reviews: check via `gh pr view <number> --comments` — works across iterations.
- `/codex:review`: check session memory only. Session context persists across `/loop` iterations, but findings are not durable beyond the session.
- After pushing code, the working tree is clean. Use `--base main` to review the branch diff: `/codex:review --base main --background`. Retrieve results with `/codex:status` + `/codex:result`.
- Note: `/review` is **deprecated**. Use `/code-review` (requires plugin install: `claude plugin install code-review@claude-plugins-official`).

## Loop Job Prompt Deduplication

**Issue**
CronCreate loop job 在单次 fire 中将 prompt 重复发送了 5 次，导致同一迭代收到 5 份相同的指令。

**Cause**
Loop prompt 内容过长（完整的 docs/loop-prompt.md），可能触发了 CronCreate 的重复投递。此外 loop fire 可能在当前迭代的 review gate 过程中再次触发，打断正在进行的 /review → merge 流程。

**Practical guidance**
- 监控 loop fire 是否重复投递，如出现重复应检查 prompt 长度和 cron 配置
- Loop prompt 应考虑添加幂等性检查：在迭代开始时检查是否有未完成的上一迭代工作
- Review gate 和 merge 操作可能耗时较长，10 分钟间隔在复杂 PR 时可能不够

## Event Tap Timeout Recovery Needs Escalation

**Issue**
Re-enabling an event tap after a timeout is necessary but not always sufficient.

**Cause**
macOS can repeatedly disable the tap with `tapDisabledByTimeout`, which indicates sustained callback or lifecycle pressure rather than a one-off interruption.

**Practical guidance**
Keep the callback path light and re-enable in place first, but track rolling timeout counts. In Wink's current recovery ladder, the first timeout stays in-place, 3 timeouts within 30 seconds escalate to full recreation, and 2 recreation failures within 120 seconds mark the tap subsystem degraded. Recreate the tap on the same dedicated background RunLoop thread, using a reusable readiness mechanism so repeated add/remove/recreate cycles do not deadlock.

## Codex Stop Hook Infinite Loop

**Issue**
The Codex plugin `Stop` hook (`stop-review-gate-hook.mjs`) enters an infinite loop when the Codex CLI is unavailable: hook fails, emits `decision: "block"`, Claude responds, Stop hook fires again, fails again, and repeats indefinitely.

**Cause**
`stop-review-gate-hook.mjs` always emits `block` when `runStopReview()` returns `status !== 0`, without distinguishing between "review found issues" and "Codex CLI infrastructure failure." When Codex cannot connect (unauthenticated, network issues, etc.), every Stop attempt is blocked, producing dozens of repeated error messages in the conversation.

**Practical guidance**
- When the Stop hook loops, temporarily disable `stopReviewGate`: edit `~/.claude/plugins/data/codex-openai-codex/state/<project>/state.json` and change `"stopReviewGate": true` to `false`.
- The root fix belongs in the hook script: infrastructure failures (Codex CLI unavailable) should warn, not block.
- Before enabling `stopReviewGate`, ensure `codex login` authentication is working.

## babysit-prs Bot Review Findings Must All Block Merge

**Issue**
The babysit-prs merge criteria originally only checked P0/P1 bot review findings, allowing real bugs at lower priority levels to be merged without being fixed.

**Cause**
The merge condition read "No unresolved P0/P1 bot review findings", while Step 1c treated P2+ as "fix if easy, otherwise comment why skipped." This gap meant a lower-priority finding that was not fixed in Step 1c would not block the merge in Step 1a.

**Practical guidance**
- All bot review findings (any priority) now block merge (updated in skill.md and review-gates.md).
- A finding may only be skipped if it is clearly a false positive or provides no actionable value — the dismissal must be explained in a PR comment.
- If a real issue is found, fix it regardless of priority.
- Example: PR #113 was merged with an unresolved P2 stale-cache-hints bug, requiring a follow-up fix in PR #114.

## Loop Job Rate Limit Empty Cycling (#118)

**Issue**
`/loop 30m /babysit-prs` continues firing every 30 minutes during API quota exhaustion, producing repeated "You've hit your limit" messages with no useful work.

**Cause**
`/loop` has no built-in error detection or circuit breaker. When API quota is fully exhausted, Claude cannot respond at all — skill code never executes, so no in-skill logic can prevent the next fire.

**Practical guidance**
A two-layer mitigation is in place:
1. Skill-level circuit breaker in Iteration Guard reads `logs/loop-circuit-breaker.json` and skips iterations during cooldown (exponential backoff up to 4 hours)
2. Stop hook (`.claude/hooks/rate-limit-detector.sh`) detects rate-limit signals in the session transcript and writes cooldown state for the next iteration
This handles soft limits and post-recovery transitions. Full quota exhaustion still causes empty fires — this is a `/loop` infrastructure limitation that requires upstream improvement.
