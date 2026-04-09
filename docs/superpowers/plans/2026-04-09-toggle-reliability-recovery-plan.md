# Toggle Reliability Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate Quickey's first-launch / relaunch toggle failures and frontmost-without-window false positives by replacing the current split-brain activation tracking with a pid-aware toggle session model, and make future failures diagnosable from one pass of logs.

**Architecture:** Keep shortcut matching, window observation, and platform activation separate, but move toggle lifecycle ownership into a single canonical session model owned by `ToggleSessionCoordinator`, with `AppSwitcher` acting as the façade that drives transitions. Borrow Zed's "pending input is first-class state" and "debug the current matching context directly" ideas, but do not copy its editor-specific keybinding system into Quickey's global shortcut path.

**Tech Stack:** Swift 6, AppKit, Accessibility APIs, Carbon hotkeys, NSWorkspace, file-backed diagnostic logging, Swift Testing.

---

## Research Summary

### What the current Quickey evidence proves

- `~/.config/Quickey/debug.log` shows a concrete relaunch failure window at `2026-04-09T01:23:34Z` to `2026-04-09T01:23:35Z`: `NOT RUNNING → launching` is followed by `stableState invalidated by coordinator, phase=no_session`, then `TOGGLE_HIDE_UNTRACKED`, then `TOGGLE_HIDE_DEGRADED` even though Safari is frontmost and window-complete. See [`debug.log:17216`](/Users/yvan/.config/Quickey/debug.log:17216) through [`debug.log:17223`](/Users/yvan/.config/Quickey/debug.log:17223).
- `~/.config/Quickey/debug.log` also shows a different failure class on the "toggle on" side. At `2026-04-09T01:47:27Z`, the shortcut definitely matches and the activation request definitely runs, but Quickey records success while Safari still has `visibleWindowCount=0`, `hasFocusedWindow=false`, and `hasMainWindow=false`. See [`debug.log:18008`](/Users/yvan/.config/Quickey/debug.log:18008) through [`debug.log:18013`](/Users/yvan/.config/Quickey/debug.log:18013). This means at least one current "toggle on doesn't work" symptom is not a capture failure; it is a false-positive success classification.
- The current stability rule in [ApplicationObservation.swift](/Users/yvan/developer/Quickey/Sources/Quickey/Services/ApplicationObservation.swift#L33) makes that false positive possible: `.windowlessOrAccessory` is always considered stable once the app is frontmost, active, and not hidden. For user-facing regular apps, that collapses "frontmost with no restored window" into "successful toggle on". See [ApplicationObservation.swift](/Users/yvan/developer/Quickey/Sources/Quickey/Services/ApplicationObservation.swift#L38) through [ApplicationObservation.swift](/Users/yvan/developer/Quickey/Sources/Quickey/Services/ApplicationObservation.swift#L45).
- The logs also prove Quickey can distinguish a real window-stabilization sequence when the app does have a visible window. At `2026-04-09T01:30:38Z`, Safari transitions through `TOGGLE_DEGRADED` while `hasFocusedWindow=false`, then only becomes stable after the focused window arrives. See [`debug.log:17618`](/Users/yvan/.config/Quickey/debug.log:17618) through [`debug.log:17626`](/Users/yvan/.config/Quickey/debug.log:17626). That is valuable because it shows the log format already has enough raw signals; the state machine is what is collapsing incompatible cases.
- Current launch handling in [AppSwitcher.swift](/Users/yvan/developer/Quickey/Sources/Quickey/Services/AppSwitcher.swift#L642) only opens the app and returns. It does not create a tracked pending activation, does not attach a pid, and does not schedule confirmation for the launched process.
- Current session state is split across two owners:
  - [AppSwitcher.swift](/Users/yvan/developer/Quickey/Sources/Quickey/Services/AppSwitcher.swift) keeps `pendingActivationState`, `pendingDeactivationState`, and `stableActivationState`.
  - [ToggleSessionCoordinator.swift](/Users/yvan/developer/Quickey/Sources/Quickey/Services/ToggleSessionCoordinator.swift#L213) keeps a separate bundle-keyed session store and independently reacts to workspace notifications.
- That split lets local AppSwitcher state and coordinator state diverge at process lifetime boundaries. The `phase=no_session` log line is the direct proof that one side still believed the bundle was stable while the other side had already dropped the session.

### What Zed is worth copying, and what is not

- Zed treats pending keyboard input as explicit state in [key_dispatch.rs](/tmp/zed/crates/gpui/src/key_dispatch.rs#L476). A keystroke dispatch returns `bindings`, `pending`, and `to_replay`, rather than hiding the in-flight state inside ad hoc branches. That is the main architectural lesson for Quickey: in-flight toggle state should be explicit and queryable.
- Zed provides a dedicated key-debug surface in [key_context_view.rs](/tmp/zed/crates/language_tools/src/key_context_view.rs#L24), which records pending keys, context stack, candidate bindings, and match outcome. The lesson for Quickey is not "build the same UI", but "make the current state machine and branch decisions directly observable."
- Zed keeps macOS platform primitives thin in [platform.rs](/tmp/zed/crates/gpui_macos/src/platform.rs#L555): `activate` and `hide` are wrappers, while higher-level semantics live elsewhere. Quickey should move in the same direction: platform calls stay dumb; toggle lifecycle logic stays in one state owner.
- Zed's user-facing keybinding docs explicitly document precedence, pending sequences, and a debugging command in [key-bindings.md](/tmp/zed/docs/src/key-bindings.md#L39). Quickey should adopt the same level of explicitness for shortcut/toggle diagnostics, but Quickey is not an editor and does not need Zed's context-tree binding system.

### What Raycast is worth copying, and what is not

- Raycast's official manual treats hotkeys as first-class global triggers for applications, commands, quicklinks, and window-management actions, not just as a way to open the launcher. See [Hotkey](https://manual.raycast.com/hotkey) and [Command Aliases and Hotkeys](https://manual.raycast.com/command-aliases-and-hotkeys). The lesson for Quickey is that the shortcut should directly own the command semantics; users should not have to mentally translate one hotkey into several hidden phases.
- Raycast's recorder explicitly surfaces conflicts and lets the user choose layout-independent versus key-equivalent recording, as well as single-tap and double-tap modifier triggers. See [Shortcuts](https://manual.raycast.com/windows/shortcuts). Quickey does not need to copy the full settings UI right now, but it should preserve enough structured shortcut metadata that conflict diagnosis and keyboard-layout issues remain explainable.
- Raycast's changelog explicitly calls out a hotkey bugfix: "Global hotkey now unhides app if windows are minimized." See [Raycast v1.80.0](https://www.raycast.com/changelog/macos/1-80-0). That is a valuable product cue for Quickey: minimized/hidden/unhidden is not an incidental edge case, it is a first-class branch of launcher semantics.
- Raycast also separates "switch windows" from generic app launching and exposes window/app actions directly. See [Raycast v1.19.0](https://www.raycast.com/changelog/1-19-0) and the fix note in [Raycast v1.77.0](https://www.raycast.com/changelog/1-77-0), which explicitly mentions fixing tracking for windows of apps launched after the initial command use. Quickey should not grow into a full window switcher in this cycle, but it should stop collapsing "app exists but is minimized", "app exists with visible windows", and "app is not running" into one under-specified toggle lane.

### What Keyboard Maestro is worth copying, and what is not

- Keyboard Maestro treats switching and launching as specialized products, not as a byproduct of generic hotkeys. Its documentation explicitly separates `Application Launcher`, `Application Switcher`, and `Window Switcher`, and describes the switchers as dedicated actions that can launch, switch, hide, quit, show, and minimize. See [Keyboard Maestro documentation](https://www.keyboardmaestro.com/documentation-keyboardmaestro/6/keyboardmaestro.pdf). The lesson for Quickey is that "bring app forward", "toggle app visibility", and "switch windows" are close cousins, but they are not the same state machine.
- Keyboard Maestro also treats activation scope as first-class configuration. `Macro Groups` can be global, app-specific, excluded from specific apps, or manually activated/deactivated as a mode. See [Macro Groups](https://wiki.keyboardmaestro.com/manual/Macro_Groups). Quickey should copy the mental model, not the full feature set: shortcut availability and toggle semantics need explicit context, not implied side effects.
- Keyboard Maestro's docs repeatedly expose user-visible failure boundaries such as "Window Switcher can only see windows in the current Space" and that the engine performs switcher behavior even when the editor is not open. See [Keyboard Maestro documentation](https://www.keyboardmaestro.com/documentation-keyboardmaestro/6/keyboardmaestro.pdf). Quickey should be equally explicit about what part of the system owns hotkey capture, what part owns toggle lifecycle, and which platform limits still apply.

### What BetterTouchTool is worth copying, and what is not

- BetterTouchTool separates trigger definition from action execution. Its official docs distinguish global triggers, app-specific triggers, and named triggers that can be reused from multiple physical triggers or called from scripts. See [Global and App-Specific Triggers](https://docs.folivora.ai/docs/2_2_preferences_global_vs_app_specific.html) and [Reusable Named Triggers](https://docs.folivora.ai/docs/other-triggers/named-triggers/). Quickey should borrow that separation: one shortcut should map to one explicit toggle command object, while launch/unhide/focus/hide remain downstream execution branches.
- BetterTouchTool also exposes a scripting and CLI surface for triggering the same actions programmatically. See [CLI](https://docs.folivora.ai/docs/scripting/cli/) and [URL Scheme](https://docs.folivora.ai/docs/scripting/url-scheme/). Quickey does not need to grow a scripting API in this cycle, but the design implication is useful: action semantics should be stable enough that they can be invoked and debugged independently of the physical hotkey source.

### What Thor is worth copying, and what is not

- The local Thor checkout confirms the product is intentionally minimal. In [ShortcutMonitor.swift](/Users/yvan/developer/Thor/Thor/ShortcutMonitor.swift#L15), Thor registers one MASShortcut action per selected app; if the target bundle is already frontmost it calls `hide()`, otherwise it opens the app with `NSWorkspace.OpenConfiguration.activates = true`. There is no intermediate lifecycle state, no pid attachment, and no window-evidence gate. The lesson for Quickey is product clarity: the user should be able to explain the shortcut in one sentence.
- Thor's persistence model is equally flat. [AppsManager.swift](/Users/yvan/developer/Thor/Thor/AppsManager.swift#L56) simply unregisters all shortcuts, updates the selected-app list, writes JSON, and re-registers. [AppModel.swift](/Users/yvan/developer/Thor/Thor/AppModel.swift#L20) stores bundle URL, display name, and MASShortcut string only; there is no separate application/window/session layer. That confirms Thor is solving "shortcut to app" rather than "reliable lifecycle-aware visibility toggle."
- Thor also exposes one interesting product idea that Quickey should consider keeping conceptually separate from hidden safety throttles: a user-visible temporary shortcut disable flow. [AppDelegate.swift](/Users/yvan/developer/Thor/Thor/AppDelegate.swift#L90) listens for a chosen modifier key and temporarily unregisters all app shortcuts before re-enabling them on a timer. Quickey should not copy the exact UX by default, but the principle is useful: user-facing escape hatches are clearer than opaque internal suppression when shortcuts are getting in the way.
- Thor is therefore both inspiration and caution. Its semantics are excellent as a product contract, but its implementation is intentionally too small for Quickey's current reliability target because it does not model pid rollover, minimized windows, partially settled focus state, or diagnostic branch reasons. Quickey should copy Thor's semantic clarity, not its lack of lifecycle tracking.

### What skhd is worth copying, and what is not

- `skhd` is not an app switcher, but it is a mature macOS hotkey daemon with very explicit operational boundaries. Its README emphasizes responsiveness, live config reload, app-specific hotkeys, blacklist support, and clear daemon/log file behavior. See [skhd README](https://github.com/koekeishiya/skhd). Quickey should adopt the same clarity around capture ownership: one place to observe what keys are being seen, one place to understand whether capture is active, and one place to see why a binding did not fire.
- `skhd` also offers `--observe`, `--verbose`, and pid-file based service management. See [skhd README](https://github.com/koekeishiya/skhd). Quickey does not need a daemon CLI, but it should have the same philosophy: debugging shortcut capture must be easier than debugging downstream app activation.

### What Alfred is worth copying, and what is not

- Alfred's official Hotkey Trigger docs make hotkeys contextual by focused app, with explicit precedence rules for "only active when app has focus", "active when app does not have focus", and "global". See [Hotkey Trigger](https://www.alfredapp.com/help/workflows/triggers/hotkey/). Quickey should adopt the same mindset: when a shortcut has context-sensitive behavior, that behavior must be explicit and inspectable rather than hidden in incidental runtime state.
- Alfred's hotkey docs also call out speed tuning for modifier pass-through. See [Hotkey Trigger](https://www.alfredapp.com/help/workflows/triggers/hotkey/). Quickey does not need the same UI today, but this is a reminder that perceived shortcut reliability includes trigger latency, not just eventual correctness.
- Most importantly, Alfred's `Launch Apps & Files` action has an explicit `Toggle visibility for apps` option. See [Launch Apps & Files Action](https://www.alfredapp.com/help/workflows/actions/launch-apps-files/). That confirms Quickey's core semantics should be modeled as a dedicated visibility command, not treated as a side effect of generic launch/focus code.

### What Hammerspoon is worth copying, and what is not

- Hammerspoon exposes hotkey conflict and availability as first-class queries through `hs.hotkey.assignable`, `hs.hotkey.systemAssigned`, `hs.hotkey.getHotkeys`, and active/shadowed semantics. See [hs.hotkey](https://www.hammerspoon.org/docs/hs.hotkey.html). Quickey should not make users guess whether a shortcut is truly available or shadowed by the system.
- Hammerspoon's application API explicitly separates `launchOrFocus`, `hide`, `unhide`, `allWindows`, `visibleWindows`, `focusedWindow`, `mainWindow`, and `applicationForPID`. See [hs.application](https://www.hammerspoon.org/docs/hs.application.html). That is directly relevant to Quickey: process identity, application visibility, and window visibility are separate axes and should remain separate in our model.

### What AltTab is worth copying, and what is not

- AltTab keeps `Application` and `Window` as separate domain objects in [Application.swift](/tmp/alt-tab-macos/src/logic/Application.swift), including pid, hidden state, focused window, AX observer, and explicit `hideOrShow()` semantics. This is much closer to Quickey's problem space than Zed's editor model.
- AltTab subscribes to AX notifications for activated, main window changed, focused window changed, window created, hidden, and shown states. See [AccessibilityEvents.swift](/tmp/alt-tab-macos/src/logic/events/AccessibilityEvents.swift). Quickey currently samples state on demand; AltTab demonstrates the value of event-driven lifecycle updates for reducing ambiguity.
- AltTab also uses a dedicated AX scheduler with throttling, retry, unresponsive-pid tracking, and per-key serialized work in [AXCallScheduler.swift](/tmp/alt-tab-macos/src/logic/AXCallScheduler.swift). Quickey does not necessarily need all of that machinery, but it is a strong signal that mature macOS window-switching tools isolate Accessibility IPC timing from main business logic.

### Alternatives considered

1. Keep applying local patches to `hide_untracked`, `stableActivationState`, and launch edge cases.
   Reject. This is what we have effectively been doing, and the failure keeps moving because the underlying lifecycle ownership is still split.
2. Rewrite the whole toggle stack from scratch in one pass.
   Reject. Too risky while we still need stable Carbon / event-tap capture and existing tests to keep working.
3. Do a focused re-architecture of the toggle lifecycle while preserving the existing capture pipeline.
   Recommend this. It attacks the real fault line, keeps the platform-specific shortcut path intact, and is small enough to verify incrementally.
4. Keep the old state model alive behind compatibility fallbacks while layering a new session model on top.
   Reject. That would preserve the very split-brain ownership that caused the bug, add permanent mental overhead, and leave future failures harder to diagnose.

## Target Design

### Design Section 1: Single Source of Truth for Toggle Lifecycle

Quickey should have exactly one owner for per-target toggle lifecycle state. Replace the current "AppSwitcher local state + coordinator bundle session" split with a single pid-aware session record owned by `ToggleSessionCoordinator`, while `AppSwitcher` becomes the main-actor façade that observes state and invokes transitions. The recommended model is:

```swift
enum TogglePhase: String, Sendable {
    case launching
    case activating
    case activeStable
    case deactivating
    case degraded
    case idle
}

struct ToggleSession: Equatable, Sendable {
    let bundleIdentifier: String
    let attemptID: UUID
    var pid: pid_t?
    var phase: TogglePhase
    var activationPath: AppSwitcher.ActivationPath
    var previousBundleIdentifier: String?
    var startedAt: CFAbsoluteTime
    var confirmedAt: CFAbsoluteTime?
    var degradedReason: String?
}
```

The key design choice is that `launching` is a real phase, not a fire-and-forget branch. If Quickey launched the app, the next press must see that same in-flight session instead of falling through to `hide_untracked`.

This also aligns with Alfred's explicit `Toggle visibility for apps` option and AltTab's separate application/window objects: Quickey should model "visibility toggle" as a first-class command over an owned session, not as an accidental consequence of launch/focus branches.

### Design Section 2: Launch, Relaunch, and Termination Must Be Process-Aware

Bundle identifier is not enough. The logs already show Safari relaunching from one pid to another while the bundle-level memory lingers. Every activation path should attach pid as soon as it exists, and every termination should clear the matching session immediately.

Rules:

- `NOT RUNNING → launching` creates a `launching` session before calling `NSWorkspace.openApplication`.
- The `openApplication` completion or the next successful process lookup attaches the launched pid to the same session.
- `NSWorkspace.didTerminateApplicationNotification` clears any session for that bundle and pid, and emits a structured reset log.
- If the same bundle reappears under a different pid, Quickey treats it as a new process generation even if the bundle is unchanged.
- Hidden and minimized windows are explicit sub-states of an owned process, not incidental observation details. The session must record whether Quickey is trying to launch, unhide, or merely re-focus an existing visible process.

### Design Section 3: Repeated Shortcut Presses Need Explicit Pending Semantics

During `launching` or `activating`, a second shortcut press must not silently route into `hide_untracked` or generic `activate`. Quickey should branch explicitly:

- If the session is still pending and the current observation is not yet stable, log `BLOCKED activation_pending_not_stable` and keep confirming.
- If the session is pending and the current observation is already stable, promote to `activeStable` first, then evaluate toggle-off in the same turn.
- Only use `hide_untracked` for truly external activation: active, stable, no owned session, no pending session, no recently launched owned attempt.
- If the owned target is minimized or hidden, the session should prefer `unhide` / visibility restoration over pretending the target is already in the same state as a visible foreground app. This mirrors the kind of distinction Raycast publicly calls out in its hotkey behavior.
- If the target is frontmost but has no restored visible/focused/main window evidence, Quickey must not record "toggle on succeeded" for a regular user-facing app. That observation is either a `launching visibility recovery` case or a `degraded no visible window` case, not `activeStable`. This is the concrete protection against the Safari false-positive windowless success seen in [`debug.log:18008`](/Users/yvan/.config/Quickey/debug.log:18008) through [`debug.log:18013`](/Users/yvan/.config/Quickey/debug.log:18013).

### Design Section 3A: Explicit No-Window Success Policy

The current plan must not leave "true windowless utility" as an implementation-time judgment call.

Rules:

- Only non-regular targets may succeed without window evidence. Concretely: if `activationPolicy != .regular`, the target may be considered stable once it is frontmost, active, and not hidden.
- Any `.regular` app must present usable window evidence before becoming `activeStable`. Usable evidence means:
  - `visibleWindowCount > 0`, or
  - `hasFocusedWindow == true`, or
  - `hasMainWindow == true`
- A `.regular` app with zero visible/focused/main window evidence is never a silent success. It must remain `activating`, move into an explicit visibility-recovery path, or become `degraded`.
- Accessibility read failure for a `.regular` app is not permission to succeed without evidence. It should be represented as `degraded` or `pending`, with the failure reason preserved in diagnostics.
- Do not add heuristic allowlists, bundle-specific exceptions, or "seems accessory-like" guesses in this cycle. If a real app needs a special rule later, it must come from new logs and a dedicated design update.

### Design Section 4: Diagnostics Must Explain the Branch, Not Just the Outcome

Current logs are structured, but they do not reliably connect one toggle attempt across launch, confirmation, invalidation, and hide. Add a new structured trace family that includes:

- `attemptId`
- `bundle`
- `pid`
- `phase`
- `event`
- `activationPath`
- `reason`
- `previousBundle`

Recommended event families:

- `TOGGLE_TRACE_DECISION`
- `TOGGLE_TRACE_SESSION`
- `TOGGLE_TRACE_RESET`
- `TOGGLE_TRACE_CONFIRMATION`

This is the Quickey equivalent of Zed's "Key Context View" principle: when a shortcut misbehaves, we should be able to answer "what branch did Quickey take, and why?" from one trace window.

The practical target should be closer to Hammerspoon's explicit hotkey visibility and Alfred's contextual hotkey clarity: a user or maintainer should be able to tell whether a failure was caused by shortcut capture, system conflict, owned pending session state, external activation, or window visibility state.

### Design Section 5: Reliability Constraints To Avoid New Debt

This work should explicitly optimize for correctness and maintainability over short-term compatibility shims.

Rules:

- Do not keep two independent lifecycle owners once the new model lands. `ToggleSessionCoordinator` is the canonical owner; AppSwitcher-local lifecycle state must be deleted or reduced to derived read-only views. No permanent dual-write bridge.
- Do not add catch-all fallback branches such as "if activation looks weird, mark stable anyway" for regular user-facing apps. Unknown or incomplete state should stay visible as `pending` or `degraded` until it is explained, not be silently coerced into success.
- Keep `ACTIVE_UNTRACKED` only because it is a proven external-ownership case already documented in [AGENTS.md](/Users/yvan/developer/Quickey/AGENTS.md#L62). Do not invent additional fallback lanes unless logs demonstrate a distinct ownership model that cannot be represented by the primary state machine.
- Every newly introduced branch must have one corresponding test and one corresponding diagnostic reason string. If a branch cannot be named, logged, and tested, it should not exist.
- When the new path supersedes an old branch, delete the old branch in the same implementation cycle instead of leaving a dormant compatibility path behind.

### Design Section 6: Performance And Best-Practice Guardrails

This redesign must preserve Quickey's existing hot-path discipline and only spend more work after a shortcut has already been matched.

Rules:

- Do not add new work to the raw key-capture hot path beyond what is already necessary for matching and dispatch. `ShortcutManager` should still do O(1) trigger lookup before any activation/window logic begins.
- Do not move Accessibility window observation into the general key-event path. AX calls should remain scoped to the matched target app and the confirmation/degradation pipeline for that one target.
- Do not add new global polling loops or background retry timers for lifecycle recovery. Use bounded, per-session confirmation with explicit retry caps and expiry, consistent with existing coordinator discipline.
- Keep all new retry behavior bounded by existing concepts such as absolute ceilings, idle expiry, and retry caps. No unbounded reconfirm loops, no "keep trying until it works" behavior.
- Keep platform-specific state reads on the main actor only where the Apple API semantics require it. Do not spread `@MainActor` to unrelated runtime logic just to make the implementation easier.
- Diagnostics must stay cheap enough that they do not materially change hotkey responsiveness. Detailed trace logs should be emitted only for matched shortcuts, accepted lifecycle transitions, and explicit blocking/failure reasons, not for every unrelated key event.
- Prefer event-driven state transitions over additional sampling when a trustworthy system notification already exists. If observation still needs sampling, keep the sampling window narrow and tied to a live owned session.
- Any new abstraction introduced for clarity must also reduce or at least not increase runtime coupling. Do not add a new indirection layer that leaves the number of state transitions or AX round-trips unchanged while making the code harder to reason about.

## File Map

**Create:**

- `Tests/QuickeyTests/ToggleLaunchLifecycleTests.swift`
  Purpose: isolated regression tests for launch → relaunch → second-press behavior.

**Modify:**

- `Sources/Quickey/Services/AppSwitcher.swift`
  Purpose: remove split local lifecycle state, route launch/activate/hide through coordinator-owned session transitions, add structured branch logs, and delete superseded fallback branches in the same pass.
- `Sources/Quickey/Services/ToggleSessionCoordinator.swift`
  Purpose: become the single session owner with pid-aware phases and transition helpers, while preserving bounded retry/expiry semantics and durable `previousBundle` ownership.
- `Sources/Quickey/Services/ApplicationObservation.swift`
  Purpose: keep observation purely observational and expose enough data for session transitions, not ownership, while stopping regular user-facing apps from treating `frontmost + no restored window` as a successful toggle-on state.
- `Sources/Quickey/Services/ShortcutManager.swift`
  Purpose: if diagnostics are added here, keep them on the accepted-trigger boundary rather than regressing the raw capture/match hot path.
- `Tests/QuickeyTests/AppSwitcherTests.swift`
  Purpose: preserve existing lifecycle assertions while moving them to the new session semantics.
- `Tests/QuickeyTests/ApplicationObservationTests.swift`
  Purpose: lock the no-window success policy so `.regular` apps cannot silently pass while non-regular utilities still can.
- `Tests/QuickeyTests/ToggleSessionCoordinatorTests.swift`
  Purpose: preserve coordinator invariants while session ownership becomes single-source and pid-aware.
- `Tests/QuickeyTests/ShortcutManagerStatusTests.swift`
  Purpose: protect shortcut-capture readiness and accepted-trigger semantics while diagnostics and lifecycle ownership change around them.
- `docs/architecture.md`
  Purpose: update the runtime ownership model so docs match the coordinator-owned single-source toggle lifecycle design.
- `docs/README.md`
  Purpose: keep maintainer navigation aligned with any renamed lifecycle concepts or validation flow.
- `docs/handoff-notes.md`
  Purpose: record the exact failure signatures and the new validation checklist.
- `docs/lessons-learned.md`
  Purpose: document the anti-pattern we hit: bundle-only tracking across process lifetimes.

**Optional, if diagnostics stay too opaque after Task 2:**

- `Sources/Quickey/Services/ToggleDiagnosticEvent.swift`
  Purpose: centralize structured trace formatting instead of continuing to build ad hoc log strings inside `AppSwitcher`.
- `scripts/toggle-trace-summary.sh`
  Purpose: grep-friendly summarizer for one attempt window in `~/.config/Quickey/debug.log`.

## Task Plan

### Task 1: Freeze the Current Failure Model in Tests

**Files:**
- Create: `Tests/QuickeyTests/ToggleLaunchLifecycleTests.swift`
- Modify: `Tests/QuickeyTests/AppSwitcherTests.swift`
- Modify: `Tests/QuickeyTests/ApplicationObservationTests.swift`
- Modify: `Tests/QuickeyTests/ToggleSessionCoordinatorTests.swift`
- Modify: `Tests/QuickeyTests/ShortcutManagerStatusTests.swift` only if accepted-trigger or diagnostics boundaries need explicit protection

- [ ] Add a failing regression test for "app terminated, relaunched, second press must not go through stale owned state".
- [ ] Add a failing regression test for "launch path creates owned pending lifecycle state instead of returning fire-and-forget".
- [ ] Add a failing regression test for "second press during owned launch cannot route to `hide_untracked`".
- [ ] Add a failing regression test for "hidden/minimized owned app routes through explicit visibility recovery lane instead of generic activate".
- [ ] Add a failing regression test for "frontmost regular app with no visible/focused/main window cannot be promoted to stable toggle-on success".
- [ ] Add or adjust coordinator regression coverage so expiry / retry / previousBundle semantics remain explicit under the new single-source model.
- [ ] Add or adjust `ShortcutManager` coverage if needed to prove matched-trigger acceptance semantics stay unchanged and diagnostics do not leak into unrelated key events.
- [ ] Run:
  - `swift test --filter ApplicationObservationTests`
  - `swift test --filter AppSwitcherTests`
  - `swift test --filter ToggleSessionCoordinatorTests`
  - `swift test --filter ShortcutManagerStatusTests`
  - `swift test --filter ToggleLaunchLifecycleTests`
- [ ] Expected before implementation: failures that mention stale session state, missing launch tracking, or `.regular` apps being promoted to stable without window evidence.

### Task 2: Make Lifecycle Ownership Single-Source and pid-Aware

**Files:**
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Modify: `Sources/Quickey/Services/ToggleSessionCoordinator.swift`

- [ ] Introduce one canonical `ToggleSession` model with explicit `launching`, `activating`, `activeStable`, `deactivating`, `degraded`, and `idle` phases.
- [ ] Move canonical lifecycle ownership into `ToggleSessionCoordinator` and reduce AppSwitcher-local lifecycle storage to derived views or remove it entirely.
- [ ] Delete or demote superseded AppSwitcher-local lifecycle storage in the same task rather than keeping an adapter layer that writes both old and new models.
- [ ] Add pid attachment/update rules so the same bundle under a new pid is treated as a new process generation.
- [ ] Route termination and reset handling through the single owner, not two loosely synchronized owners.
- [ ] Preserve bounded expiry and retry semantics already covered by `ToggleSessionCoordinatorTests`; do not replace them with open-ended polling.
- [ ] Run:
  - `swift test --filter AppSwitcherTests`
  - `swift test --filter ToggleSessionCoordinatorTests`
  - `swift test --filter ToggleLaunchLifecycleTests`
- [ ] Expected after implementation: termination and relaunch tests pass without weakening existing toggle/coordinator tests.

### Task 3: Rebuild the Launch Path as a Real Pending Activation

**Files:**
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Modify: `Sources/Quickey/Services/ApplicationObservation.swift`

- [ ] Replace the current `NOT RUNNING → launching` fire-and-forget branch with owned `launching` session creation.
- [ ] Attach launch completion to the same confirmation path used by activate/unhide, so launch and activate share one stabilization pipeline.
- [ ] Split owned visibility recovery into explicit lanes: `launch`, `unhide`, and `focus-visible`, instead of treating them as one generic activation path.
- [ ] Tighten stabilization rules so regular apps do not report success until there is usable window evidence; do not add a permissive "best effort success" fallback for incomplete observations.
- [ ] Preserve success for non-regular/system-utility targets only when `activationPolicy != .regular` explicitly justifies it; do not introduce bundle-specific exceptions.
- [ ] Keep AX observation scoped to the target app for the active session only; do not introduce any extra pre-match observation or global sampling loop.
- [ ] On second press for the same bundle:
  - if stable now, promote and evaluate toggle-off in the same turn
  - if not stable yet, block with explicit reason and continue confirming
- [ ] Keep `hide_untracked` only for truly external frontmost ownership, never for our own just-launched target.
- [ ] Run:
  - `swift test --filter ApplicationObservationTests`
  - `swift test --filter AppSwitcherTests`
  - `swift test --filter ToggleLaunchLifecycleTests`
- [ ] Expected after implementation: no test depends on `hide_untracked` immediately after an owned launch, and no regular app can become "stable" through a no-window fallback.

### Task 4: Upgrade Diagnostics from Outcome Logs to Transition Logs

**Files:**
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Modify: `Sources/Quickey/Services/ShortcutManager.swift`
- Optional Create: `Sources/Quickey/Services/ToggleDiagnosticEvent.swift`
- Optional Create: `scripts/toggle-trace-summary.sh`

- [ ] Add attempt/session identifiers to every launch/activate/hide transition line.
- [ ] Emit explicit branch reasons for:
  - stale state invalidation
  - launch-pending blocking
  - frontmost-without-window false-positive prevention
  - external untracked hide
  - partial hide degradation
  - pid rollover / termination reset
- [ ] Emit companion shortcut-capture diagnostics when a hotkey is blocked by cooldown, missing registration, or system conflict, so toggle failures and capture failures stop looking the same in the log stream.
- [ ] Keep existing `TOGGLE_*` outcome lines for continuity, but add `TOGGLE_TRACE_*` lines that explain branch choice.
- [ ] Do not use diagnostics as a substitute for fallback behavior. Logs should explain the chosen primary branch, not hide an ambiguous best-effort rescue path.
- [ ] Keep diagnostics off the raw key path for unrelated events; emit detailed trace lines only after a shortcut is matched or explicitly blocked.
- [ ] If the inline log strings become too dense, extract a small formatter type rather than growing `AppSwitcher.swift` further.
- [ ] Run:
  - `swift test --filter AppSwitcherTests`
  - `swift test --filter ShortcutManagerStatusTests`
- [ ] Manual spot-check: grep one attempt window in `~/.config/Quickey/debug.log` and confirm it is traceable end-to-end by `attemptId`.

### Task 5: Validate the Real Failure Matrix on macOS

**Files:**
- Modify: `docs/handoff-notes.md`
- Modify: `docs/lessons-learned.md`

- [ ] Validate fresh-launch path:
  - target app not running
  - shortcut launches it
  - second press hides it without `hide_untracked` or `phase=no_session`
- [ ] Validate relaunch path:
  - target app becomes stable
  - target app quits
  - shortcut relaunches it
  - second press still hides cleanly
- [ ] Validate external activation path:
  - user activates target outside Quickey
  - Quickey still handles it via explicit `hide_untracked` only when unowned
- [ ] Validate frontmost/no-window path:
  - target app becomes frontmost without restoring a usable window
  - Quickey records the case as visibility recovery or degraded, not stable success
- [ ] Run:
  - `swift test`
  - `bash scripts/package-app.sh`
  - `codesign --verify --deep --strict --verbose=2 build/Quickey.app`
- [ ] Record the exact log signatures that count as success and failure in the handoff docs.
- [ ] During macOS validation, confirm no perceptible hotkey-latency regression when repeatedly triggering a matched shortcut under normal use.
- [ ] Update:
  - `docs/architecture.md`
  - `docs/README.md`
  - `docs/handoff-notes.md`
  - `docs/lessons-learned.md`

## Risks and Non-Goals

- Do not rewrite the Carbon hotkey or Hyper event-tap capture path as part of this work.
- Do not add a full graphical debug UI in this cycle unless the improved trace logs still leave failures ambiguous.
- Do not treat Zed as a feature-by-feature template. Its reference value is architecture and observability discipline, not app-toggle semantics.
- Do not leave a compatibility shim that preserves both the old and new lifecycle models after rollout.
- Do not add "best effort" stabilization fallbacks for regular apps that are only justified by making the symptom disappear in one log sample.
- Do not add bundle-specific allowlists or special cases to rescue ambiguous no-window observations.
- Do not regress the existing O(1) trigger lookup path or add new global polling in the name of reliability.

## Success Criteria

- No owned launch/relaunch path can fall through to `phase=no_session` on the next press.
- No second press immediately after an owned launch can route to `hide_untracked`.
- `hide_untracked` remains available only for truly external activation.
- Hidden or minimized owned targets recover through an explicit visibility lane instead of relying on accidental `activate`/`hide` behavior.
- No regular app can be marked toggle-on successful solely because it became frontmost while still lacking usable window evidence.
- Shortcut matching remains O(1) pre-dispatch, with no new AX work or detailed logging on unrelated key events.
- Shortcut capture failures, system-reserved conflicts, and toggle-lifecycle failures are distinguishable in logs without additional instrumentation.
- One failed attempt window in `debug.log` is enough to identify branch, pid, phase, and reset reason.
- Full `swift test` remains green before any macOS runtime signoff.
