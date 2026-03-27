# Toggle-off Performance Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the approved toggle-off performance architecture in controlled milestones, starting with reusable runtime foundations and shadow mode, then enabling fast lane for normal apps without regressing compatibility behavior.

**Architecture:** Keep `AppSwitcher` as the public facade, but move the new behavior behind a main-actor `ToggleRuntime`, a main-actor `TapContextCache`, a main-actor `ObservationBroker`, and a background `ActivationPipeline`. `ToggleSessionCoordinator.previousBundle` remains the durable restore source of truth; background work only consumes immutable `RestoreContext` values extracted on the main actor.

**Tech Stack:** Swift 6, Swift Testing, AppKit, `NSWorkspace` notifications, Accessibility APIs, SkyLight private API, `OperationQueue`, `DispatchQueue`, file-backed diagnostics

---

## Spec Input

- Design spec: `docs/superpowers/specs/2026-03-27-toggle-off-performance-architecture-design.md`

## Scope Check

- This spec is one subsystem with staged rollout, not multiple unrelated features. One plan is appropriate.
- Execute this plan in an isolated worktree if possible. If you are not already in one, create it before Task 1:

```bash
git worktree add ../Quickey-issue-86 -b codex/issue-86-toggle-off-runtime fix/non-hyper-shortcut-toggle
cd ../Quickey-issue-86
```

## File Map

- Create: `Sources/Quickey/Models/RestoreContext.swift`
  Responsibility: immutable snapshot extracted on the main actor and passed into `ActivationPipeline`.
- Create: `Sources/Quickey/Models/ActivationCommand.swift`
  Responsibility: command/result enums plus timeout-budget helpers shared by pipeline and runtime.
- Create: `Sources/Quickey/Services/TapContextCache.swift`
  Responsibility: main-actor fast-lane cache, temporary compatibility quarantine tracking, cache invalidation reasons.
- Create: `Sources/Quickey/Services/ActivationPipeline.swift`
  Responsibility: bounded-concurrency `contextPreparationLane`, global-serial `activationCommandLane`, timeout mapping, and the thread-safe latest-generation gate used for pre-execution dropping.
- Create: `Sources/Quickey/Services/ObservationBroker.swift`
  Responsibility: cheap-confirmation-first flow, `NSWorkspace.didActivateApplicationNotification` integration, bounded confirmation window, escalated observation fallback.
- Create: `Sources/Quickey/Services/ToggleRuntime.swift`
  Responsibility: runtime generation/state orchestration, shadow mode, kill switch, lane selection, runtime invariants.
- Create: `Tests/QuickeyTests/TapContextCacheTests.swift`
  Responsibility: cache ownership, quarantine, invalidation, coordinator/cache source-of-truth boundaries.
- Create: `Tests/QuickeyTests/ActivationPipelineTests.swift`
  Responsibility: timeout mapping, bounded preparation concurrency, latest-wins dropping, serial mutating execution.
- Create: `Tests/QuickeyTests/ObservationBrokerTests.swift`
  Responsibility: cheap confirmation, notification-first behavior, 75ms confirmation window, escalated fallback.
- Create: `Tests/QuickeyTests/ToggleRuntimeTests.swift`
  Responsibility: shadow mode, kill switch, generation cancellation, runtime invariants, lane selection.
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
  Responsibility: wire the new services in, keep legacy path available, hand off accepted requests to `ToggleRuntime`, and eventually switch fast lane on.
- Modify: `Sources/Quickey/Services/ToggleSessionCoordinator.swift`
  Responsibility: expose any helper needed to read durable `previousBundle` without introducing a second source of truth.
- Modify: `Sources/Quickey/Services/ApplicationObservation.swift`
  Responsibility: support `ObservationBroker` without duplicating app/window classification logic.
- Modify: `Sources/Quickey/Services/FrontmostApplicationTracker.swift`
  Responsibility: remain legacy/compatibility helper only; do not become the durable restore source of truth again.
- Modify: `Sources/Quickey/Services/ShortcutManager.swift`
  Responsibility: only if a small seam or comment is needed to preserve accepted-trigger semantics during rollout; do not move toggle policy into shortcut handling.
