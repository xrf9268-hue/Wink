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
Headless mode (`-p`) disables all interactive features: skills (`/review`, `/simplify`), clean output formatting, and session-level capabilities. The `stream-json` format dumps raw JSON with session_id, token statistics, and cost metadata on every line. Adding `--verbose` (required by `stream-json`) makes it worse. There is no output format option in `-p` mode that provides both real-time visibility and human readability.

**Practical guidance**
Always use `/loop` for recurring automated work. `/loop` runs in interactive mode where skills work natively, output is clean, and no shell scripting infrastructure (tmux, stdbuf, tee, signal traps, circuit breakers) is needed. Example:

```
/loop 30m Follow the instructions in docs/loop-prompt.md
```

## `/codex:review` in Loop Jobs Is Session-Local, Not PR-Visible

**Issue**
`/codex:review` findings do not appear as PR comments. Treating them like bot review findings (readable via `gh pr view --comments`) leads to empty checks and missed issues across iterations.

**Cause**
`/codex:review` ([Codex Plugin CC](https://github.com/openai/codex-plugin-cc)) outputs results only within the Claude Code session. Unlike `@chatgpt-codex-connector[bot]` (which posts PR comments with P0/P1/P2 tags), `/codex:review` results live in session memory. `/review` behaves the same way — session-local, not PR-posted.

**Practical guidance**
- After pushing code, the working tree is clean. Use `--base main` to review the branch diff: `/codex:review --base main --background`.
- Use `--background` by default (plugin README: "generally recommended to run it in the background"). Retrieve results with `/codex:status` + `/codex:result`.
- Session context persists across `/loop` iterations, so findings from iteration N are visible in iteration N+1. But they are not durable beyond the session.
- In auto-merge checks, verify `/codex:review` findings via session memory, not PR comments. Only bot review findings (`@chatgpt-codex-connector[bot]`) can be checked on the PR itself.

## Event Tap Timeout Recovery Needs Escalation

**Issue**
Re-enabling an event tap after a timeout is necessary but not always sufficient.

**Cause**
macOS can repeatedly disable the tap with `tapDisabledByTimeout`, which indicates sustained callback or lifecycle pressure rather than a one-off interruption.

**Practical guidance**
Keep the callback path light and re-enable in place first, but track rolling timeout counts. In Quickey's current recovery ladder, the first timeout stays in-place, 3 timeouts within 30 seconds escalate to full recreation, and 2 recreation failures within 120 seconds mark the tap subsystem degraded. Recreate the tap on the same dedicated background RunLoop thread, using a reusable readiness mechanism so repeated add/remove/recreate cycles do not deadlock.
