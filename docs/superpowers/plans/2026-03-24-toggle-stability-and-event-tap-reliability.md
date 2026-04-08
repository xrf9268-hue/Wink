# Toggle Stability And Event Tap Reliability Implementation Plan

> Partially superseded for toggle-off: the restore-state / `POST_RESTORE_STATE` / `TOGGLE_RESTORE_*` portions of this plan were replaced on 2026-04-08 by a direct-hide-only implementation. Keep this file as historical execution context, not as current toggle-off guidance.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved stable-state toggle redesign and event tap recovery hardening without regressing Quickey's app-level shortcut behavior.

**Architecture:** Land the redesign in three controlled phases. Phase 1 adds observation snapshots, structured diagnostics, and restore-state foundations. Phase 2 adds lightweight pending/stable confirmation inside the existing `AppSwitcher` flow without a full coordinator. Phase 3 introduces `ToggleSessionCoordinator`, degraded-state lifecycle rules, and bounded event-tap recreation on the dedicated background run loop.

**Tech Stack:** Swift 6, Swift Testing, AppKit, CoreGraphics, Accessibility APIs, `NSWorkspace` notifications, background RunLoop event taps

---

## Spec Input

- Design spec: `docs/superpowers/specs/2026-03-23-toggle-stability-and-event-tap-design.md`

## File Map

- Create: `Sources/Quickey/Services/ApplicationObservation.swift`
- Create: `Sources/Quickey/Services/ToggleSessionCoordinator.swift`
- Create: `Tests/QuickeyTests/ApplicationObservationTests.swift`
- Create: `Tests/QuickeyTests/ToggleSessionCoordinatorTests.swift`
- Create: `Tests/QuickeyTests/EventTapManagerLifecycleTests.swift`
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Modify: `Sources/Quickey/Services/FrontmostApplicationTracker.swift`
- Modify: `Sources/Quickey/Services/EventTapManager.swift`
- Modify: `Sources/Quickey/Services/ShortcutManager.swift` only if accepted-trigger semantics need explicit comments or test seams
- Modify: `Tests/QuickeyTests/AppSwitcherTests.swift`
- Modify: `Tests/QuickeyTests/QuickeyTests.swift` only if existing event-tap callback tests remain the best home for callback-safe assertions
- Modify: `docs/architecture.md`
- Modify: `docs/handoff-notes.md`
- Modify: `docs/lessons-learned.md` if implementation changes the recommended event-tap recovery guidance

## Phase Boundaries

- Phase 1 in this plan = Tasks 1-2
- Phase 2 in this plan = Task 3
- Phase 3 in this plan = Tasks 4-5
- Final documentation and validation = Task 6

The plan itself is the Phase 2 implementation spec the design review asked for. Do not start Phase 3 until Phase 2 behavior is green and manually understandable from logs.

### Task 1: Build Application Observation And Phase-1 Diagnostics

**Files:**
- Create: `Sources/Quickey/Services/ApplicationObservation.swift`
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Test: `Tests/QuickeyTests/ApplicationObservationTests.swift`
- Test: `Tests/QuickeyTests/AppSwitcherTests.swift`

- [ ] **Step 1: Write failing observation tests before creating the helper**

Add focused tests that pin the intended observation behavior:

```swift
@Test @MainActor
func observationMarksFrontmostMismatchAsNotStable()

@Test @MainActor
func observationReevaluatesClassificationPerAttempt()

@Test @MainActor
func observationCanRepresentCurrentTogglePostActionFields()
```

- [ ] **Step 2: Run the focused observation tests to verify they fail for the right reason**

Run: `swift test --filter ApplicationObservation`
Expected: fail because the helper types and seams do not exist yet.

- [ ] **Step 3: Create the new observation helper with an injectable client seam**

Add `Sources/Quickey/Services/ApplicationObservation.swift` with a small, testable surface:

```swift
enum ApplicationClassification: Sendable {
    case regularWindowed
    case nonStandardWindowed
    case windowlessOrAccessory
    case systemUtility
}

struct ActivationObservationSnapshot: Sendable, Equatable {
    let targetBundleIdentifier: String?
    let observedFrontmostBundleIdentifier: String?
    let targetIsActive: Bool
    let targetIsHidden: Bool
    let visibleWindowCount: Int
    let hasFocusedWindow: Bool
    let hasMainWindow: Bool
    let classification: ApplicationClassification
    let classificationReason: String
}
```