- Modify: `Tests/QuickeyTests/AppSwitcherTests.swift`
  Responsibility: cover facade wiring, legacy fallback, previous-app quit invalidation, and fast-lane compatibility regressions.
- Modify: `Tests/QuickeyTests/ApplicationObservationTests.swift`
  Responsibility: support any new escalated-observation seams.
- Modify: `docs/architecture.md`
  Responsibility: document `ToggleRuntime`, `TapContextCache`, `ActivationPipeline`, `ObservationBroker`, and shadow-mode rollout.
- Modify: `docs/handoff-notes.md`
  Responsibility: record which milestone landed, what remains behind kill switch or shadow mode, and what still requires macOS validation.
- Modify: `docs/lessons-learned.md`
  Responsibility: capture confirmation-window, quarantine, and timeout lessons only if implementation changes the operational guidance.

## Milestone Mapping

- Task 1 = M2 foundations
- Task 2 = M2 cache boundary
- Task 3 = M2 executor
- Task 4 = M2 confirmation broker
- Task 5 = M2.5 shadow mode
- Task 6 = M3 fast lane default + compatibility fallback
- Task 7 = M4 docs, tuning gate, and verification handoff

### Task 1: Create The Runtime Foundation Types And Kill Switch

**Files:**
- Create: `Sources/Quickey/Models/RestoreContext.swift`
- Create: `Sources/Quickey/Models/ActivationCommand.swift`
- Create: `Sources/Quickey/Services/ToggleRuntime.swift`
- Test: `Tests/QuickeyTests/ToggleRuntimeTests.swift`

- [ ] **Step 1: Write the failing runtime-foundation tests**

Add a new focused test file with these first tests:

```swift
@Test @MainActor
func restoreContextCapturesGenerationAndPreviousBundle()

@Test @MainActor
func toggleRuntimeConfigurationDefaultsToLegacyMode()

@Test @MainActor
func runtimeInvariantsRejectSelfReferencingPreviousBundle()
```

- [ ] **Step 2: Run the focused runtime tests to verify they fail**

Run:

```bash
swift test --filter ToggleRuntimeTests
```

Expected: FAIL because `RestoreContext`, `ToggleRuntime`, and the configuration types do not exist yet.

- [ ] **Step 3: Create `RestoreContext` as the immutable background-work payload**

Add `Sources/Quickey/Models/RestoreContext.swift`:

```swift
import AppKit
import Carbon.HIToolbox

struct RestoreContext: Sendable {
    let targetBundleIdentifier: String
    let previousBundleIdentifier: String?
    let previousPID: pid_t?
    let previousPSNHint: ProcessSerialNumber?
    let previousWindowIDHint: CGWindowID?
    let previousBundleURL: URL?
    let capturedAt: CFAbsoluteTime
    let generation: Int
}
```

Do not make `RestoreContext` reach back into `TapContextCache`; it must be a value snapshot only.

- [ ] **Step 4: Create the shared command and timeout model**

Add `Sources/Quickey/Models/ActivationCommand.swift`:

```swift
enum ActivationCommand: Sendable {
    case prepareRestoreContext(targetBundleIdentifier: String, previousBundleIdentifier: String?)
    case restorePreviousFast(RestoreContext)
    case restorePreviousCompatible(RestoreContext)
    case hideTarget(bundleIdentifier: String, pid: pid_t)
    case raiseWindow(bundleIdentifier: String, pid: pid_t, windowID: CGWindowID)
}

enum ActivationCommandResult: Sendable, Equatable {
    case completed(String)
    case needsFallback(String)
    case degraded(String)
    case cancelledByNewerGeneration(Int)
}

struct ActivationTimeoutBudget: Sendable, Equatable {
    var prepareRestoreContext: TimeInterval = 0.04
    var restorePreviousFast: TimeInterval = 0.12
    var hideTarget: TimeInterval = 0.08
    var restorePreviousCompatible: TimeInterval = 0.18
    var raiseWindow: TimeInterval = 0.08
}
```

- [ ] **Step 5: Create `ToggleRuntime` configuration and kill-switch surface**

Add `Sources/Quickey/Services/ToggleRuntime.swift` with the configuration types first:

```swift
import Foundation

enum ToggleExecutionMode: Sendable, Equatable {
    case legacyOnly
    case shadowMode
    case pipelineEnabled
}

struct ToggleRuntimeConfiguration: Sendable, Equatable {
    var executionMode: ToggleExecutionMode = .legacyOnly
    var fastConfirmationWindow: TimeInterval = 0.075
    var contextPreparationConcurrencyLimit: Int = 2
    var fastLaneMissThreshold: Int = 3
    var fastLaneMissWindow: TimeInterval = 600
    var temporaryCompatibilityWindow: TimeInterval = 300
}
```

Keep the rest of `ToggleRuntime` minimal in this task; the important part is to define the names later tasks will use.

- [ ] **Step 6: Add the first runtime-invariant helper**

Still in `ToggleRuntime.swift`, add a helper that rejects self-referencing restore targets:

```swift
@MainActor
func normalizedPreviousBundle(
    targetBundleIdentifier: String,
    previousBundleIdentifier: String?
) -> String? {
    guard previousBundleIdentifier != targetBundleIdentifier else {
        return nil
    }
    return previousBundleIdentifier
}
```

- [ ] **Step 7: Run the focused runtime tests to verify the new foundation compiles and passes**

Run:

```bash
swift test --filter ToggleRuntimeTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/Quickey/Models/RestoreContext.swift Sources/Quickey/Models/ActivationCommand.swift Sources/Quickey/Services/ToggleRuntime.swift Tests/QuickeyTests/ToggleRuntimeTests.swift
git commit -m "构建 toggle runtime 基础类型"
```

### Task 2: Add `TapContextCache` Without Creating A Second Source Of Truth

**Files:**
- Create: `Sources/Quickey/Services/TapContextCache.swift`
- Modify: `Sources/Quickey/Services/ToggleSessionCoordinator.swift`
- Test: `Tests/QuickeyTests/TapContextCacheTests.swift`
- Test: `Tests/QuickeyTests/ToggleRuntimeTests.swift`

- [ ] **Step 1: Write the failing cache-boundary tests**

Add these tests first:

```swift
@Test @MainActor
func coordinatorPreviousBundleWinsWhenCacheMirrorDrifts()

@Test @MainActor
func cacheInvalidatesWhenPreviousAppTerminates()

@Test @MainActor
func threeFastLaneMissesEnterTemporaryCompatibilityWindow()
```

- [ ] **Step 2: Run the focused cache tests to verify they fail**

Run:

```bash
swift test --filter TapContextCacheTests
```

Expected: FAIL because `TapContextCache` does not exist yet.

- [ ] **Step 3: Create the cache entry type and invalidation reasons**

Add `Sources/Quickey/Services/TapContextCache.swift`:

```swift
import Foundation

enum CacheInvalidationReason: String, Sendable, Equatable {
    case sessionReset
    case previousAppTerminated
    case frontmostChanged
    case sourceOfTruthMismatch
}

@MainActor
final class TapContextCache {
    struct Entry: Equatable {
        var restoreContext: RestoreContext
        var fastLaneEligible: Bool
        var fastLaneMissCount: Int
        var fastLaneMissWindowStart: CFAbsoluteTime?
        var temporaryCompatibilityUntil: CFAbsoluteTime?
        var lastInvalidationReason: CacheInvalidationReason?
    }
}
```

- [ ] **Step 4: Implement coordinator-first cache updates**

Still in `TapContextCache.swift`, add an update method that treats `ToggleSessionCoordinator.previousBundle` as the durable source of truth:

```swift
@discardableResult
func upsert(
    targetBundleIdentifier: String,
    coordinatorPreviousBundle: String?,
    restoreContext: RestoreContext
) -> Entry {
    let normalizedPrevious = coordinatorPreviousBundle == targetBundleIdentifier ? nil : coordinatorPreviousBundle
    var entry = entries[targetBundleIdentifier] ?? Entry(
        restoreContext: restoreContext,
        fastLaneEligible: true,
        fastLaneMissCount: 0,
        fastLaneMissWindowStart: nil,
        temporaryCompatibilityUntil: nil,
        lastInvalidationReason: nil
    )
    entry.restoreContext = RestoreContext(
        targetBundleIdentifier: restoreContext.targetBundleIdentifier,
        previousBundleIdentifier: normalizedPrevious,
        previousPID: restoreContext.previousPID,
        previousPSNHint: restoreContext.previousPSNHint,
        previousWindowIDHint: restoreContext.previousWindowIDHint,
        previousBundleURL: restoreContext.previousBundleURL,
        capturedAt: restoreContext.capturedAt,
        generation: restoreContext.generation
    )
    entries[targetBundleIdentifier] = entry
    return entry
}
```

