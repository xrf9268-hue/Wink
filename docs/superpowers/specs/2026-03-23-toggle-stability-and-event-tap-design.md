# Toggle Stability and Event Tap Reliability Design

> Partially superseded for toggle-off: the restore-first / hide-fallback portions of this design were replaced on 2026-04-08 by a direct-hide-only toggle-off path. The activation stability and event-tap reliability parts remain historical background, but should not be used to reintroduce restore-first toggle-off logic.

**Date:** 2026-03-23
**Branch:** main
**Status:** Draft
**Scope:** Redesign Quickey's app toggle stability checks, special-case handling for system or window-weird apps, and event tap recovery/diagnostic strategy

## Overview

Quickey's current app switching behavior is intentionally simple: activate the target app on first trigger, then restore the previous app and hide the target as a fallback on the second trigger. That model works for many normal apps, but recent macOS validation on 2026-03-23 exposed a reliability gap for system apps such as Home.

The observed failure mode is not a crash. It is worse from a UX perspective: Quickey can leave the target app in a half-activated state where a window is visible, but the system frontmost app is still something else, or a second trigger tries to toggle off before the first activation has become stable. In practice this produces behavior like:

- the target app appears in front visually but is not the actual active app
- the same shortcut alternates between "activate" and "toggle off" too aggressively
- clicking the visible target window can make it disappear because the app is still in a transient show/hide state

At the same time, the event tap path is stable enough to avoid the historical crash paths, but it still needs a clearer lifecycle and better escalation when macOS disables the tap for timeout.

This design keeps Quickey's product model as an app-level toggle utility, but makes the runtime semantics stricter and more observable:

- activation is not considered complete until it reaches a stable frontmost state
- toggle-off is only allowed from that stable state
- system apps and window-weird apps get explicit downgrade rules instead of falling through generic logic
- repeated event tap timeouts move through a documented recovery ladder with actionable logs

## Goals

- Preserve Quickey's app-level toggle product behavior instead of turning it into a full window switcher
- Eliminate "half-active" states from counting as a successful activation
- Prevent rapid repeat triggers from flipping between activate and restore based on stale or contradictory state
- Make toggle decisions depend on state that matches user-visible reality
- Improve diagnostics so future runtime failures can be localized from logs without reproducing in LLDB
- Define an event tap recovery strategy that is lightweight on the hot path but escalates when timeout churn persists

## Non-Goals

- Replacing Quickey with a window-first AltTab-style product
- Removing the SkyLight activation path
- Adding a full persistence layer for per-window focus history
- Solving every exotic app activation edge case in one pass
- Introducing synchronous file logging or other heavy work into the event tap callback

## Current Evidence

The strongest evidence comes from the newly added post-action logs in `~/.config/Quickey/debug.log`.

Representative entries from 2026-03-23:

- `2026-03-23T08:29:13Z TOGGLE[Home]: POST_ACTIVATE_STATE postFrontmost=com.apple.systempreferences, targetBundle=com.apple.Home, targetFrontmost=false, targetHidden=true, targetVisibleWindows=true`
- `2026-03-23T08:29:28Z TOGGLE[Home]: POST_RESTORE_STATE postFrontmost=com.apple.systempreferences, targetBundle=com.apple.Home, targetFrontmost=true, targetHidden=false, targetVisibleWindows=true`

These lines show two important contradictions:

1. Quickey can visually surface a target app with visible windows while the system frontmost app remains another bundle.
2. `NSRunningApplication.isActive` can disagree with `NSWorkspace.shared.frontmostApplication`, which means `isActive` alone is not a safe gate for toggle-off behavior.

The event tap logs from prior runs also showed repeated:

- `EVENT TAP DISABLED by system (reason: 4294967294)`

Apple's current documentation identifies that event type as `tapDisabledByTimeout`, which means macOS disabled the tap because the callback path took too long or was otherwise judged unhealthy.

## Current Context