Use injected closures or a `Client` struct, not direct global calls, so the helper can be tested without live AppKit state.

- [ ] **Step 4: Preserve and bridge the existing `TogglePostActionState` path**

Keep `TogglePostActionState` in `AppSwitcher.swift`, but make it a compatibility view over `ActivationObservationSnapshot` instead of a parallel truth source. During Phase 1, both log paths can coexist.

- [ ] **Step 5: Replace ad hoc post-action logging with structured `key=value` records**

Update `AppSwitcher` log helpers to emit fields from `ActivationObservationSnapshot`:

```swift
"frontmost=\(snapshot.observedFrontmostBundleIdentifier ?? "nil") target=\(snapshot.targetBundleIdentifier ?? "nil") targetActive=\(snapshot.targetIsActive) targetHidden=\(snapshot.targetIsHidden) visibleWindowCount=\(snapshot.visibleWindowCount) classification=\(snapshot.classification)"
```

Do not remove `POST_ACTIVATE_STATE` / `POST_RESTORE_STATE` yet; make them wrappers over the structured fields.

- [ ] **Step 6: Enumerate the required toggle lifecycle log families**

Make the Phase 1 diagnostics deliver the named lifecycle records required by the design spec:
- `TOGGLE_ATTEMPT`
- `TOGGLE_CONFIRMATION`
- `TOGGLE_STABLE`
- `TOGGLE_DEGRADED`
- `TOGGLE_RESTORE_ATTEMPT`
- `TOGGLE_RESTORE_CONFIRMED`
- `TOGGLE_RESTORE_DEGRADED`

Each record should emit, when available:
- target bundle
- previous bundle
- observed frontmost bundle
- `isActive`
- `isHidden`
- visible-window evidence
- app classification and classification reason
- activation or recovery path
- elapsed milliseconds

`POST_ACTIVATE_STATE` / `POST_RESTORE_STATE` may remain as compatibility wrappers during Phase 1, but the implementation should already route through the canonical structured fields above.

- [ ] **Step 7: Add a failing `AppSwitcher` test proving the new snapshot is used for logs**

Cover a case where:
- `frontmostApplication` is another bundle
- `runningApp.isActive == true`
- the snapshot still marks the state as not stable

- [ ] **Step 8: Run the focused observation and app-switcher tests to verify they now pass**

Run:

```bash
swift test --filter ApplicationObservation
swift test --filter AppSwitcher
```

Expected: green, with diagnostics still representing the old post-action fields.

- [ ] **Step 9: Commit**

```bash
git add Sources/Quickey/Services/ApplicationObservation.swift Sources/Quickey/Services/AppSwitcher.swift Tests/QuickeyTests/ApplicationObservationTests.swift Tests/QuickeyTests/AppSwitcherTests.swift
git commit -m "feat: add activation observation snapshots"
```

### Task 2: Fix Previous-App Ownership And Tracker Semantics

**Files:**
- Modify: `Sources/Quickey/Services/FrontmostApplicationTracker.swift`
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Test: `Tests/QuickeyTests/AppSwitcherTests.swift`
- Create or modify: focused frontmost-tracker tests under `Tests/QuickeyTests/`

- [ ] **Step 1: Write a failing test for premature previous-app clearing**

Add a test proving the current tracker behavior is wrong for post-restore confirmation:

```swift
@Test @MainActor
func restoreAttemptDoesNotDiscardPreviousBundleBeforeConfirmation()
```

- [ ] **Step 2: Run the focused tracker test to verify it fails**

Run: `swift test --filter FrontmostApplicationTracker`
Expected: fail because the current implementation clears state too early.

- [ ] **Step 3: Introduce explicit restore-attempt state instead of destructive read semantics**

Refactor the tracker so the code can:

```swift
let previousBundle = tracker.lastNonTargetBundleIdentifier
let restoreAccepted = tracker.restorePreviousAppIfPossible()
// bundle is only cleared after explicit confirmation or explicit session reset
```

If a cleaner shape is needed, add a tiny value type:

```swift
struct PreviousAppRestoreAttempt: Sendable, Equatable {
    let bundleIdentifier: String?
    let restoreAccepted: Bool
}
```

Do not leave a "read-and-clear" API behind.