- [ ] **Step 5: Add quarantine and invalidation helpers**

Implement:

```swift
func markFastLaneMiss(for targetBundleIdentifier: String, now: CFAbsoluteTime, threshold: Int, window: TimeInterval, quarantine: TimeInterval)

func invalidate(_ targetBundleIdentifier: String, reason: CacheInvalidationReason)

func entry(for targetBundleIdentifier: String, now: CFAbsoluteTime) -> Entry?
```

`entry(for:now:)` must clear expired `temporaryCompatibilityUntil` values instead of leaving stale quarantine state behind.

- [ ] **Step 6: Add the tiny coordinator helper needed by the cache**

If `ToggleSessionCoordinator` needs a more explicit read path, add:

```swift
func durablePreviousBundle(for bundleIdentifier: String) -> String? {
    session(for: bundleIdentifier)?.previousBundle
}
```

Do not duplicate the durable previous-bundle value anywhere else.

- [ ] **Step 7: Run the focused cache and runtime tests**

Run:

```bash
swift test --filter TapContextCacheTests
swift test --filter ToggleRuntimeTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/Quickey/Services/TapContextCache.swift Sources/Quickey/Services/ToggleSessionCoordinator.swift Tests/QuickeyTests/TapContextCacheTests.swift Tests/QuickeyTests/ToggleRuntimeTests.swift
git commit -m "新增 toggle 上下文缓存"
```

### Task 3: Implement `ActivationPipeline` With Bounded Preparation And Serial Mutations

**Files:**
- Create: `Sources/Quickey/Services/ActivationPipeline.swift`
- Test: `Tests/QuickeyTests/ActivationPipelineTests.swift`
- Modify: `Sources/Quickey/Models/ActivationCommand.swift`

- [ ] **Step 1: Write the failing executor tests**

Start with:

```swift
@Test
func latestGenerationDropsQueuedMutatingCommandsBeforeExecution()

@Test
func restoreFastTimeoutMapsToNeedsFallback()

@Test
func contextPreparationUsesBoundedConcurrency()
```

- [ ] **Step 2: Run the focused pipeline tests to verify they fail**

Run:

```bash
swift test --filter ActivationPipelineTests
```

Expected: FAIL because the pipeline does not exist yet.

- [ ] **Step 3: Create the pipeline shell with two queues**

Add `Sources/Quickey/Services/ActivationPipeline.swift`:

```swift
import Foundation

final class LatestGenerationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func write(_ newValue: Int) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class ActivationPipeline {
    struct Client: Sendable {
        let prepareRestoreContext: @Sendable (ActivationCommand) -> ActivationCommandResult
        let runMutatingCommand: @Sendable (ActivationCommand) -> ActivationCommandResult
    }

    private let timeouts: ActivationTimeoutBudget
    private let contextPreparationQueue: OperationQueue
    private let activationCommandQueue: OperationQueue
    private let client: Client
}
```

- [ ] **Step 4: Configure the queues to match the spec**

Inside the initializer, enforce the bounded-vs-serial model:

```swift
contextPreparationQueue.maxConcurrentOperationCount = 2
contextPreparationQueue.qualityOfService = .userInteractive

activationCommandQueue.maxConcurrentOperationCount = 1
activationCommandQueue.qualityOfService = .userInteractive
```

Do not use an unbounded concurrent queue for preparation.

- [ ] **Step 5: Implement latest-wins dropping before mutating execution**

Add a submit API shaped like this:

```swift
func submit(
    _ command: ActivationCommand,
    generation: Int,
    latestGeneration: @escaping @Sendable () -> Int,
    completion: @escaping @Sendable (ActivationCommandResult) -> Void
)
```

Before executing a mutating command, compare `generation` to `latestGeneration()` and short-circuit with:

```swift
completion(.cancelledByNewerGeneration(generation))
```