- `AppSwitcher` currently uses `runningApp.isActive` as the primary toggle-off gate.
- `FrontmostApplicationTracker` stores a single `lastNonTargetBundleIdentifier`.
- `FrontmostApplicationTracker.restorePreviousAppIfPossible()` currently clears `lastNonTargetBundleIdentifier` before restore success is confirmed, which is incompatible with a design that wants post-restore confirmation and retry safety.
- Post-action logging now records `postFrontmost`, `targetFrontmost`, `targetHidden`, and `targetVisibleWindows`.
- `TogglePostActionState` is the current diagnostics bridge for post-action state; the redesign needs an explicit migration path instead of silently replacing it.
- `EventTapManager` already avoids synchronous file I/O in the callback and already records a useful timeout snapshot asynchronously.
- `EventTapManager` currently re-enables the tap in place when disabled by timeout or user input.

The current architecture intentionally favors app-level semantics:

- activate target app
- restore previous app when toggling away
- hide target app as a fallback

That model stays in place. The redesign is about making it truthful and stable.

## Official API Semantics That Matter

Apple's current documentation and system behavior imply the following:

- `NSRunningApplication.activate(options:)` only attempts activation; it is not a guarantee of a stable interactive result.
- `NSWorkspace.frontmostApplication` returns the app that receives key events.
- `NSRunningApplication.isActive` indicates whether the app is currently frontmost, but our observed logs show it can briefly disagree with `frontmostApplication` during transition-heavy system app behavior.
- `NSRunningApplication.hide()` attempts to hide the target app, which is the relevant app-level hide operation in Quickey's runtime path.
- `NSWorkspace.openApplication(at:configuration:completionHandler:)` calls its completion handler asynchronously on a concurrent queue.
- `CGEvent.tapCreate(...)` invokes the callback on the run loop to which the tap source is attached.
- `CGEventType.tapDisabledByTimeout` explicitly means the event tap was disabled because of timeout.

These semantics lead to two design constraints:

1. A single activation API return value cannot be treated as the final truth for toggle state.
2. Event tap diagnostics must remain callback-safe and run-loop-aware.

## External Reference Implementations

### AltTab

AltTab is primarily window-first. Its switching logic focuses a specific window using a layered approach:

- bring the process forward
- make the window key
- raise the window

This is the right design for a window switcher, but Quickey is not trying to become one. The lesson for Quickey is narrower:

- visual presence is not enough
- "window became key" and "app became frontmost" are different truths
- system apps and Space-related transitions are explicitly buggy enough that AltTab carries extra recovery logic

### Hammerspoon

Hammerspoon exposes separate app-level and window-level concepts:

- app activation
- frontmost checks
- main/focused window inspection
- explicit hide/unhide primitives

Its `hs.application.open(..., waitForFirstWindow)` API is especially instructive because it models "app launched" and "first usable window exists" as different checkpoints. That same distinction is what Quickey currently lacks.

### Practical takeaway

Mature tools do not treat "requested activation" as equivalent to "toggle target is ready". They either:

- focus a concrete window, or
- gate app-level behavior behind additional confirmation such as "wait until the first usable window exists"

Quickey should adopt the second approach.

## Approaches Considered

### 1. Minimal fix: keep app-level toggle and switch the gate from `isActive` to `frontmostApplication`

Pros:

- Smallest change
- Directly addresses the most obvious mismatch

Cons:

- Still treats one snapshot as sufficient
- Does not handle transient activation states or window-weird system apps
- Does not define what "stable enough to toggle off" means

### 2. Stable-state app toggle

Pros:

- Preserves Quickey's product semantics
- Separates activation request from activation success
- Provides a clean place to integrate app-type exceptions and retry behavior
- Gives logs and tests a more explicit state model

Cons:

- More moving parts than the minimal fix
- Requires new internal state and clearer phase boundaries

### 3. Window-first redesign

Pros:

- Most precise model for interactive focus
- Best alignment with AltTab-style reliability patterns

Cons:

- Changes the product
- Requires heavier architectural work than this problem needs

## Recommendation

Use approach 2: keep Quickey as an app-level toggle tool, but move the runtime behavior to a stable-state model.

This gives us the smallest change that can still produce mature behavior. The key shift is:

> "Activation requested" is no longer enough to count as "target is active and the next trigger should toggle it off."

## Approved Product Decisions

