# Plan: ObservationBroker 与 Bounded Cheap Confirmation

> Superseded for implementation: `ObservationBroker` and the associated compatibility-lane confirmation design were removed on 2026-04-08 when Quickey converged toggle-off to a single direct-hide path. Keep this plan only as historical context.

**Issue:** #90
**Status:** Draft
**Dependencies:** #87 (closed), prefer after #89 (PR #100 open)

## Overview

实现 `ObservationBroker`，在 toggle-off 命令执行后确认切换是否成功。采用 cheap-confirmation-first 策略，避免确认本身成为性能瓶颈。

## Sub-tasks

### Task 1: 创建 ObservationBroker 核心类型与骨架

**文件:** `Sources/Quickey/Services/ObservationBroker.swift`

创建 `@MainActor` 类，包含：

- `ConfirmationResult` 结构体：`confirmed: Bool`, `usedEscalatedObservation: Bool`, `snapshot: ActivationObservationSnapshot`
- `Client` 结构体（依赖注入）：
  - `frontmostBundleIdentifier: @MainActor () -> String?`
  - `observeTarget: @MainActor (NSRunningApplication) -> ActivationObservationSnapshot`
  - `schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void`
- 初始化器接受 `Client` 和 `ApplicationObservation`

### Task 2: 实现廉价确认路径 (cheap confirmation)

在 `ObservationBroker` 中实现 `confirmFastRestore()`:

1. 立即读 `frontmostBundleIdentifier`
2. 若 target 已不是 frontmost → 快速返回 `confirmed = true`
3. 若仍是 frontmost → 进入 75ms 有界等待
4. 等待期间通知驱动 + 短间隔重读（10ms 间隔）
5. 75ms 超时 → `confirmed = false`

**真值优先级:**
1. `frontmostApplication`（最高）
2. `targetIsHidden`
3. `isActive`
4. window evidence（最低）

### Task 3: 实现矛盾状态升级 (contradiction escalation)

廉价信号矛盾时升级到完整 AX window observation：

- frontmost 改变但 isActive/isHidden 矛盾 → 调用 `ApplicationObservation.snapshot(for:)`
- `.systemUtility` / `.nonStandardWindowed` / `.windowlessOrAccessory` 分类 → 跳过廉价确认直接升级
- 升级后结果作为最终 `ConfirmationResult`

### Task 4: 实现 compatibility lane 确认

`confirmCompatibilityRestore()` 方法：
- 更保守的确认窗口
- 总是包含 escalated observation
- 用于 fast lane 失败后的 fallback

### Task 5: ApplicationObservation 补充 helper

在 `Sources/Quickey/Services/ApplicationObservation.swift` 中：
- 确保 `snapshot(for:)` 方法可被 ObservationBroker 调用
- 如需要，添加 `cheapSnapshot(for:)` 只读取 frontmost + isHidden（无 AX）

### Task 6: 编写测试

**文件:** `Tests/QuickeyTests/ObservationBrokerTests.swift`

必须覆盖：
- [ ] cheap confirmation 成功（frontmost 改变，无 escalation）
- [ ] 75ms 有界轮询行为
- [ ] 矛盾信号自动升级到 window observation
- [ ] 确认超时返回 `confirmed = false`
- [ ] 通知驱动确认在轮询 backoff 前完成
- [ ] `previousBundleIdentifier = nil` 时优雅处理
- [ ] `.systemUtility` 分类直接升级
- [ ] schedule callback 被正确调用

### Task 7: ApplicationObservation 测试补充

**文件:** `Tests/QuickeyTests/ApplicationObservationTests.swift`

- 补充新 helper seam 的测试

## Design Constraints

1. **@MainActor** — ObservationBroker 整体运行在主 actor，因 NSRunningApplication 属性一致性绑定主 run loop
2. **75ms 硬上限** — 不允许无界等待
3. **通知优先** — `NSWorkspace.didActivateApplicationNotification` 为首选信号
4. **不操作 AXUIElement** — 只通过 ApplicationObservation 间接使用
5. **尊重 generation cancellation** — 新 generation 到来时旧确认应安全取消
6. **cache invalidation** — 观察到 previous app 终止时通知 TapContextCache 失效

## Estimated Complexity

- 新文件 2 个（ObservationBroker.swift + ObservationBrokerTests.swift）
- 修改文件 2 个（ApplicationObservation.swift + ApplicationObservationTests.swift）
- 预估 300-400 行实现 + 200-300 行测试
- 建议分 2-3 次迭代实现：Task 1-3 → Task 4-5 → Task 6-7

## Verification

```bash
swift test --filter ObservationBrokerTests
swift test --filter ApplicationObservationTests
swift build
swift build -c release
```

**注意:** 最终 runtime 正确性必须在 macOS 真机验证，Linux 环境只能验证编译和单元测试逻辑。