Do this before starting the command, not after it has already run.

- [ ] **Step 6: Implement timeout mapping explicitly**

Use `DispatchWorkItem` or equivalent to enforce the spec budgets:

```swift
if command == .restorePreviousFast(context) {
    completion(.needsFallback("timeout_restore_fast"))
}
```

Map every timeout to the exact error string from the spec. Do not invent alternate wording.

- [ ] **Step 7: Run the focused executor tests**

Run:

```bash
swift test --filter ActivationPipelineTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/Quickey/Services/ActivationPipeline.swift Sources/Quickey/Models/ActivationCommand.swift Tests/QuickeyTests/ActivationPipelineTests.swift
git commit -m "新增 activation pipeline 执行器"
```

### Task 4: Add `ObservationBroker` With Notification-First Cheap Confirmation

**Files:**
- Create: `Sources/Quickey/Services/ObservationBroker.swift`
- Create: `Tests/QuickeyTests/ObservationBrokerTests.swift`
- Modify: `Sources/Quickey/Services/ApplicationObservation.swift`
- Modify: `Tests/QuickeyTests/ApplicationObservationTests.swift`

- [ ] **Step 1: Write the failing confirmation tests**

Add these first:

```swift
@Test @MainActor
func cheapConfirmationSucceedsFromFrontmostNotificationWithoutEscalation()

@Test @MainActor
func cheapConfirmationFallsBackToPollingWithinSeventyFiveMilliseconds()

@Test @MainActor
func contradictoryCheapConfirmationEscalatesToWindowObservation()
```

- [ ] **Step 2: Run the focused confirmation tests to verify they fail**

Run:

```bash
swift test --filter ObservationBrokerTests
```

Expected: FAIL because `ObservationBroker` does not exist yet.

- [ ] **Step 3: Create the broker result type and client seam**

Add `Sources/Quickey/Services/ObservationBroker.swift`:

```swift
import AppKit

@MainActor
final class ObservationBroker {
    struct ConfirmationResult: Equatable {
        let confirmed: Bool
        let usedEscalatedObservation: Bool
        let snapshot: ActivationObservationSnapshot
    }

    struct Client {
        let frontmostBundleIdentifier: @MainActor () -> String?
        let observeTarget: @MainActor (NSRunningApplication) -> ActivationObservationSnapshot
        let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    }
}
```

- [ ] **Step 4: Implement the cheap-confirmation window exactly as specified**

Add a method like:

```swift
func confirmFastRestore(
    targetApp: NSRunningApplication,
    previousBundleIdentifier: String?,
    confirmationWindow: TimeInterval = 0.075,
    completion: @escaping @MainActor (ConfirmationResult) -> Void
)
```

Behavior:

- Read `frontmostApplication` immediately
- If that confirms the target is no longer frontmost, finish without escalation
- Otherwise wait only inside the bounded `0.075` second window
- Use short-interval rechecks only inside that window
- Escalate to `ApplicationObservation.snapshot(for:)` only when the cheap signals remain contradictory

- [ ] **Step 5: Reuse `ApplicationObservation` instead of re-implementing classification**

If the broker needs a helper, add it in `ApplicationObservation.swift` rather than duplicating snapshot logic:

```swift
@MainActor
func cheapRestoreConfirmation(
    targetBundleIdentifier: String,
    currentFrontmostBundleIdentifier: String?,
    targetIsHidden: Bool
) -> Bool?
```

Return `nil` for ambiguous states so the broker knows when to escalate.

- [ ] **Step 6: Run the focused confirmation tests and the existing observation tests**

Run:

```bash
swift test --filter ObservationBrokerTests
swift test --filter ApplicationObservationTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/Quickey/Services/ObservationBroker.swift Sources/Quickey/Services/ApplicationObservation.swift Tests/QuickeyTests/ObservationBrokerTests.swift Tests/QuickeyTests/ApplicationObservationTests.swift
git commit -m "新增 toggle 确认 broker"
```

### Task 5: Wire Shadow Mode Through `AppSwitcher` Without Changing User-Visible Behavior

**Files:**
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Modify: `Sources/Quickey/Services/ToggleRuntime.swift`
- Modify: `Tests/QuickeyTests/AppSwitcherTests.swift`
- Modify: `Tests/QuickeyTests/ToggleRuntimeTests.swift`