- [ ] **Step 4: Update `AppSwitcher` to stop depending on destructive tracker reads**

Current restore logs capture `previousApp` before restore. Keep that behavior, but ensure a failed confirmation path can still see the same bundle later.

- [ ] **Step 5: Add a failing test for manual frontmost change invalidating the stored previous bundle**

This test should model:
- first trigger captures previous bundle
- user manually changes the frontmost app before confirmation succeeds
- the next fresh activation session refreshes `previousBundle` from current frontmost state

- [ ] **Step 6: Implement the minimum refresh rule**

Refresh `previousBundle` only when a session restarts from `idle` or when a confirmation generation mismatch invalidates the old activation session. Do not rewrite previous-bundle history mid-session unless the session has been abandoned.

- [ ] **Step 7: Verify tracker and app-switcher tests pass**

Run:

```bash
swift test --filter FrontmostApplicationTracker
swift test --filter AppSwitcher
```

- [ ] **Step 8: Commit**

```bash
git add Sources/Quickey/Services/FrontmostApplicationTracker.swift Sources/Quickey/Services/AppSwitcher.swift Tests/QuickeyTests
git commit -m "fix: preserve previous app until restore is confirmed"
```

### Task 3: Implement Phase-2 Pending/Stable Confirmation In `AppSwitcher`

**Files:**
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Modify: `Sources/Quickey/Services/ShortcutManager.swift` only if accepted-trigger semantics need comments or test adjustments
- Test: `Tests/QuickeyTests/AppSwitcherTests.swift`
- Test: `Tests/QuickeyTests/ApplicationObservationTests.swift`

- [ ] **Step 1: Write failing tests for the Phase-2 pending/stable behavior**

Cover the highest-risk flows:

```swift
@Test @MainActor
func secondTriggerDuringPendingActivationDoesNotToggleOff()

@Test @MainActor
func staleConfirmationGenerationCannotPromoteState()

@Test @MainActor
func acceptedTriggerStillReturnsTrueWhileConfirmationIsPending()
```

- [ ] **Step 2: Run the focused Phase-2 tests to verify they fail**

Run: `swift test --filter AppSwitcher`
Expected: fail because no pending/stable coordination exists yet.

- [ ] **Step 3: Replace the blind nested recovery timers with stage-by-stage completion**

Refactor `recoverWindowlessApp` so it can be coordinated instead of racing with a separate confirmation timer. The implementation should move toward:

```swift
private func recoverWindowlessApp(
    _ app: NSRunningApplication,
    shortcut: AppShortcut,
    completion: @escaping @MainActor (WindowRecoveryStageResult) -> Void
)
```

Do not keep an unstructured `asyncAfter -> asyncAfter -> final fallback` chain once Phase 2 begins.

- [ ] **Step 4: Implement a lightweight pending/stable store inside `AppSwitcher`**

Do not introduce `ToggleSessionCoordinator` yet. Use a small Phase-2-local structure such as:

```swift
private struct PendingActivationState {
    let bundleIdentifier: String
    let previousBundleIdentifier: String?
    let generation: Int
    let startedAt: CFAbsoluteTime
}
```

This is enough for:
- confirmation generation invalidation
- pending vs stable distinction
- accepted-trigger boolean semantics

- [ ] **Step 5: Make confirmation interleave with recovery stages rather than race them**

Required order for one activation attempt:

```text
activation attempt
-> confirmation pass
-> if needed, recovery stage 1
-> confirmation pass
-> if needed, recovery stage 2
-> confirmation pass
-> stable or idle
```

Do not run a confirmation timer in parallel with an unfinished recovery stage.

- [ ] **Step 6: Keep synchronous return semantics stable for `ShortcutManager`**

`ShortcutManager.trigger(_:)` should continue to treat `true` as "the trigger was accepted and work started", not "the app definitely reached stable state." Document that expectation in code comments if needed.

- [ ] **Step 7: Add a focused regression test for the existing `recoverWindowlessApp` timing path**

The test should prove that a recovery stage can complete before the next confirmation is evaluated.

- [ ] **Step 8: Verify the Phase-2 suite passes**

Run:

```bash
swift test --filter AppSwitcher
swift test --filter ApplicationObservation
```

Expected: green, with no visual-rollback logic added.

- [ ] **Step 9: Commit**

