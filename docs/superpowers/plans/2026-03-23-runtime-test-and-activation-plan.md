# Runtime Test And Activation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise confidence in Quickey's macOS runtime path by closing the biggest testing gaps and aligning activation fallbacks with current Apple guidance.

**Architecture:** Keep the current AppKit-first structure, but improve testability at the service seam level instead of rewriting large subsystems. Tackle the highest-risk runtime path first: event-tap delivery and shortcut orchestration, then system-facing services, then the deprecated activation fallback.

**Tech Stack:** Swift 6, Swift Testing, AppKit, CoreGraphics event taps, ServiceManagement, macOS command-line coverage tooling

---

## Issue Mapping

- [ ] #69 `Strengthen runtime lifecycle tests for event tap and shortcut orchestration`
- [ ] #70 `Add test seams for system-facing services with 0% coverage`
- [ ] #71 `Align app activation fallback with current macOS guidance`

## File Map

- Modify: `Sources/Quickey/Services/EventTapManager.swift`
- Modify: `Sources/Quickey/Services/ShortcutManager.swift`
- Modify: `Sources/Quickey/Services/AccessibilityPermissionService.swift`
- Modify: `Sources/Quickey/Services/AppListProvider.swift`
- Modify: `Sources/Quickey/Services/AppPreferences.swift`
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Modify: `Sources/Quickey/Services/FrontmostApplicationTracker.swift`
- Modify: `Sources/Quickey/UI/MenuBarController.swift` only if activation semantics or launch-item messaging need a UI adjustment
- Modify: `docs/architecture.md` if activation strategy changes materially
- Modify: `docs/handoff-notes.md` with new validation notes
- Test: `Tests/QuickeyTests/QuickeyTests.swift`
- Test: `Tests/QuickeyTests/ShortcutManagerStatusTests.swift`
- Test: `Tests/QuickeyTests/HyperKeyServiceTests.swift`
- Create or modify focused test files for service seams as needed

### Task 1: Harden Event Tap And Shortcut Runtime Tests

**Files:**
- Modify: `Sources/Quickey/Services/EventTapManager.swift`
- Modify: `Sources/Quickey/Services/ShortcutManager.swift`
- Test: `Tests/QuickeyTests/QuickeyTests.swift`
- Test: `Tests/QuickeyTests/ShortcutManagerStatusTests.swift`

- [ ] **Step 1: Add a failing regression test for background callback delivery**

Write a test that invokes a background-safe matched-shortcut handler from a non-main queue and asserts delivery lands on `MainActor`.

- [ ] **Step 2: Run the focused test to verify it fails for the right reason**

Run: `swift test --filter matchedShortcutHandlerCanBeInvokedFromBackgroundThread`
Expected: fail because the runtime path still assumes the wrong executor, or the helper seam is missing.

- [ ] **Step 3: Add failing tests for event-tap lifecycle edges**

Cover:
- tap disabled by timeout or user input
- Hyper key press/release state transitions
- shortcut swallowing decision for a registered shortcut

- [ ] **Step 4: Run those focused tests to verify they fail before implementation**

Run: `swift test --filter EventTapManager`
Expected: targeted failures only.

- [ ] **Step 5: Implement the minimum runtime-safe seam**

Keep the callback background-safe and move only the app logic hop to `MainActor`. Do not broaden `@MainActor` coupling.

- [ ] **Step 6: Add failing `ShortcutManager` tests for permission transition decisions**

Cover:
- all permissions granted starts the tap when not running
- permission loss stops the tap when running
- status snapshot reflects accessibility, input monitoring, and tap state separately

- [ ] **Step 7: Run the focused shortcut-manager tests to verify they fail**

Run: `swift test --filter ShortcutManager`
Expected: failures exercise the intended path rather than unrelated compile or setup issues.

- [ ] **Step 8: Implement the minimum code needed to make the new lifecycle tests pass**

Prefer fake services and deterministic state over timers or sleeps where possible.

- [ ] **Step 9: Verify the runtime suite passes**

Run: `swift test --filter EventTapManager`
Run: `swift test --filter ShortcutManager`
Expected: green.

- [ ] **Step 10: Commit**

```bash
git add Sources/Quickey/Services/EventTapManager.swift Sources/Quickey/Services/ShortcutManager.swift Tests/QuickeyTests/QuickeyTests.swift Tests/QuickeyTests/ShortcutManagerStatusTests.swift
git commit -m "test: harden event tap and shortcut runtime coverage"
```

### Task 2: Add Test Seams For System-Facing Services