- [ ] **Step 1: Write the failing shadow-mode tests**

Add:

```swift
@Test @MainActor
func shadowModeLogsLaneDecisionButStillRunsLegacyPath()

@Test @MainActor
func shadowModeDoesNotSubmitMutatingCommands()
```

- [ ] **Step 2: Run the focused app-switcher and runtime tests to verify they fail**

Run:

```bash
swift test --filter AppSwitcherTests
swift test --filter ToggleRuntimeTests
```

Expected: FAIL because shadow mode is not wired yet.

- [ ] **Step 3: Make `AppSwitcher` own the new services but keep legacy behavior authoritative**

In `Sources/Quickey/Services/AppSwitcher.swift`, inject and store:

```swift
private let toggleRuntime: ToggleRuntime
private let tapContextCache: TapContextCache
private let activationPipeline: ActivationPipeline
private let observationBroker: ObservationBroker
private let latestGenerationStore: LatestGenerationStore
```

Also extract the current stable toggle-off branch from `toggleApplication(for:)` into a dedicated helper before adding shadow mode:

```swift
@discardableResult
private func performLegacyToggle(
    for shortcut: AppShortcut,
    runningApp: NSRunningApplication,
    attemptStartedAt: CFAbsoluteTime
) -> Bool
```

Move the existing restore/hide/confirm behavior into that helper without changing semantics. Update the initializer so tests can pass fakes in.

- [ ] **Step 4: Add a runtime decision API that can return legacy, shadow, or pipeline execution**

In `ToggleRuntime.swift`, add:

```swift
enum ToggleRuntimeDecision: Equatable {
    case useLegacy
    case shadow(ShadowDecision)
    case execute(PipelineDecision)
}

struct ShadowDecision: Equatable {
    let selectedLane: String
    let wouldUseHideTarget: Bool
    let previousBundleIdentifier: String?
}

enum PipelineDecision: Equatable {
    case fastLane(RestoreContext)
    case compatibilityLane(RestoreContext)
}
```

Also update the accepted-trigger path in `AppSwitcher` so immediately after `acceptPendingActivation(...)` succeeds it writes `state.generation` into `latestGenerationStore`. That store is the source used by `ActivationPipeline.submit(... latestGeneration: ...)`.

- [ ] **Step 5: Route accepted toggle-off attempts through shadow mode first**

In `AppSwitcher.toggleApplication(for:)`, keep the current legacy restore code as the authoritative effect, but add:

```swift
switch toggleRuntime.decision(for: shortcut, runningApp: runningApp, attemptStartedAt: attemptStartedAt) {
case .useLegacy:
    return performLegacyToggle(for: shortcut, runningApp: runningApp, attemptStartedAt: attemptStartedAt)
case .shadow(let shadowDecision):
    DiagnosticLog.log("TOGGLE_SHADOW lane=\(shadowDecision.selectedLane) previous=\(shadowDecision.previousBundleIdentifier ?? "nil")")
    return performLegacyToggle(for: shortcut, runningApp: runningApp, attemptStartedAt: attemptStartedAt)
case .execute:
    Issue.record("Pipeline execution must not be enabled in Task 5")
    return false
}
```

- [ ] **Step 6: Run the focused tests and verify no user-visible behavior changed**

Run:

```bash
swift test --filter AppSwitcherTests
swift test --filter ToggleRuntimeTests
```

Expected: PASS, with shadow mode logging but no mutating commands submitted.

- [ ] **Step 7: Commit**

```bash
git add Sources/Quickey/Services/AppSwitcher.swift Sources/Quickey/Services/ToggleRuntime.swift Tests/QuickeyTests/AppSwitcherTests.swift Tests/QuickeyTests/ToggleRuntimeTests.swift
git commit -m "接入 toggle shadow mode"
```

### Task 6: Enable Fast Lane For Normal Apps And Preserve Compatibility Fallback

**Files:**
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Modify: `Sources/Quickey/Services/ToggleRuntime.swift`
- Modify: `Sources/Quickey/Services/TapContextCache.swift`
- Modify: `Sources/Quickey/Services/FrontmostApplicationTracker.swift`
- Modify: `Tests/QuickeyTests/AppSwitcherTests.swift`
- Modify: `Tests/QuickeyTests/ToggleRuntimeTests.swift`
- Modify: `Tests/QuickeyTests/TapContextCacheTests.swift`