| Topic | Decision |
|------|----------|
| Product model | Keep app-level toggle semantics |
| Toggle-off gate | Only allow toggle-off from a stable active state |
| Primary truth source | Treat `NSWorkspace.frontmostApplication` as the main user-visible truth for app-level toggle decisions |
| Role of `isActive` | Keep as supporting signal and diagnostic field, not the sole authority |
| Window signals | Use focused/main/visible-window signals to confirm stability for regular windowed apps |
| System/window-weird apps | Handle with explicit degraded-success rules instead of pretending generic activation always worked |
| Previous app memory | Keep current single previous-app model for now; do not add a multi-entry history stack in this pass |
| Event tap timeout handling | Keep callback-light re-enable behavior, but add lifecycle tiers and escalation after repeated timeouts |

## Delivery Strategy

The reviewer concern about implementation jump is valid: the current `AppSwitcher.toggleApplication(for:)` path is still a compact synchronous method, while the full target design introduces explicit runtime phases and delayed confirmation. This should land in controlled stages.

### Phase 1: Observation-first hardening

- Introduce a reusable activation observation snapshot that records:
  - `frontmostApplication`
  - target `isActive`
  - target `isHidden`
  - visible-window evidence
  - focused/main-window evidence when available
- Keep the current public synchronous entry point
- Keep existing behavior mostly intact, but stop using `isActive` as the only truth source
- Expand logging into structured `key=value` records so every later phase has better evidence

### Phase 2: Stable confirmation without full session coordinator

- Add delayed confirmation with a bounded confirmation window
- Add a lightweight pending/stable concept around the current toggle path
- Prevent second-trigger toggle-off while the target is still pending confirmation
- Keep storage local and minimal so behavior can be validated before introducing a broader coordinator
- In this phase, the practical state model should stay intentionally small:
  - `idle`
  - `activating`
  - `activeStable`

### Phase 3: Full session coordination and degraded-state handling

- Introduce `ToggleSessionCoordinator`
- Add per-target runtime session state
- Add degraded-success rules and explicit expiry behavior
- Add event tap escalation thresholds and recreation ladder
- In this phase, the full target state model becomes available:
  - `idle`
  - `activating`
  - `activeStable`
  - `deactivating`
  - `degraded`

Each phase must be independently testable and independently reversible. This is not just implementation caution; it is part of the design intended to keep the runtime reliable during rollout.

## Design

### 1. Introduce a Toggle Session State Machine

Quickey should track a small in-memory toggle session per target bundle identifier.

Recommended states:

- `idle`
- `activating(previousBundle, startedAt, activationAttempt, recoveryStage)`
- `activeStable(previousBundle, confirmedAt, stabilityEvidence)`
- `deactivating(previousBundle, startedAt)`
- `degraded(previousBundle, reason, observedAt)`

This does not need to be persisted. It is runtime-only coordination.

#### Why per-target session state is needed

Right now Quickey decides each shortcut press only from instantaneous app state. That is the direct cause of flapping:

- press 1 starts activation
- system state is still transitioning
- press 2 lands before activation stabilizes
- Quickey mistakes the target for "already active" or toggles based on contradictory signals

With a session state machine:

- repeated presses during `activating` can re-confirm or re-attempt activation instead of toggling off
- repeated presses during `activeStable` can perform true toggle-off
- degraded states can be logged and handled intentionally

#### Session ownership and lifecycle

Session state should be keyed by target bundle identifier, not by shortcut UUID. Multiple shortcuts targeting the same app should share one runtime session because the user-visible object is the app, not the binding row.

Sessions should be:

- created lazily on first trigger for a bundle
- cleared on successful toggle-off
- cleared when the target app terminates
- cleared when no configured shortcuts still reference that bundle
- expired after a bounded idle period so stale degraded or pending state cannot accumulate indefinitely

Recommended initial expiry values:

- `activating` and `degraded` expire after 2 seconds of no reinforcing trigger or successful confirmation
- `activeStable` expires after 5 minutes of inactivity or immediately if the target is no longer frontmost

Recommended initial absolute ceilings:

- no activation session should stay pending longer than 5 seconds from its first accepted trigger
- no degraded retry loop should continue past 2 re-confirm attempts within the same activation session

If either ceiling is reached, the session should fall back to `idle` instead of retrying indefinitely.

Because Quickey typically has a small configured shortcut set, memory pressure is not expected to be meaningful here. The implementation should still cap sessions to the active configured target bundles and avoid unbounded growth.

Recommended initial cap:

- at most `50` live bundle-keyed sessions at once

If the cap would be exceeded, the implementation should evict the stalest `idle` session first, then the stalest expired non-idle session.

### 2. Define Stable Active State Explicitly

`activeStable` should require a short confirmation step, not just a single boolean read.

#### Primary app-level truth

Use `NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetBundleIdentifier` as the primary condition because Apple defines the frontmost app as the one receiving key events.

#### Supporting stability evidence for regular windowed apps

For apps with normal windows, stability should require:

- target bundle is frontmost
- target is not hidden
- at least one of:
  - AX focused window belongs to the target app
  - AX main window belongs to the target app
  - a visible non-minimized target window exists and the frontmost match survives a short confirmation delay

#### Short confirmation delay

After activation attempt succeeds, Quickey should perform a delayed confirmation pass after a small interval such as 50-150 ms. The goal is not animation delay. The goal is to let AppKit, SkyLight, AX, and odd system apps settle before we declare success.

If the target is still frontmost after that delay and the supporting evidence matches, transition to `activeStable`.

If not, remain in `activating` and run the next recovery step or record a degraded result.

#### Timing semantics relative to debounce

This redesign must coexist cleanly with the current `EventTapManager` debounce window, which is 200 ms for repeated identical shortcuts.

The intended interaction is:

- confirmation delay should start below the debounce interval
- the initial recommended confirmation delay is 75 ms
- a second confirmation pass may be scheduled, but the total confirmation budget for an already-running app should stay under 300 ms before resolving to `activeStable` or `degraded`
- Space-switching activations are a known exception; if the app-level frontmost transition depends on Mission Control space movement and does not stabilize within the nominal 300 ms budget, the session should degrade instead of forcing rollback, and validation should treat this as a known slow-path exception rather than a budget regression by default

Behavioral rules:

- a repeated trigger suppressed by event-tap debounce behaves exactly as it does today: no new toggle decision is made
- a repeated trigger that arrives after debounce but while the session is still `activating` should be interpreted as "continue or re-confirm activation", not "toggle off"
- if the user changes apps externally during confirmation, the pending confirmation must be invalidated via a monotonic confirmation generation counter so stale results cannot promote the wrong state

#### Visual feedback and rollback policy

The frontmost-switch request should be issued immediately. Confirmation exists to decide state promotion, not to delay the visible app switch behind a timer.

Product rule:

- confirmation should not block the initial bring-to-front attempt
- confirmation failure should not proactively restore the previous app just to "undo" a non-stable activation
- if confirmation cannot establish `activeStable`, Quickey should mark the session pending, degraded, or idle according to the session rules and wait for explicit user input rather than causing a flicker-inducing visual rollback

This keeps the keyboard interaction feeling immediate even when the state model is still deciding whether the activation became trustworthy enough for later toggle-off.

#### Public method semantics

The design keeps `toggleApplication(for:) -> Bool` synchronous in the first rollout stages to avoid widening the change surface through `ShortcutManager`, usage tracking, and test seams all at once.

In this design, the synchronous return value should continue to mean:

> Quickey accepted the trigger and initiated a switch attempt.

It should not be interpreted as:

> The target is definitely already in `activeStable`.

Stable/degraded promotion can occur after the method returns. If later validation shows that downstream callers need richer semantics than a boolean, the implementation plan can introduce an internal result enum or callback path while preserving the external behavior during migration.

### 3. Distinguish App Classes

Quickey should stop pretending every app behaves like a normal document app.

Recommended coarse classes:

- `regularWindowed`
- `nonStandardWindowed`
- `windowlessOrAccessory`
- `systemUtility`

This classification does not need a giant hard-coded app database on day one. It can start with heuristics plus a tiny explicit exception list for known bad actors.