**Files:**
- Modify: `Sources/Quickey/Services/AccessibilityPermissionService.swift`
- Modify: `Sources/Quickey/Services/AppListProvider.swift`
- Modify: `Sources/Quickey/Services/AppPreferences.swift`
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Modify: `Sources/Quickey/Services/FrontmostApplicationTracker.swift`
- Test: `Tests/QuickeyTests/LaunchAtLoginServiceTests.swift`
- Create: focused service test files under `Tests/QuickeyTests/`

- [ ] **Step 1: Identify the smallest seam needed per zero-coverage service**

For each service, decide whether a protocol, injectable closure, or tiny wrapper is enough. Avoid refactors that mix multiple service boundaries.

- [ ] **Step 2: Write failing tests for permission and preference snapshots**

Cover:
- `AccessibilityPermissionService` snapshots both permissions correctly
- `AppPreferences` updates only after service calls succeed

- [ ] **Step 3: Run the focused tests to verify they fail**

Run: `swift test --filter AccessibilityPermissionService`
Run: `swift test --filter AppPreferences`
Expected: fail because seams or assertions are not in place yet.

- [ ] **Step 4: Write failing tests for app discovery and frontmost-app tracking**

Cover the decision logic, not the real system APIs.

- [ ] **Step 5: Run those focused tests to verify they fail**

Run: `swift test --filter AppListProvider`
Run: `swift test --filter FrontmostApplicationTracker`
Expected: fail for missing seams or missing logic coverage.

- [ ] **Step 6: Implement minimal seams and no more**

Use injected wrappers or closures for system calls. Preserve existing actor boundaries and runtime behavior.

- [ ] **Step 7: Add or extend `AppSwitcher` tests around fallback decision logic**

Do not require real app activation; assert which path would be chosen under controlled conditions.

- [ ] **Step 8: Verify the system-service suite passes**

Run: `swift test`
Run: `swift test --enable-code-coverage`
Expected: all green, with measurable coverage improvement in the service layer.

- [ ] **Step 9: Capture updated coverage numbers**

Run:

```bash
xcrun llvm-cov report .build/arm64-apple-macosx/debug/QuickeyPackageTests.xctest/Contents/MacOS/QuickeyPackageTests -instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata .build/arm64-apple-macosx/debug/Quickey
```

Record the before/after numbers in the PR description or handoff notes.

- [ ] **Step 10: Commit**

```bash
git add Sources/Quickey/Services Tests/QuickeyTests
git commit -m "test: add seams for system-facing services"
```

### Task 3: Align Activation Fallback With Current macOS Guidance

**Files:**
- Modify: `Sources/Quickey/Services/AppSwitcher.swift`
- Modify: `docs/architecture.md` if fallback semantics change
- Modify: `docs/handoff-notes.md`
- Test: focused `AppSwitcher` tests under `Tests/QuickeyTests/`

- [ ] **Step 1: Re-check Apple documentation for activation fallback semantics**

Use current Apple docs for:
- `NSRunningApplication.activate(options:)`
- any recommended modern alternative relevant to Quickey's fallback path

- [ ] **Step 2: Write a failing test for the desired fallback behavior**

The test should prove the chosen fallback path and its expected result when the primary SkyLight path fails.

- [ ] **Step 3: Run the focused fallback test to verify it fails**

Run: `swift test --filter AppSwitcher`
Expected: fail because the fallback has not been updated yet.

- [ ] **Step 4: Implement the minimal fallback change**

Either remove the deprecated call in favor of a better-supported path, or isolate and document it if no practical replacement preserves behavior.

- [ ] **Step 5: Verify build warnings and behavior**

Run: `swift build`
Run: `swift build -c release`
Expected: deprecation warning removed or reduced to the intentionally retained path only.

- [ ] **Step 6: Update docs if the activation rationale changed**

Document the tradeoff clearly in `docs/architecture.md` and `docs/handoff-notes.md`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Quickey/Services/AppSwitcher.swift docs/architecture.md docs/handoff-notes.md Tests/QuickeyTests
git commit -m "fix: align activation fallback with modern macOS guidance"
```

### Task 4: Final Verification And macOS Validation

**Files:**
- Modify: `docs/handoff-notes.md`

- [ ] **Step 1: Run the full verification suite**

Run:

```bash
swift test
swift build
swift build -c release
./scripts/package-app.sh
```

- [ ] **Step 2: Re-run the manual macOS smoke checklist**

Validate:
- permissions prompt and refresh behavior
- menu bar item stability after permissions are granted
- registered shortcut handling
- no crash after interacting with the event tap path for at least 30 seconds

- [ ] **Step 3: Update handoff notes with real macOS results and residual risks**

- [ ] **Step 4: Create the PR with issue links**

Reference:
- `Closes #69`
- `Closes #70`
- `Closes #71`
