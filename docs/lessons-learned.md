# Quickey Troubleshooting Guidance

## CGEvent Tap Permissions

**Issue**
`AXIsProcessTrusted()` can return true while `CGEvent.tapCreate()` still fails.

**Cause**
On macOS 15, a working event tap requires both Accessibility and Input Monitoring. Either permission alone is not enough.

**Practical guidance**
Check both `AXIsProcessTrusted()` and `CGPreflightListenEventAccess()` as prerequisites, but treat shortcut capture as ready only after the active event tap starts successfully. When validating on a clean machine, request and confirm both permissions, then verify the tap startup path.

## Ad-hoc Signing and TCC

**Issue**
Permissions appear enabled in System Settings, but Quickey is still not trusted after a rebuild.

**Cause**
TCC binds permissions to the app's code signature. Ad-hoc signatures change between builds, so a new binary no longer matches the old TCC record.

**Practical guidance**
After rebuilding locally, reset and regrant permissions if the app stops matching its previous TCC state:

```bash
tccutil reset Accessibility com.quickey.app
tccutil reset ListenEvent com.quickey.app
```

For long-lived releases, use a stable Developer ID signature.

## Launch Via `open`

**Issue**
Launching the app binary directly can produce different permission behavior than launching the app bundle.

**Cause**
TCC and app identity matching are tied to the bundle launch path. Directly running `./Quickey.app/Contents/MacOS/Quickey` can bypass the launch context used during permission registration.

**Practical guidance**
Validate permission-sensitive behavior by starting the app with `open Quickey.app`, not by executing the binary directly.

## File-Based Diagnostics

**Issue**
`log stream` and `log show` may not expose the diagnostics needed during local debugging.

**Cause**
Unified logging is filtered and can hide the messages you expect to see.

**Practical guidance**
Use a file-backed log for troubleshooting, such as `~/.config/Quickey/debug.log`. Create the parent directory first, then append short diagnostic lines there.

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
Use the SkyLight-based activation path when Quickey must reliably front the target app. Treat it as the validated route for LSUIElement activation behavior.

## Frontmost Truth for Toggle Semantics

**Issue**
An app can appear visually present while Quickey still should not treat it as safely toggleable.

**Cause**
App activation on macOS is transitional. `NSRunningApplication.activate()` only attempts activation, and `NSRunningApplication.isActive` can briefly disagree with `NSWorkspace.shared.frontmostApplication` during odd system-app or window-recovery flows.

**Practical guidance**
For app-level toggle behavior, treat `NSWorkspace.shared.frontmostApplication` as the primary truth because Apple defines it as the app receiving key events. Use `isActive`, `isHidden`, and window visibility as supporting signals, not as the sole toggle-off gate.

## Stable Activation Beats Instantaneous Activation

**Issue**
Repeated shortcut presses can flap between "activate" and "toggle off" if Quickey decides from a single immediate state snapshot.

**Cause**
The first trigger may only have started activation, while the second trigger arrives before the app has reached a stable frontmost state with a usable window.

**Practical guidance**
Do not let "activation requested" mean "activation complete". Require a short post-activation confirmation pass and only allow toggle-off from a stable active state. During pending or degraded activation, a repeat trigger should re-confirm or re-attempt activation instead of restoring away immediately.

## Session-Owned Previous App Memory

**Issue**
Restore confirmation becomes unreliable if previous-app memory is cleared as soon as a restore attempt starts.

**Cause**
The restore path needs the same `previousBundle` to survive activation, pending confirmation, deactivation, and retry/degraded branches. A destructive read from a lightweight tracker loses that ownership too early.

**Practical guidance**
Let the toggle session own the durable `previousBundle` once a trigger is accepted. Use `FrontmostApplicationTracker` to capture the current frontmost app and execute restore attempts, but keep the authoritative previous-app value on the coordinator session until the session is reset.

## Notification-Driven Toggle Invalidation

**Issue**
Stable toggle state can become stale as soon as the user changes apps outside Quickey.

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

## Cross-App Restore Breaks Toggle-Off Tracking

**Issue**
When App A's toggle-off restores App B to the foreground, pressing App B's shortcut fails to toggle it off — instead it re-activates or silently does nothing.