Classification should be re-evaluated on each toggle attempt from the current runtime evidence gathered for that toggle. The design intentionally avoids a long-lived global classification cache because app window behavior can change while the app is running.

#### Heuristics

- activation policy
- whether AX windows exist
- whether focused/main window can be resolved
- whether the app frequently reports visible windows while never becoming the key-event receiver
- whether the app should skip focused/main-window checks because it is accessory-like, windowless, or already known to be nonstandard

Classification results should be logged with their observed reasons so later bug reports can distinguish "the app was misclassified" from "the app changed runtime behavior on a new macOS release."

#### Initial explicit exceptions

The current evidence justifies starting with a small exception bucket for apps like:

- `com.apple.Home`
- other system utilities that routinely expose nonstandard window or scene behavior during toggling

The exception policy is not "special-case forever". It is "be honest about apps that already disprove the generic path."

### 4. Activation Flow

When the user triggers a shortcut for a running, non-frontmost target:

1. Record the current previous app if the target is not already frontmost.
2. Enter `activating`.
3. Unhide the target if needed.
4. Recover minimized windows if relevant.
5. Attempt activation through the existing layered path:
   - SkyLight foreground request
   - key-window request if a window ID exists
   - AX raise
6. Run a delayed confirmation pass.
7. If stable, transition to `activeStable`.
8. If not stable:
   - if no usable windows exist, run window recovery
   - if the app is in an exception class, apply its degraded-success policy
   - otherwise remain degraded and log the failure reason

`unhide` and "recover minimized windows" are intentionally separate steps. Unhiding an app does not guarantee that minimized windows are restored to a usable state, so the design keeps `unhide -> unminimize/recover` ordering explicit.

#### Confirmation versus recovery-stage timing

The existing code already contains an asynchronous recovery chain for windowless or non-visible-window situations. The redesign must not layer a blind confirmation timer on top of that chain.

Required rule:

- confirmation for a given recovery stage runs after that stage's effect window, not in parallel with an unfinished recovery stage

Practical sequencing:

- initial activation attempt -> confirmation pass
- if recovery stage 1 is needed, schedule that recovery stage, then run the next confirmation after its expected settling delay
- if recovery stage 2 is needed, do the same again

The recovery chain and the confirmation chain therefore interleave stage-by-stage rather than race each other.

For the not-running launch path, Quickey should preserve today's previous-app capture behavior before launching. The user expectation is still Thor-like: if launch succeeds and later becomes stable, the next trigger should be able to restore away from that app.

### 5. Toggle-Off Flow

Toggle-off should only be reachable from `activeStable`.

When the same shortcut fires from `activeStable`:

1. Enter `deactivating`.
2. Attempt to restore the previous app.
3. Confirm whether the previous app actually became frontmost.
4. If the target still has visible windows or contradictory active state after restore, explicitly hide it.
5. Confirm the target is no longer frontmost.
6. Clear or downgrade the session state.

This flow fixes a current weakness: Quickey logs `restored=true` or `hidden=true/false`, but it does not currently model whether the post-restore state is actually coherent enough to count as a completed toggle-off.

#### Previous-app ownership during restore confirmation

The current `FrontmostApplicationTracker` clears previous-app memory too early for this design. During rollout, Quickey needs one of these two explicit strategies:

- delay clearing `lastNonTargetBundleIdentifier` until restore success is confirmed, or
- store `previousBundle` in the session/coordinator and treat that session-owned value as the source of truth during `activating`, `activeStable`, and `deactivating`

For the stable-state design, session-owned `previousBundle` is the more reliable model because it stays attached to the toggle attempt even if the tracker implementation remains lightweight during the migration.

### 6. Degraded Success Rules

Some activations should not count as full success, but they also should not be treated as total failure.

Examples:

- target became frontmost but no focused window could be verified yet
- target is a system utility with visible content but unstable AX key-window reporting
- target re-opened successfully but did not stabilize before the deadline

These cases should transition to `degraded`, not `activeStable`.

Behavior in `degraded`:

- the next shortcut should prefer another activation confirmation pass, not toggle-off
- the UI behavior remains "best effort bring forward"
- logs must explain why the state is degraded
- degraded state should automatically expire back to `idle` if the target never stabilizes within the bounded expiry window
- if the target loses frontmost status before stabilizing, the session should drop out of `degraded` instead of staying sticky
- degraded re-confirm attempts should be capped at 2 within one activation session
- if the degraded retry cap or the 5-second absolute activation ceiling is hit, the session should give up and return to `idle`

Degraded is a runtime honesty mechanism, not a permanent limbo state.

#### Expiry and retry interaction

The degraded idle-expiry timer, degraded retry cap, and 5-second absolute activation ceiling must not fight each other.

Rules:

- user-triggered re-confirmation may reset the short degraded idle-expiry timer
- user-triggered re-confirmation must not reset the 5-second absolute activation ceiling
- user-triggered re-confirmation must increment against the same activation session's retry cap until that session returns to `idle`

This keeps degraded usable for short re-attempts without accidentally turning it into an endless loop.

#### User experience rule for repeated triggers

The user-visible rule should stay simple:

- first press tries to bring the app forward
- second press only toggles away if Quickey has already confirmed a stable active state
- if the app is still degraded or pending, another press keeps trying to complete activation rather than immediately hiding or restoring away
- if the retry cap or absolute activation ceiling has already been reached, the next press starts a fresh activation attempt from `idle`

This design deliberately does not add a hidden "force toggle-off" escape hatch in the same shortcut path. That would make the model harder to learn and easier to trigger accidentally. If real-world validation later shows that a manual escape hatch is necessary, it should be introduced intentionally as a separate product decision, not as an implicit third state on the same shortcut.

This avoids the user-visible bug where Quickey toggles off an app that never fully toggled on.

### 7. Required New Observability for Toggle Semantics

The current `POST_ACTIVATE_STATE` and `POST_RESTORE_STATE` logs were enough to expose the bug, but not enough to explain every branch of a future state machine.

`TogglePostActionState` should remain in place during Phase 1 as the compatibility bridge for today's diagnostics. In Phase 2 and Phase 3, it should either be expanded into or be superseded by the richer activation observation snapshot and log families in this design. It should not be removed before equivalent structured fields exist in the new logs.

Add log phases with stable names:

- `TOGGLE_ATTEMPT`
- `TOGGLE_CONFIRMATION`
- `TOGGLE_STABLE`
- `TOGGLE_DEGRADED`
- `TOGGLE_RESTORE_ATTEMPT`
- `TOGGLE_RESTORE_CONFIRMED`
- `TOGGLE_RESTORE_DEGRADED`

Each record should capture:

- target bundle
- shortcut app name
- session state
- previous bundle
- observed frontmost bundle
- `isActive`
- `isHidden`
- visible window count or boolean
- focused/main window availability if known
- activation path used
- recovery path used
- app classification and classification reason
- elapsed milliseconds since trigger

These records should use structured `key=value` formatting rather than ad hoc prose so they remain grep-friendly in `debug.log` and easy to compare across runs.

This data should be logged from main-actor-safe or background-safe code paths only, never directly from the event tap callback.

### 8. Event Tap Reliability Design

The event tap path needs to be treated as a lifecycle system, not just a callback.

Recommended lifecycle states:

- `stopped`
- `starting`
- `running`
- `disabledBySystem`
- `recovering`
- `degraded`

#### Recovery ladder

For `tapDisabledByTimeout`:

1. Capture a callback-safe snapshot.
2. Asynchronously record the snapshot.
3. Re-enable the tap in place.
4. Increment a rolling timeout counter.
5. If the counter exceeds a threshold within a time window, tear down and recreate the tap on the background run loop.
6. If recreation fails, mark capture degraded and surface that truth through readiness state and diagnostics.

For `tapDisabledByUserInput`:

- keep the light re-enable path
- do not immediately escalate to full recreation unless repeated disables indicate the tap is unhealthy

This design preserves hot-path safety while making repeated timeout storms diagnosable and actionable.

#### Recreation ordering and run loop ownership

Full recreation should default to the same dedicated background run loop thread that owns the current tap. The design should not migrate the tap across threads unless there is a deliberate architectural reason to do so.