```bash
git add Sources/Quickey/Services/AppSwitcher.swift Sources/Quickey/Services/ShortcutManager.swift Tests/QuickeyTests
git commit -m "feat: add pending and stable activation confirmation"
```

### Task 4: Introduce `ToggleSessionCoordinator` And Notification-Driven Lifecycle Rules

**Files:**
- Create: `Sources/Quickey/Services/ToggleSessionCoordinator.swift`
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Modify: `Sources/Quickey/Services/ApplicationObservation.swift`
- Create: `Tests/QuickeyTests/ToggleSessionCoordinatorTests.swift`
- Modify: `Tests/QuickeyTests/AppSwitcherTests.swift`

- [ ] **Step 1: Write failing coordinator tests before creating the coordinator**

Cover:

```swift
@Test @MainActor
func activeStableExpiresWhenAnotherAppBecomesFrontmost()

@Test @MainActor
func degradedSessionReturnsToIdleAfterRetryCap()

@Test @MainActor
func terminatedTargetClearsPendingSession()

@Test @MainActor
func sessionStoreEvictsStalestIdleOrExpiredSessionAtConfiguredCap()
```

- [ ] **Step 2: Run the focused coordinator tests to verify they fail**

Run: `swift test --filter ToggleSessionCoordinator`
Expected: fail because the coordinator file does not exist yet.

- [ ] **Step 3: Create the coordinator as `@MainActor` and document the exception**

Implement a focused coordinator:

```swift
@MainActor
final class ToggleSessionCoordinator {
    struct Session { ... }
    func beginActivation(for bundleIdentifier: String, previousBundle: String?, now: CFAbsoluteTime) -> Session
    func markStable(...)
    func markDegraded(...)
    func beginDeactivation(...)
    func handleFrontmostChange(...)
    func handleTermination(...)
}
```

Add a short comment that this is an intentional `@MainActor` exception because it coordinates AppKit/AX/`NSWorkspace` ordering and is not part of the event-tap callback hot path.

- [ ] **Step 4: Use `NSWorkspace` notifications as the invalidation source**

Wire notification-driven helpers for:
- `NSWorkspace.didActivateApplicationNotification`
- `NSWorkspace.didTerminateApplicationNotification`

Do not poll.

- [ ] **Step 5: Move previous-bundle ownership into the coordinator session**

At this point the coordinator, not `FrontmostApplicationTracker`, should be the durable source of `previousBundle` for:
- pending activation
- active stable
- deactivation

- [ ] **Step 6: Add failing tests for degraded expiry and retry interaction**

Prove:
- user-triggered reconfirm resets degraded idle expiry
- user-triggered reconfirm does not reset the 5-second absolute ceiling
- same-session retries count against the same retry cap

- [ ] **Step 7: Implement idle expiry, retry cap, bounded session storage, and session reset rules**

Use deterministic time injection in tests. Do not rely on `sleep`.

Bound live coordinator sessions to configured target bundles, with an initial runtime cap of 50 sessions. When the cap is reached:
- evict the stalest idle session first
- if no idle session exists, evict the stalest expired non-idle session
- do not evict the currently mutating session

- [ ] **Step 8: Verify coordinator and integration tests pass**

Run:

```bash
swift test --filter ToggleSessionCoordinator
swift test --filter AppSwitcher
```

- [ ] **Step 9: Commit**

```bash
git add Sources/Quickey/Services/ToggleSessionCoordinator.swift Sources/Quickey/Services/AppSwitcher.swift Sources/Quickey/Services/ApplicationObservation.swift Tests/QuickeyTests/ToggleSessionCoordinatorTests.swift Tests/QuickeyTests/AppSwitcherTests.swift
git commit -m "feat: add toggle session coordinator"
```

### Task 5: Harden Event Tap Recreation And Background RunLoop Ownership

**Files:**
- Modify: `Sources/Quickey/Services/EventTapManager.swift`
- Create: `Tests/QuickeyTests/EventTapManagerLifecycleTests.swift`
- Modify: `Tests/QuickeyTests/QuickeyTests.swift` if existing callback tests should be moved or shared

- [ ] **Step 1: Write failing tests for repeated recreation on the same background thread**

Cover:

```swift
@Test
func repeatedTimeoutsTriggerRecreationAfterThreshold()

@Test
func repeatedRecreationDoesNotDeadlockBackgroundRunLoopThread()

@Test
func recreationFailureEmitsExplicitDegradedState()
```