- [ ] **Step 1: Write the failing fast-lane tests**

Add:

```swift
@Test @MainActor
func fastLaneRestoreDoesNotHideTargetWhenConfirmationSucceeds()

@Test @MainActor
func fastLaneMissAutomaticallyFallsBackToCompatibilityLane()

@Test @MainActor
func previousAppQuitInvalidatesCacheAndFallsBackToCompatibility()
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
swift test --filter AppSwitcherTests
swift test --filter TapContextCacheTests
```

Expected: FAIL because the pipeline is not authoritative yet.

- [ ] **Step 3: Promote `ToggleRuntime` from shadow-only to executable pipeline mode**

In `ToggleRuntime.swift`, implement lane selection:

```swift
func decision(
    for shortcut: AppShortcut,
    runningApp: NSRunningApplication,
    attemptStartedAt: CFAbsoluteTime
) -> ToggleRuntimeDecision
```

Fast lane eligibility must require:

```swift
entry.fastLaneEligible &&
sessionCoordinator.durablePreviousBundle(for: shortcut.bundleIdentifier) != nil &&
applicationObservation.snapshot(for: runningApp).classification == .regularWindowed
```

- [ ] **Step 4: Execute `restorePreviousFast` before any hide in pipeline mode**

In `AppSwitcher`, when `ToggleRuntimeDecision.execute(.fastLane(...))` is returned:

```swift
let generation = pendingActivationState?.generation ?? 0

activationPipeline.submit(
    .restorePreviousFast(context),
    generation: generation,
    latestGeneration: latestGenerationStore.read
) { result in
    // on success -> broker confirmation
    // on timeout or contradiction -> submit compatibility fallback
}
```

Do not call `hideTarget` before the fast-lane restore.

- [ ] **Step 5: Map misses into compatibility fallback and quarantine**

On fast-lane miss:

```swift
tapContextCache.markFastLaneMiss(
    for: shortcut.bundleIdentifier,
    now: confirmationClient.now(),
    threshold: configuration.fastLaneMissThreshold,
    window: configuration.fastLaneMissWindow,
    quarantine: configuration.temporaryCompatibilityWindow
)
```

Then run:

```swift
activationPipeline.submit(.hideTarget(bundleIdentifier: shortcut.bundleIdentifier, pid: runningApp.processIdentifier), ...)
activationPipeline.submit(.restorePreviousCompatible(context), ...)
```

- [ ] **Step 6: Keep compatibility-only helpers in `FrontmostApplicationTracker`**

If `FrontmostApplicationTracker` still participates, limit it to:

```swift
func restorePreviousAppIfPossible() -> PreviousAppRestoreAttempt
```

Do not let it own the durable previous bundle again. If a helper now conflicts with `TapContextCache` or `ToggleSessionCoordinator`, remove or narrow it.

- [ ] **Step 7: Run the focused tests plus the existing toggle suites**

Run:

```bash
swift test --filter AppSwitcherTests
swift test --filter ToggleRuntimeTests
swift test --filter TapContextCacheTests
swift test --filter ToggleSessionCoordinatorTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/Quickey/Services/AppSwitcher.swift Sources/Quickey/Services/ToggleRuntime.swift Sources/Quickey/Services/TapContextCache.swift Sources/Quickey/Services/FrontmostApplicationTracker.swift Tests/QuickeyTests/AppSwitcherTests.swift Tests/QuickeyTests/ToggleRuntimeTests.swift Tests/QuickeyTests/TapContextCacheTests.swift
git commit -m "启用正常应用 fast lane 恢复"
```

### Task 7: Finalize Coexistence Rules, Docs, And Verification Handoff

**Files:**
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Modify: `Sources/Quickey/Services/ShortcutManager.swift` only if comments or seams are needed for accepted-trigger behavior
- Modify: `docs/architecture.md`
- Modify: `docs/handoff-notes.md`
- Modify: `docs/lessons-learned.md` if operational guidance changes
- Test: `Tests/QuickeyTests/AppSwitcherTests.swift`
- Test: `Tests/QuickeyTests/ActivationPipelineTests.swift`