Important implementation constraint from the current codebase:

- the existing `BackgroundRunLoopThread.addSource` readiness synchronization is one-shot semaphore based, which is not safe for repeated same-thread add/remove/recreate cycles

Before same-thread full recreation is implemented, the synchronization primitive must be upgraded to a reusable readiness mechanism. Creating a fresh thread per recreation is an acceptable fallback only if the reusable-thread approach cannot be made reliable quickly.

Recommended cleanup and rebuild order:

1. remove the old run loop source from the owning run loop
2. disable and invalidate the old tap
3. release the old run loop source and tap references
4. create the new tap on the dedicated background thread
5. create the new run loop source
6. add the new source to the same owning run loop
7. enable the new tap

This order avoids overlapping live tap ownership and keeps run loop cleanup explicit.

#### Recommended initial thresholds

The design should not leave the first implementation guessing at thresholds. Recommended starting values:

- first timeout: in-place re-enable only
- `3` timeouts within `30` seconds: full event tap recreation
- `2` recreation failures within `120` seconds: mark the event-tap subsystem `degraded` and report shortcut capture as not fully ready until recovery succeeds

These are starting values, not immutable product constants. They should be called out in tests and validation notes so later tuning is evidence-driven rather than guesswork.

### 9. Event Tap Diagnostics Strategy

Current diagnostics already record:

- disable reason
- last event type
- last key code
- modifier flags
- whether the shortcut was swallowed
- Hyper injection state
- registered shortcut count

The design extends this into structured lifecycle logging.

Recommended log families:

- `EVENT_TAP_STARTED`
- `EVENT_TAP_DISABLED`
- `EVENT_TAP_REENABLED`
- `EVENT_TAP_RECREATED`
- `EVENT_TAP_RECREATION_FAILED`
- `EVENT_TAP_DEGRADED`
- `EVENT_TAP_RECOVERED`

Additional fields:

- rolling timeout count
- time since last timeout
- whether recovery was in-place or full recreation
- run loop thread identity
- readiness state before and after recovery

The key rule remains:

> No synchronous file I/O, no expensive AX work, and no state-machine-heavy branching should happen inside the callback itself.

### 10. Architecture Placement

To keep responsibilities clear, the redesign should split concerns instead of growing `AppSwitcher` into a monolith.

Recommended responsibilities:

- `AppSwitcher`
  - orchestrates shortcut-triggered switching
  - owns high-level activation and toggle flow
- new `ToggleSessionCoordinator`
  - owns per-target runtime state
  - evaluates transitions between `idle`, `activating`, `activeStable`, `degraded`, and `deactivating`
- existing `FrontmostApplicationTracker`
  - remains responsible for previous-app memory and restore attempts
- new or expanded `ApplicationObservation` helper
  - computes frontmost/focused/main/visible-window evidence snapshots
  - should expose a test seam via an injected client or protocol-backed adapter, consistent with the existing `FrontmostApplicationTracker.Client` pattern
- `EventTapManager`
  - owns tap lifecycle and callback-safe recovery

This decomposition keeps:

- toggle semantics logic testable without live event tap behavior
- app observation logic testable separately from state transitions
- event tap recovery independent from app switching logic

#### Actor boundary

`ToggleSessionCoordinator` should be `@MainActor` in the initial design.

Reasoning:

- it is not part of the event tap callback hot path
- it will coordinate with `AppSwitcher`, `NSWorkspace` notifications, restore confirmation, and AX/AppKit-derived observation
- keeping it on the same actor as `AppSwitcher` reduces cross-actor timing races during rollout

If later profiling shows the coordinator itself has become a bottleneck, it can be revisited with a more explicit concurrency model. The default design should optimize for correctness and predictable ordering first.

#### Active-state invalidation

The design should use `NSWorkspace.didActivateApplicationNotification` as the primary invalidation signal for `activeStable` session expiry when another app becomes frontmost.

Related notification hooks should also be used where appropriate:

- `NSWorkspace.didTerminateApplicationNotification` to clear sessions for terminated targets
- `NSWorkspace.didLaunchApplicationNotification` or equivalent app-lifecycle signals only if later phases need them for launch-path confirmation