- [ ] **Step 2: Run the focused event-tap lifecycle tests to verify they fail**

Run: `swift test --filter EventTapManagerLifecycle`
Expected: fail because the lifecycle state and recreation thresholds do not exist yet.

- [ ] **Step 3: Replace the one-shot readiness semaphore with a reusable readiness mechanism**

Do not implement same-thread recreation while `BackgroundRunLoopThread.addSource(_:)` still depends on a single-consume semaphore.

Prefer a reusable state holder, for example:

```swift
private struct RunLoopState {
    var runLoop: CFRunLoop?
    var isReady: Bool
}
```

guarded by a lock or condition. The goal is repeated add/remove/recreate on the same owning thread, not a one-time startup handshake.

- [ ] **Step 4: Implement lifecycle counters and escalation thresholds**

Add deterministic state for:
- first timeout -> in-place re-enable
- 3 timeouts / 30 seconds -> full recreation
- 2 recreation failures / 120 seconds -> degraded capture state

- [ ] **Step 5: Recreate the tap with explicit same-thread ordering**

Keep a single dedicated background run loop thread by default. Follow the documented order:

```text
remove source
-> disable/invalidate old tap
-> release old references
-> create new tap
-> create new source
-> add new source
-> enable new tap
```

If same-thread recreation proves impossible quickly, a fresh-thread fallback is acceptable only as an explicitly documented temporary path.

- [ ] **Step 6: Add a regression test for callback-safe logging during recovery**

Ensure timeout logging remains callback-safe and does not perform synchronous file I/O or AX work.

- [ ] **Step 7: Enumerate the required event-tap lifecycle log families**

Make the hardened event-tap implementation emit the named lifecycle records required by the design spec:
- `EVENT_TAP_STARTED`
- `EVENT_TAP_DISABLED`
- `EVENT_TAP_REENABLED`
- `EVENT_TAP_RECREATED`
- `EVENT_TAP_RECREATION_FAILED`
- `EVENT_TAP_DEGRADED`
- `EVENT_TAP_RECOVERED`

Each record should emit, when available:
- rolling timeout count
- time since last timeout
- recovery mode (`in_place` or `recreated`)
- owning run-loop thread identity
- readiness state before and after recovery

- [ ] **Step 8: Verify the event-tap suite passes**

Run:

```bash
swift test --filter EventTapManagerLifecycle
swift test --filter EventTapManager
```

- [ ] **Step 9: Commit**

```bash
git add Sources/Quickey/Services/EventTapManager.swift Tests/QuickeyTests/EventTapManagerLifecycleTests.swift Tests/QuickeyTests/QuickeyTests.swift
git commit -m "fix: harden event tap recreation lifecycle"
```

### Task 6: Documentation, Verification, And macOS Validation

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/handoff-notes.md`
- Modify: `docs/lessons-learned.md` if event-tap recovery guidance changes materially

- [ ] **Step 1: Update architecture and runtime docs to match the landed implementation**

Document:
- observation helper responsibilities
- coordinator ownership of `previousBundle`
- notification-driven invalidation
- event-tap recreation strategy

- [ ] **Step 2: Run the full automated verification suite**

Run:

```bash
swift test
swift build
swift build -c release
./scripts/package-app.sh
```

Expected: all green.

- [ ] **Step 3: Run the targeted macOS validation matrix**

Validate:
- Safari, Finder, Terminal
- Home, Clock, System Settings
- hidden app reactivation
- minimized window recovery
- fast repeated same-shortcut presses
- at least one event-tap timeout/recovery stress run if reproducible

- [ ] **Step 4: Confirm the new behavioral guarantees on macOS**

Verify:
- no half-active frontmost mismatch is promoted to stable
- second press during pending activation does not toggle off
- confirmation failure does not cause flicker-inducing restore-away rollback
- stable toggle-off restores the previous app and leaves coherent state
- event tap recreation either succeeds or reports degraded state explicitly

- [ ] **Step 5: Update handoff notes with real results and residual risks**

- [ ] **Step 6: Commit**

```bash
git add docs/architecture.md docs/handoff-notes.md docs/lessons-learned.md
git commit -m "docs: document toggle stability and event tap lifecycle changes"
```