**Cause**
`stableActivationState` for App B was cleared when App A was toggled on (because `acceptPendingActivation` clears stable state for the new target's bundle, and `clearActivationTracking` clears the old target). When App B returns to the foreground via another app's restore, no code recreates its `stableActivationState`. Without stable state, `shouldToggleOff()` returns false, and the code falls through to the activate path. Additionally, `frontmostTracker.noteCurrentFrontmostApp(excluding: B)` sees B as the frontmost app and skips it, leaving `lastNonTargetBundleIdentifier` as B itself — a self-reference.

**Practical guidance**
When the target app is already active and frontmost but has no tracking state, treat it as an untracked toggle-off: hide the app and let macOS bring the next app forward. Guard against self-referencing `previousApp` (target == previous) by explicitly clearing it. Log the `ACTIVE_UNTRACKED` path with coordinator phase and tracker state for post-hoc analysis.

## Previous App Self-Reference in Tracker

**Issue**
`previousApp` resolves to the target app's own bundle identifier, causing toggle-off to attempt restoring the same app it just hid.

**Cause**
When App A is frontmost and App B is toggled on, `noteCurrentFrontmostApp(excluding: B)` correctly records A. But `lastNonTargetBundleIdentifier` is not cleared when App B's toggle-off restores App A. If the user then toggles App A, `noteCurrentFrontmostApp(excluding: A)` sees A as frontmost, skips the update, and the stale value (which happens to be A from the previous cycle) persists.

**Practical guidance**
Always check `previousApp != shortcut.bundleIdentifier` before recording it. If a self-reference is detected, treat `previousApp` as nil and log the anomaly.

## Toggle State Machine Must Handle External Activation

**Issue**
Apps can become frontmost through paths Quickey doesn't control (Dock click, Cmd-Tab, another app's restore). These externally-activated apps have no `stableActivationState` or coordinator session.

**Practical guidance**
Do not assume that every frontmost app was activated by Quickey. Add a catch-all path for apps that are active+frontmost but untracked. The `ACTIVE_UNTRACKED` path serves this purpose — it hides the app without attempting to restore a specific previous app, since the previous app info is unreliable in this state.

## DiagnosticLog.log() Uses queue.async to Avoid Blocking

**Issue**
`DiagnosticLogWriter.log()` originally used `queue.sync` which blocked the calling thread until file I/O completed. When called from `toggleApplication` on the main actor, each call blocked the main thread for a FileHandle open/seek/write/close cycle.

**Cause**
The `queue.sync` pattern was chosen for ordered log output, but the cost was blocking I/O on the calling thread.

**Resolution**
Switched to `queue.async`. The serial queue still guarantees ordered output. Timestamp is captured before dispatch to preserve accurate timing. A `flush()` method is available for tests that need to read logs immediately after writing.

## Reference: alt-tab-macos Activation Strategy (2026-03-25)

**Context**
Compared Quickey's toggle implementation with alt-tab-macos (https://github.com/lwouis/alt-tab-macos), the most mature macOS window switcher.

**Key findings**
- alt-tab uses a "show-select-focus" model, not toggle. No stableActivationState equivalent — just a `appIsBeingUsed` boolean.
- Three-layer activation (SkyLight + makeKeyWindow 0xf8 + AXRaise) is identical to Quickey's approach.
- alt-tab runs SkyLight/AX calls on a background queue (`BackgroundWork.accessibilityCommandsQueue`), not the main thread. Quickey runs them on the main actor.
- alt-tab tracks frontmost app via AX notifications (`kAXApplicationActivatedNotification`) rather than NSWorkspace notifications. More real-time but more complex.
- alt-tab maintains full MRU window ordering (`lastFocusOrder`), not just a single previous app.
- alt-tab has `redundantSafetyMeasures()` that polls hardware modifier state after each key event to detect lost keyUp events.
- alt-tab has no debounce/cooldown — its show-select-focus model doesn't need it.

**Hammerspoon 对比 (https://github.com/Hammerspoon/hammerspoon):**
- 激活方案更保守：NSRunningApplication + Carbon PSN 双层（无 SkyLight）
- 窗口焦点：纯 AXUIElement (becomeMain + raise)，无 SkyLight makeKeyWindow
- 前台监控：NSWorkspace 通知（与 Quickey 一致）
- Event tap 在**主线程**运行（Quickey 在后台线程更好）
- 专门为 Finder 写了 0.3s 延迟 workaround — 说明纯 AX 方案不够可靠
- Hotkey 用 Carbon RegisterEventHotKey 而非 CGEventTap（更轻量但功能受限）

**Practical guidance**
Quickey 的三层激活方案（SkyLight + 0xf8 makeKeyWindow + AXRaise）是三个参考项目中最完整的，与 alt-tab 一致，优于 Hammerspoon 的双层方案。toggle 状态机（pending/stable/degraded）是 Quickey 独有的需求（alt-tab 和 Hammerspoon 都不做 toggle），设计合理。后台线程 event tap 优于 Hammerspoon 的主线程方案。可优化方向：SkyLight/AX 调用可考虑移至后台队列（alt-tab 做法），但需评估 @MainActor 约束。

## Event Tap Timeout Recovery Needs Escalation

**Issue**
Re-enabling an event tap after a timeout is necessary but not always sufficient.

**Cause**
macOS can repeatedly disable the tap with `tapDisabledByTimeout`, which indicates sustained callback or lifecycle pressure rather than a one-off interruption.

**Practical guidance**
Keep the callback path light and re-enable in place first, but track rolling timeout counts. In Quickey's current recovery ladder, the first timeout stays in-place, 3 timeouts within 30 seconds escalate to full recreation, and 2 recreation failures within 120 seconds mark the tap subsystem degraded. Recreate the tap on the same dedicated background RunLoop thread, using a reusable readiness mechanism so repeated add/remove/recreate cycles do not deadlock.