#### Observation performance constraints

The confirmation pass must not turn every shortcut press into unbounded AX chatter.

Performance rules:

- always read cheap app-level signals first:
  - `frontmostApplication`
  - target `isHidden`
  - target process/bundle identity
- only perform AX focused/main-window checks if the app class needs them
- `windowlessOrAccessory` and some `systemUtility` cases may skip focused/main-window checks entirely
- reuse one fetched window list within a confirmation pass instead of repeating AX window enumeration
- cap confirmation to a small number of passes before degrading

This keeps AX IPC off the hot input path and bounds the extra work to toggle-time confirmation only.

### 11. Testing Strategy

#### Highest-value automated tests

- `ToggleSessionCoordinator` transition tests
  - activating does not immediately become stable without confirmation
  - repeated trigger during `activating` does not toggle off
  - stable state does toggle off
  - degraded state retries activation instead of toggling off
- `ApplicationObservation` snapshot tests
  - frontmost mismatch with visible windows is not stable
  - frontmost match plus focused/main window is stable
  - hidden app is not stable
- timing-dependent tests
  - confirmation generation counters discard stale confirmation results
  - pending activation expires back to `idle` after the configured ceiling
  - degraded retry cap returns the session to `idle` instead of looping forever
  - repeated triggers suppressed by debounce do not incorrectly promote or toggle state
- session and lifecycle tests
  - target app termination while `activating` clears the pending session
  - target app termination while `degraded` clears the pending session
- repeated-trigger race tests
  - a same-shortcut trigger arriving after debounce but before confirmation completion continues activation rather than toggling off
- `AppSwitcher` orchestration tests
  - chooses restore path only from stable state
  - hide fallback runs when restore leaves contradictory visibility/frontmost results
- `EventTapManager` lifecycle tests
  - single timeout re-enables in place
  - repeated timeouts escalate to full tap recreation
  - degraded state is surfaced if recreation fails

#### Manual macOS validation

This design cannot be considered complete without targeted macOS validation.

Required manual validation matrix:

- normal apps: Safari, Finder, Terminal
- system/window-weird apps: Home, Clock, System Settings
- hidden app reactivation
- minimized-window recovery
- fast repeated shortcut presses
- event tap timeout stress path

Validation should confirm:

- no half-active frontmost mismatches are counted as success
- second press does not toggle off until stable activation is achieved
- toggle-off actually restores the previous app and leaves the target in a coherent state
- repeated event tap timeouts are logged and escalated predictably

## Acceptance Criteria

- Quickey no longer treats a transient or contradictory activation state as fully active
- Repeated shortcut presses during activation do not flap between activate and restore
- System apps that do not behave like regular windowed apps are handled honestly through degraded-success rules
- Toggle-off decisions align with the actual frontmost app that receives key events
- Event tap timeout storms produce structured diagnostics and a bounded recovery sequence
- Automated tests cover the new state transitions and escalation rules
- for already-running regular apps under nominal system load, Quickey should resolve an accepted trigger to `activeStable` or `degraded` within `300` ms
- the initial confirmation delay should remain below the current `200` ms shortcut debounce window
- full event tap recreation, when triggered under healthy permissions, should either complete or report explicit degraded state within `1` second
- confirmation failure should not cause an automatic restore-away visual rollback that makes the target app flicker out of view

## Implementation Notes For Planning

- Start with the phased rollout in this document instead of jumping directly to the full coordinator
- Introduce observation snapshots before changing activation mechanics
- Do not remove existing `POST_ACTIVATE_STATE` and `POST_RESTORE_STATE` logs until the new log families fully supersede them
- Keep `NSWorkspace.frontmostApplication` and `NSRunningApplication.isActive` side by side in logs during migration so mismatches remain visible
- Keep the current single previous-app memory in this pass; a multi-entry history stack is a later enhancement if needed
- Preserve callback-light behavior in `EventTapManager`; escalation should be scheduled outside the callback
- Expect `Home` and similar apps to remain special during early validation; that is a product-quality concession, not an architectural failure