- [ ] **Step 1: Write the failing coexistence and metrics tests**

Add:

```swift
@Test @MainActor
func cooldownBlocksBeforeNewGenerationIsAllocated()

@Test
func timeoutMetricsIncludeRestoreAndHideErrorCodes()
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
swift test --filter AppSwitcherTests
swift test --filter ActivationPipelineTests
```

Expected: FAIL because the coexistence rules and metrics fields are not fully enforced yet.

- [ ] **Step 3: Enforce the cooldown-vs-generation coexistence rule in `AppSwitcher`**

Keep the current entry gating ahead of runtime allocation:

```swift
if let lastTime = lastToggleTimeByBundle[shortcut.bundleIdentifier],
   attemptStartedAt - lastTime < toggleCooldown {
    DiagnosticLog.log("TOGGLE[\(shortcut.appName)]: BLOCKED cooldown ...")
    return false
}
```

Do not allocate a new generation before this branch returns.

- [ ] **Step 4: Emit the new structured metric fields**

Update logging paths to include:

```swift
"axHideErrorCode=\(axHideErrorCode ?? "nil") restoreErrorCode=\(restoreErrorCode ?? "nil") cacheInvalidationReason=\(cacheInvalidationReason ?? "nil")"
```

For attempts slower than the performance budget, add a compact trace line:

```swift
"TOGGLE_TRACE attemptId=\(attemptId) lane=\(lane) queueWaitMs=\(queueWaitMs) mutatingCommandCount=\(mutatingCommandCount) fallbackCount=\(fallbackCount)"
```

- [ ] **Step 5: Update the architecture and handoff docs**

Document the landed runtime pieces in `docs/architecture.md`:

```markdown
- `ToggleRuntime`: main-actor lane selection, kill switch, and generation coordination
- `TapContextCache`: main-actor fast-lane cache; not the durable previous-app source of truth
- `ActivationPipeline`: bounded prepare lane + serial mutating lane
- `ObservationBroker`: notification-first cheap confirmation with a 75ms bounded window
```

Update `docs/handoff-notes.md` with:

```markdown
- which milestone is landed
- whether shadow mode or kill switch remains active
- which macOS validation matrix entries are still pending
```

- [ ] **Step 6: Run the full automated verification suite**

Run:

```bash
swift test
swift build
swift build -c release
```

Expected: PASS. If running on non-macOS, document that runtime validation remains pending.

- [ ] **Step 7: Record the required manual macOS validation checklist in the handoff**

Add explicit checklist items for:

- Safari / Finder / Terminal fast lane
- Home / System Settings compatibility lane
- shadow mode to pipeline-enabled transition
- previous app quitting between toggle-on and toggle-off
- fast repeated same-shortcut presses

- [ ] **Step 8: Commit**

```bash
git add Sources/Quickey/Services/AppSwitcher.swift Sources/Quickey/Services/ShortcutManager.swift Tests/QuickeyTests/AppSwitcherTests.swift Tests/QuickeyTests/ActivationPipelineTests.swift docs/architecture.md docs/handoff-notes.md docs/lessons-learned.md
git commit -m "完善 toggle 性能文档与验证交接"
```

## Self-Review

### Spec Coverage

- M2 foundations: covered by Tasks 1-4
- M2.5 shadow mode: covered by Task 5
- M3 fast lane + compatibility fallback + quarantine: covered by Task 6
- M4 coexistence rules, metrics, docs, and validation handoff: covered by Task 7
- Runtime invariants: introduced in Task 1, enforced in Tasks 5-7
- Kill switch: introduced in Task 1, wired in Task 5, preserved through Task 7

### Placeholder Scan

- No `TBD`, `TODO`, “implement later”, or “write tests” placeholders remain.
- Every task lists exact files, concrete test names, concrete commands, and explicit commit commands.

### Type Consistency

- `RestoreContext`, `ActivationCommand`, `ActivationCommandResult`, `ToggleRuntimeConfiguration`, `TapContextCache`, `ActivationPipeline`, and `ObservationBroker` are named consistently across all tasks.
- `ToggleSessionCoordinator.previousBundle` remains the durable restore source of truth in every task.
