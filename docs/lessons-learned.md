# Quickey Troubleshooting Guidance

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
Do not let "activation requested" mean "activation complete". Require a short post-activation confirmation pass and only allow toggle-off from a stable active state. During pending or degraded activation, a repeat trigger should re-confirm or re-attempt activation instead of making hide/reactivate decisions from a transient snapshot.

## Session-Owned Previous App Memory

**Issue**
Session context becomes incoherent if previous-app memory is cleared as soon as activation is accepted.

**Cause**
Even after removing restore-first toggle-off, the same `previousBundle` still needs to survive activation, pending confirmation, stable state, and deactivation as durable session context. A destructive read from a lightweight tracker loses that ownership too early.

**Practical guidance**
Let the toggle session own the durable `previousBundle` once a trigger is accepted. Use `FrontmostApplicationTracker` to capture current frontmost context, but keep the authoritative previous-app value on the coordinator session until the session is reset. Treat it as session context and observability metadata, not as a reason to reintroduce restore-first toggle-off.

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

## Untracked Frontmost Apps Need a Direct Hide Path

**Issue**
An app can be frontmost and apparently stable even though Quickey has no active stable session for it.

**Cause**
Apps can become frontmost through paths Quickey does not own: Dock click, Cmd-Tab, macOS choosing the next app after a hide, or another app flow returning them to the foreground. `stableActivationState` only exists for apps Quickey itself recently stabilized, so these externally surfaced apps may otherwise fall through to the activate path.

**Practical guidance**
When the target app is already active and frontmost but has no tracking state, treat it as an untracked toggle-off: hide the app and let macOS bring the next app forward. Guard against self-referencing `previousApp` (target == previous) by explicitly clearing it. Log the `ACTIVE_UNTRACKED` path with coordinator phase and tracker state for post-hoc analysis.

## Previous App Self-Reference in Tracker

**Issue**
`previousApp` resolves to the target app's own bundle identifier, poisoning activation context and making later toggle decisions misleading.

**Cause**
When App A is frontmost and App B is toggled on, `noteCurrentFrontmostApp(excluding: B)` correctly records A. But after App B is hidden and macOS brings App A back, `noteCurrentFrontmostApp(excluding: A)` sees A as frontmost and skips the update, so a stale self-reference can persist into the next activation cycle.

**Practical guidance**
Always check `previousApp != shortcut.bundleIdentifier` before recording it. If a self-reference is detected, treat `previousApp` as nil and log the anomaly.

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
This comparison predates the 2026-04-08 capture split and front-process-first activation hot path, so read it as historical reference, not as a full description of the current runtime.

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
仍然成立的结论有两点：Quickey 需要 SkyLight 作为 LSUIElement 的可靠强激活基础；后台线程 event tap 仍优于主线程 tap。已经过时的部分是“完整三层激活始终在热路径上”和“所有快捷键都要靠 event tap”这两个心智模型。当前更准确的做法是：标准快捷键优先走 Carbon，Hyper 才走 event tap；激活热路径先做 front-process 激活，只在观察显示未稳定时再逐级升级到 `makeKeyWindow` / `AXRaise` / window recovery。

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
Keep the callback path light and re-enable in place first, but track rolling timeout counts. In Quickey's current recovery ladder, the first timeout stays in-place, 3 timeouts within 30 seconds escalate to full recreation, and 2 recreation failures within 120 seconds mark the tap subsystem degraded. Recreate the tap on the same dedicated background RunLoop thread, using a reusable readiness mechanism so repeated add/remove/recreate cycles do not deadlock.

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
