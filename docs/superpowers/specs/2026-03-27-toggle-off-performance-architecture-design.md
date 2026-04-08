# Toggle-off Performance Architecture Design

> Superseded for implementation: on 2026-04-08 Quickey removed the restore-first / fast-lane / compatibility-lane toggle-off architecture in favor of a single direct-hide path (`privateState` + `Cmd+H` + async hide confirmation). Keep this document only as historical design context.

**Date:** 2026-03-27
**Branch:** fix/non-hyper-shortcut-toggle
**Issue:** `#86` perf: Toggle-off 响应速度优化
**Related PR:** `#85` fix: 修复非 Hyper Key 快捷键 toggle-off 失效及修饰键归一化不对称
**Scope:** 为 Quickey 的快捷键切换路径设计长期性能架构，重点优化正常 app 的 toggle-off 体感，同时保留系统/怪异 app 的兼容性与稳定性

## Overview

Issue `#86` 不是在解决“功能错误”，而是在解决“功能已经正确，但用户体感仍不够快”的问题。

`PR #85` 已经把两个 correctness 问题拉回正轨：

- 非 Hyper Key 快捷键的修饰键匹配做了归一化，不再被 `numericPad`、`help` 等额外位干扰
- toggle-off 不再依赖从 `LSUIElement` app 发起时不可靠的 `NSRunningApplication.hide()`，而是改为 AX hide + 三层 SkyLight restore

但当前 toggle-off 热路径仍然偏重：

1. 在按键触发后同步执行 AX hide
2. 同步查询 previous app 的窗口信息
3. 同步执行三层 SkyLight restore
4. 再同步做 post-restore observation
5. 同时背负 400ms per-bundle cooldown 和 200ms debounce 这两层安全网

这条路径“能用”，但还不像一个以速度为卖点的快捷键工具。

本设计的核心目标是把 Quickey 的长期架构从“主 actor 上同步串联重 IPC 操作”重构为“轻热路径入口 + 可缓存上下文 + 专用执行流水线 + 事后确认”。正常 app 应默认走最快路径，系统或怪异 app 保留兼容路径，而不是让所有 app 都被最保守的策略拖慢。

## Goals

- 让正常 app 的 toggle-off 默认接近即时体感，而不是依赖 hide-first 的保守串行路径
- 把按键入口、状态机、上下文缓存、系统命令执行、结果确认拆成清晰单元
- 让重 IPC 的 AX / SkyLight / NSWorkspace 调用脱离主 actor 热路径
- 保留现有稳定性语义：请求激活或恢复不等于切换成功，必须做 post-confirmation
- 让正常 app 和系统/怪异 app 走不同的性能层级，而不是统一走最慢路径
- 为后续阈值调优提供可测量的延迟和命中率数据
- 把这项工作定义成明确的长期路线图，而不是一次性 patch

## Non-Goals

- 不把 Quickey 改造成窗口优先的 AltTab 替代品
- 不移除 SkyLight 私有 API 依赖
- 不放弃 current frontmost truth、stable-state gating、ACTIVE_UNTRACKED 等已验证的正确性约束
- 不在本轮设计中承诺所有系统 app 都能进入与正常 app 完全相同的最快路径
- 不在 Linux 上宣称 macOS 运行时正确性；最终体验结论必须来自 macOS 真机验证

## Current Context

- `AppSwitcher` 当前同时承担状态机、前台判断、AX/SkyLight 命令执行、确认与日志职责
- toggle-off 的当前主路径默认是：
  - AX hide target
  - 为 previous app 查询窗口
  - 三层 SkyLight restore previous app
  - 再观察 target 是否仍 frontmost
- `ToggleSessionCoordinator` 已经是稳定状态的 durable source of truth，`previousBundle` 也已迁入 session ownership
- `ApplicationObservation` 已能提供 `frontmostApplication`、`isActive`、`isHidden`、窗口证据与 app classification
- `EventTapManager` 已经在 callback 层过滤 `kCGKeyboardEventAutorepeat`，200ms debounce 只是后置 safety net
- `FrontmostApplicationTracker` 仍然偏向“轻量快照 + restore helper”，还不是为快路径预热而设计的上下文缓存

这意味着 Quickey 当前的 correctness 基线是好的，但性能架构仍是“同步命令式”的，而不是“预热上下文 + 分层执行”的。

## Official API Semantics That Constrain The Design

Apple 当前文档和本仓库既有验证共同约束了设计方向：

- `NSWorkspace.frontmostApplication` 返回“接收 key events 的前台 app”，这是 app-level toggle 语义的主要真值
- `NSRunningApplication.isActive` 表示 app 当前是否 frontmost，但在过渡态或怪异 app 行为下只能作为辅助信号
- `NSApplication.activate()` 与 `NSRunningApplication.activate(options:)` 都只是 request / attempt，不保证真正完成激活
- `NSApplication.yieldActivation(to:)` 是 cooperative activation，要求当前前台 app 主动配合；Quickey 这种 `LSUIElement` 工具无法依赖它
- `NSRunningApplication.hide()` 也是 attempt，并且对某些 accessory/LSUIElement 触发链路并不可靠
- `CGEventField.keyboardEventAutorepeat` 的官方语义是：非 0 表示 autorepeat，因此应在事件层过滤，而不是把 repeat 防护主要压给 debounce
- `NSApplication.ActivationOptions.activateIgnoringOtherApps` 已废弃；它既不是长期可依赖路径，也不符合现代 macOS 的最佳实践

这些约束意味着：

1. Quickey 不能把“调用返回 true”当成切换成功。
2. Quickey 不能把“最慢但最保守”的路径设为所有 app 的默认路径。
3. Quickey 不能把主 actor 继续当作所有重 IPC 的串行执行器。

## External Best-Practice References

### Apple 官方语义

- `frontmostApplication` 是接收 key events 的前台 app
- `activate()` / `activate(options:)` 只是 request / attempt
- `yieldActivation(to:)` 是 cooperative 模型，不适合 Quickey 这类不能控制其他 app 的场景
- `keyboardEventAutorepeat` 必须在最外层先过滤

### AltTab

AltTab 不是 toggle 工具，但它在两个方面很值得参考：

- 把 AX 命令与窗口聚焦命令放进专用后台队列，而不是塞到 UI 主线程热路径
- 对窗口恢复使用分层命令：SkyLight front process + makeKeyWindow + AX raise

Quickey 不应照搬 AltTab 的窗口优先产品模型，但应借鉴它的“命令执行脱离主线程热路径”这一结构性做法。

### skhd / Hammerspoon / KeyboardShortcuts

这三类成熟快捷键工具都体现出同一个原则：快捷键匹配必须只比较受控的修饰键集合，而不是盲信原始 modifier mask。

Quickey 在 `PR #85` 已经开始对齐这一点；本设计延续同样的原则到切换执行路径：只在最热路径保留真正必须存在的工作，把噪声和阻塞操作移走。

## Product Decisions

| Topic | Decision |
|------|----------|
| Product semantics | 继续保持 app-level toggle，而不是转向 window-first 产品 |
| Primary truth source | 继续以 `NSWorkspace.frontmostApplication` 为前台真值 |
| Normal apps | 默认走最快路径，目标是避免每次 toggle-off 都先 hide-first |
| System / weird apps | 保留兼容路径，允许更保守的恢复与确认 |
| Safety model | “请求切换”与“切换确认”彻底分离，repeat 防护优先靠 autorepeat filter 和 generation 模型，而不是统一的长冷却 |
| Rollout style | 做长期路线图，分里程碑迁移，不一次性切全量 |

## Performance Targets

这份设计把“更快”定义成可测量预算，而不是主观描述。

- 计时起点：`TriggerIngress` 接受一次已匹配快捷键的时刻
- 计时终点：`ObservationBroker` 首次确认 target 已不再 frontmost，且本次 restore 满足 lane 对应的确认标准
- `regularWindowed` app 的 `fast lane` 预算：
  - 中位延迟目标：`<= 150ms`
  - P95 目标：`<= 250ms`
- `compatibility lane` 预算：
  - 中位延迟目标：`<= 350ms`
  - P95 目标：`<= 600ms`
- 单次 toggle attempt 的主 actor 决策预算：`<= 5ms`

这些数字是路线图预算，不是 Linux/CI 可直接证明的发布声明；最终是否达标只能通过 macOS 真机验证矩阵确认。

## Approaches Considered

### 1. 继续局部优化现有 `AppSwitcher`

只做上下文缓存、少量阈值调优和一些同步查询移除，保留当前主 actor 上的同步命令式实现。

Pros:

- 风险最低
- 可以较快拿到部分收益

Cons:

- 主 actor 上的重 IPC 仍然是核心瓶颈
- 结构债继续累积
- 后续大概率还要再重构一次

### 2. 分层快速路径架构

引入 `TapContextCache` 和专用执行器，让正常 app 默认走 direct-restore-first，兼容路径只服务怪异 app 或 fast-lane miss。

Pros:

- 兼顾长期收益与可控迁移
- 保留现有状态机语义
- 性能收益明显且风险可管理

Cons:

- 需要中等结构调整
- 新旧路径并存期间需要更强测试与埋点

### 3. 完整异步执行模型与长期路线图

把按键入口、状态机、上下文缓存、系统命令执行、结果确认全部拆开，形成可观测、可取消、可分层降级的流水线，并以多里程碑路线图逐步落地。

Pros:

- 长期收益最高
- 最符合“快捷键工具必须快”的产品目标
- 最能避免未来在 `AppSwitcher` 中继续堆补丁

Cons:

- 设计与验证成本最高
- 需要更明确的分期与回滚策略

## Recommendation

采用 approach 3，但按可控的里程碑顺序落地。

这不是“一次性重写全部切换逻辑”，而是把最终架构先设计完整，再通过多阶段迁移把风险摊薄。只有这样，Quickey 才能同时满足：

- 快捷键热路径足够轻
- 正常 app 体感足够快
- 系统/怪异 app 仍有保守恢复能力
- 状态机不会因为性能优化而丢掉 correctness

## Design

### 1. Runtime Architecture

长期目标架构拆成五个单元：

#### `TriggerIngress`

职责：

- 处理 event tap 输入
- 过滤 autorepeat
- 进行 modifier normalization
- O(1) 匹配 shortcut
- 发出一次结构化 toggle request

约束：

- 不执行 AX / SkyLight / NSWorkspace 打开等重操作
- 不在 callback-safe 路径里做阻塞 I/O

#### `ToggleRuntime`

职责：

- 作为主 actor 上的状态机协调者
- 接收 toggle request
- 生成 generation / attempt id
- 选择 fast lane 或 compatibility lane
- 消费命令执行结果并决定下一步
- 决定何时 promotion、fallback、degrade、reset

Runtime phase：

- `idle`
- `activating`
- `activeStable`
- `deactivating`
- `restoring`
- `recovering`
- `degraded`

`ToggleRuntime` 不直接做重 IPC，只做决策与状态推进。

#### `TapContextCache`

职责：

- 在 toggle-on 被接受时预热后续 toggle-off 最需要的上下文
- 存储每个 target 的最近一次可恢复上下文
- 管理正常 app 与降级状态的短期记忆

Cache fields：

- `targetBundleIdentifier`
- `targetClassification`
- `previousBundleIdentifier`
- `previousPID`
- `previousPSNHint`
- `previousWindowIDHint`
- `previousBundleURL`
- `capturedAt`
- `lastConfirmedFrontmostBundle`
- `fastLaneEligibility`
- `recentFastLaneMissCount`
- `fastLaneMissWindowStart`
- `temporaryCompatibilityUntil`

设计要求：

- `TapContextCache` 本体留在 `@MainActor`
- `ToggleRuntime` 是 cache 的唯一写入协调者；`ObservationBroker` 只在主 actor 上提供用于失效或降级判断的证据
- `ActivationPipeline` 不直接持有或读取 cache；主 actor 必须先把所需字段提取为不可变 `RestoreContext` value type 后再传入后台执行器
- `ToggleSessionCoordinator.previousBundle` 继续是 restore target 的 durable source of truth
- `TapContextCache.previousBundleIdentifier` 只是为 fast lane 服务的 read-optimized mirror；一旦两者不一致，必须以 coordinator 为准并刷新或清空 cache
- `PSN` 和 `windowID` 都只能视为 hint，而不是永久真值
- 任何 cached process identity 都必须在使用前验证 pid/bundle 仍然匹配
- 任何 cached `windowID` 都必须在使用前验证仍归属于同一 pid / bundle 的可用窗口
- app termination、frontmost change、session reset 都要驱动缓存失效或降级
- `temporaryCompatibilityUntil` 只存在于运行时内存，不跨 app 重启持久化

`RestoreContext` 至少应包含：

- `targetBundleIdentifier`
- `previousBundleIdentifier`
- `previousPID`
- `previousPSNHint`
- `previousWindowIDHint`
- `previousBundleURL`
- `capturedAt`
- `generation`

#### `ActivationPipeline`

职责：

- 承接所有可能阻塞的 AX / SkyLight / NSWorkspace 命令
- 通过结构化命令执行而不是暴露零散系统调用
- 把执行结果作为 value type 回传给 `ToggleRuntime`

Command set：

- `prepareRestoreContext`
- `activateTarget`
- `restorePreviousFast`
- `restorePreviousCompatible`
- `hideTarget`
- `raiseWindow`
- `confirmRestorePreconditions`
- `clearAttemptArtifacts`

Result set：

- `accepted`
- `completed`
- `needsFallback(reason)`
- `degraded(reason)`
- `cancelledByNewerGeneration`

Timeout budget：

- `prepareRestoreContext`: `<= 40ms`
  - 超时后不直接判失败；仅降低 fast-lane 资格，允许继续走 compatibility lane
- `restorePreviousFast`: `<= 120ms`
  - 超时后返回 `needsFallback(timeout_restore_fast)`
- `hideTarget`: `<= 80ms`
  - 超时后返回 `needsFallback(timeout_hide_target)`
- `restorePreviousCompatible`: `<= 180ms`
  - 超时后若已用尽 attempt budget，则返回 `degraded(timeout_restore_compatible)`；否则由 `ToggleRuntime` 决定是否进入最后一次兼容补救
- `raiseWindow`: `<= 80ms`
  - 超时后不做额外第三轮 mutating retry，直接进入确认或 degraded

这些预算是设计预算，M1 建立真实基线后可以调整，但 implementation plan 必须为每类命令定义明确 timeout 行为，不能让命令无限挂起。

#### `ObservationBroker`

职责：

- 统一封装 post-action observation
- 输出是否真正达到 `frontmost`, `not hidden`, `window evidence coherent`
- 为 lane routing 和 degraded 判定提供统一证据

真值优先级保持不变：

1. `frontmostApplication`
2. `targetIsHidden`
3. `isActive`
4. `visible/focused/main window evidence`
5. app classification

### 2. Actor And Thread Boundaries

Quickey 现有架构已经明确：`NSRunningApplication` 的时间变化属性与主 run loop 一致性绑定，因此 observation 和状态机仍应留在 `@MainActor`。

这次性能架构重构不能粗暴把所有逻辑丢到后台线程；正确的边界是：

- `ToggleRuntime` 与 `ObservationBroker` 继续留在 `@MainActor`
- `ActivationPipeline` 只接收已经从主 actor 提取好的 primitive values
- 后台执行器不直接读取 `NSRunningApplication.isActive`、`isHidden`、`frontmostApplication` 这类时间敏感属性
- 后台执行器只做：
  - `pid` / `PSN` / `CGWindowID` 驱动的 SkyLight 调用
  - `AXUIElementCreateApplication(pid)` 驱动的 AX set / raise
  - 基于 `bundleURL` 的 `NSWorkspace` reopen 请求

Execution model：

- 使用一个全局串行 activation command lane，确保全局前台切换不会互相打架
- 使用 generation cancellation，保证后来的请求能让旧请求在确认前失效

这比“每个 bundle 各自并行执行”更符合前台 app 是全局资源这一事实。

`TapContextCache` 的 actor 归属也遵循同一原则：

- cache 保持在主 actor
- 任何后台命令只消费主 actor 提前提取的不可变 `RestoreContext`
- 后台命令返回后，由主 actor 决定是否更新 cache、session 和降级状态

### 3. TapContextCache Design

`TapContextCache` 是这次设计的核心，因为它决定 Quickey 是否能把 toggle-off 从“临时抓资料再执行”升级为“直接消费已准备好的恢复上下文”。

#### On Toggle-on Acceptance

当 target app 的 toggle-on 被接受后，主 actor 立即做三件事：

1. 记录 session-owned `previousBundle`
2. 抓取 previous app 的 restore context hint
3. 为 target 记录本次 classification 与最近确认信息

Prepare 策略：

- previous app 的 `bundleIdentifier` 与 `pid` 立即记录
- `PSN` 作为可选 hint 预取
- `windowID` 作为可选 hint 预取，不要求每次都成功
- 如果 previous app 没有可靠窗口，则 fast lane 资格下降，但不直接报错

#### Cache Validity Rules

- previous app 终止：上下文立即失效
- target app 被外部激活/切走：保留 cache，但降低 fast lane 置信度
- fast lane 连续 miss 达到阈值：进入 `temporaryCompatibilityUntil`
- 成功的 compatibility lane 结束后：允许重新评估 fast lane 资格，而不是永久拉黑 bundle

这样做可以避免“某个 app 某次失败后永远只能走慢路径”。

### 4. Lane Selection

每次 toggle attempt 动态选择 lane，而不是给某个 bundle 永久贴标签。

#### Fast Lane Eligibility

满足以下条件时优先走 fast lane：

- target classification 是 `regularWindowed`
- session 当前处于 `activeStable`
- `TapContextCache` 中存在完整或足够完整的 previous context
- bundle 未处于 temporary compatibility window
- 最近没有连续 fast-lane miss

#### Fast Lane Behavior

正常 app 的 toggle-off 默认流程改为：

1. 直接 restore previous app
2. 先做廉价确认，判断 target 是否已不再 frontmost
3. 只有廉价确认结果矛盾时，才升级到昂贵 observation
4. 若确认通过，则完成本次 toggle-off
5. 若确认失败，再自动升级到 compatibility lane

关键变化：

- 对正常 app，`hideTarget` 不再是默认第一步
- `hideTarget` 降级为 fallback，而不是主路径

这正是本设计最重要的用户体验收益：减少一次默认 IPC roundtrip。

#### Compatibility Lane

以下场景默认或升级到 compatibility lane：

- `systemUtility`
- `nonStandardWindowed`
- `windowlessOrAccessory`
- fast lane confirmation miss
- cached context 不完整或显著失真
- 最近出现多次 restore contradiction

兼容路径可执行更保守的顺序：

1. `hideTarget`
2. `restorePreviousCompatible`
3. `raiseWindow` / `makeKeyWindow`
4. 更长一点的确认窗口
5. 必要时记一次 degrade / temporary compatibility hit

#### Temporary Compatibility Quarantine

为避免怪异 app 每次都先 miss fast lane 再回退，设计引入 bundle 级短期 quarantine：

- 同一 bundle 在 10 分钟窗口内发生 3 次 fast-lane miss
- 则该 bundle 进入 5 分钟的 `temporaryCompatibilityUntil`
- quarantine 期间默认跳过 fast lane，直接进入 compatibility lane
- quarantine 为运行时内存状态，不跨重启保留

这个规则的目标不是“惩罚失败”，而是避免已知怪异 app 反复支付一次无意义的 fast-lane miss 成本。

这些阈值是初始设计值，不是最终发布常量；在 M1 observability 建立真实 miss 分布后，必须基于数据重新校准，再决定默认 rollout 值。

### 5. Observation Strategy

`ObservationBroker` 必须采用“廉价确认优先，昂贵确认按需升级”的策略。

#### Cheap Confirmation

优先使用：

- `NSWorkspace.frontmostApplication`
- `targetIsHidden`
- session 当前 phase
- 若 previous bundle 可知，则确认前台 bundle 是否已经离开 target

这一步不做完整 AX window 枚举。

Cheap confirmation 不是“只读一次立即结束”，而是一个有界短窗口：

- 命令返回后立即做第一次读取
- 若第一次读取不够确认，则在 fast-lane confirmation window 内继续等待最多 `75ms`
- 这 `75ms` 可由通知驱动提前结束；若需要回退检查，则使用短间隔重读 `frontmostApplication`
- 若 `75ms` 结束时仍无法确认，则进入 escalated confirmation 或 compatibility lane，而不是继续等待

#### Escalated Confirmation

只有在以下情况才做昂贵 observation：

- cheap confirmation 结果矛盾
- bundle 当前走 compatibility lane
- target classification 本来就不是 `regularWindowed`
- fast-lane success 需要更高置信度才能 promotion

昂贵 observation 可以包括：

- `isActive`
- `visibleWindowCount`
- `hasFocusedWindow`
- `hasMainWindow`
- 必要时对 target 或 previous app 做更完整的 AX window evidence 查询

设计原则是：确认本身不能重新成为新的性能瓶颈。

#### Primary Confirmation Mechanism

确认机制的首选方案不是无限轮询，而是“通知优先，短窗口回退轮询”：

- 主方案：在 `@MainActor` 上消费 `NSWorkspace.didActivateApplicationNotification`，因为仓库现有 runtime 已经依赖该通知做 session invalidation
- 辅助方案：在 `75ms` cheap-confirmation window 内，对 `frontmostApplication` 做短间隔回退检查，用来覆盖通知延迟或时序缺口
- 不使用无界轮询；回退检查必须绑定 attempt budget 和 confirmation window

这使确认延迟既能受控，又不必把所有成功路径都变成持续轮询。

### 6. Command Execution Model

`ActivationPipeline` 不是“随便丢任务到后台队列”，而是一个结构化流水线。

#### Two Command Lanes

不是所有命令都应进入同一条串行队列。设计上拆成两类：

1. `contextPreparationLane`
   - 只做只读预热或 hint 计算
   - 例如：预取 previous app 的 `PSN` / candidate `windowID`
   - 使用有界并发，初版设计为低并发队列（建议 `maxConcurrentOperationCount = 2`），避免预热任务在压力下无限堆积
   - 不得修改全局前台状态

2. `activationCommandLane`
   - 只承载会改变前台状态或窗口状态的命令
   - 例如：`restorePreviousFast`、`restorePreviousCompatible`、`hideTarget`、`raiseWindow`
   - 必须全局串行

#### Global Serialization For Mutating Commands

由于前台切换是全局资源，所有 mutating command 都进入同一条全局串行命令 lane。这样可以避免：

- A 的 restore 和 B 的 activate 互相覆盖
- 不同 bundle 命令并行导致前台结果不可预测

#### Generation Cancellation

每次 toggle request 都携带 generation。

规则：

- 新 generation 到来后，旧 generation 后续的 confirm / fallback 结果只能返回 `cancelledByNewerGeneration`
- 任何 post-command callback 进入主 actor 时都必须先验证 generation 是否仍当前有效

这样可以把一部分今天靠统一 cooldown 硬挡的问题转为更精准的逻辑取消。

#### Race Handling Rules

必须在设计层面写死以下两个竞态：

1. 同一 bundle 在 restore 尚未确认前再次被按下
   - 新 generation 抢占旧 generation
   - 旧 generation 不允许再触发新的 mutating command
   - 旧 generation 若已经造成部分副作用，只允许做本地清理，不允许再推进 session 状态

2. `A` toggle-off 恢复到 `B` 后，用户立刻按 `B`
   - 如果 `B` 的恢复结果已被确认，`ToggleRuntime` 优先尝试恢复或重建 `B` 的 stable runtime
   - 如果 `B` 的上下文无法可靠恢复，则退回 `ACTIVE_UNTRACKED` 风格的保守处理，不猜测 `B` 的 previous app

#### Runtime Invariants

以下 invariant 不允许被性能优化破坏：

- 不允许在 pending / activating 状态下直接 toggle-off
- `previousBundle` 绝不能等于 target bundle；若检测到自引用，必须清空并记录诊断
- `ACTIVE_UNTRACKED` 路径必须继续保留，作为外部激活或恢复后缺失 tracking state 的兜底
- 没有 `frontmostApplication` 真值确认时，不允许 promotion 到稳定激活
- generation 被新请求抢占后，旧 generation 不允许再推进 session phase

#### Failure Ladder

建议失败回退分三级：

1. `Fast confirm miss`
   - direct restore 后短确认窗口未通过
   - 行为：自动升级 compatibility lane

2. `Compatibility recoverable`
   - 恢复仍矛盾，但 hide/raise/makeKeyWindow 后可继续尝试
   - 行为：仍视为同一次 attempt，不要求用户多按一次

3. `Degraded`
   - 连续失败或上下文严重失真
   - 行为：记录诊断、暂时降级 bundle，后续一段时间默认走 compatibility lane

#### Attempt Budget

单次快捷键触发最多只允许经历以下升级链：

`fast lane -> compatibility lane -> degraded`

约束：

- 单次 attempt 最多只做一次 fast-lane mutating command
- 单次 attempt 最多只升级一次 compatibility lane
- compatibility lane 内最多只允许一次 `hideTarget` 和一次 `raiseWindow` 补救
- 若 compatibility lane 仍无法确认，则直接进入 degraded，不做第三轮 frontmost-mutating 重试

### 7. Cooldown And Debounce Policy

当前 400ms cooldown 与 200ms debounce 是在旧同步架构下形成的保守安全网。

长期目标不是立即把它们删除，而是改变它们的职责：

- autorepeat filter 继续作为 Layer 1 主防线
- debounce 只保护“极短时间内同 key 的重复递送”
- cooldown 不再作为所有成功 toggle-off 的默认延迟成本
- generation cancellation 与 global serial lane 成为新的主要重入保护机制

因此本设计明确要求：

- 不在 M1/M2 阶段贸然降低阈值
- 只有在 new pipeline 与 fast lane 稳定后，再进入阈值复调阶段

#### Coexistence Rules

在 generation cancellation 与现有 cooldown / debounce 并存阶段，优先级规则如下：

- 若 cooldown 或 debounce 在入口层就阻止本次触发，则该请求不会被接受，也不会分配新 generation
- generation cancellation 只作用于“已经被接受并进入 runtime”的请求
- 在 M1/M2 阶段，legacy cooldown 仍然是入口保护；new runtime 只对已接受请求做取消与抢占
- 只有在 M3 以后，且数据证明 new runtime 能稳定承担主要重入保护时，才允许进一步缩小 cooldown 的职责范围

### 8. Observability And Metrics

这项工作如果没有可比较数据，最后只会退化成“感觉快了一点”。

需要新增的结构化指标包括：

- `attemptId`
- `generation`
- `lane=fast|compatibility`
- `phase`
- `elapsedMs`
- `executorMs`
- `confirmationMs`
- `mainActorDecisionMs`
- `fastLaneHit=true|false`
- `fastLaneMissReason`
- `fallbackCount`
- `temporaryCompatibilityHit`
- `cheapConfirmation=true|false`
- `escalatedConfirmation=true|false`
- `queueWaitMs`
- `mutatingCommandCount`
- `attemptBudgetExceeded=true|false`
- `axHideErrorCode`
- `restoreErrorCode`
- `cacheInvalidationReason`

现有 `DiagnosticLog` 足够作为主记录载体；不需要把同步日志写回热路径，只需保持结构化 `key=value` 输出即可。

### 9. Testing Strategy

#### Unit Tests

重点覆盖：

- lane 选择规则
- context cache 生命周期
- generation cancellation
- temporary compatibility 窗口进入/退出
- fast confirm miss 自动升级 compatibility
- cached `windowID` / `pid` 身份校验失败时不会继续使用失真 hint
- attempt budget 用尽后直接 degraded

#### Integration Tests

用 fake clients 覆盖完整流水线：

- `restorePreviousFast -> confirm success`
- `restorePreviousFast -> confirm miss -> compatibility success`
- `activate A -> restore B -> press B immediately`
- `new generation cancels old generation`
- `three fast-lane misses for one bundle -> temporary compatibility quarantine`
- `cheap confirmation succeeds without escalated AX observation`
- `cheap confirmation contradicts -> escalated confirmation`
- `shadow mode logs fast-lane decision without executing mutating command`
- `command timeout maps to fallback or degraded exactly as designed`
- `previous app quits between toggle-on and toggle-off -> cache invalidation + compatibility fallback`

#### macOS Manual Validation

必须在 macOS 真机验证：

- 正常 app：Safari、Finder、Terminal
- 系统/怪异 app：Home、System Settings、Clock
- hidden / minimized / no-window 场景
- 快速重复按同一快捷键
- A restore 到 B 后立即再按 B

Linux 或 CI 只能验证逻辑与编译，不能宣称最终体感或系统 API 行为正确。

## Roadmap

### Milestone 1: Observability First

目标：

- 不改变行为
- 把现有 toggle-on / toggle-off 路径分阶段埋点补齐

退出标准：

- 能看见 current path 的主要耗时分布
- 能知道 normal app vs weird app 的慢点主要落在哪一段

### Milestone 2: Context Cache + Executor Scaffold

目标：

- 引入 `TapContextCache`
- 引入 `ActivationPipeline`
- 引入双 lane 执行模型：`contextPreparationLane` 与 `activationCommandLane`
- 保留旧路径为 fallback
- 增加全局 kill switch，让新 pipeline 可按 bundle 或全局关闭

退出标准：

- 新旧路径可并存
- prepare context、restore command、confirm result 已能通过新模型串起来
- kill switch 可把默认行为退回 compatibility-first 或 legacy path

### Milestone 2.5: Shadow Mode

目标：

- 保持 legacy path 继续承担真实切换
- 新 runtime 在不执行 mutating command 的前提下，计算 lane 决策、预算消耗、确认升级路径
- 对比“legacy 实际发生了什么”与“new runtime 本应怎么做”

退出标准：

- shadow mode 的决策与 legacy 结果能够稳定对齐
- 已能识别哪些 bundle 会稳定命中 fast lane，哪些 bundle 应长期留在 compatibility lane
- 关键竞态场景在 shadow mode 日志中可复盘
- 对命名的 normal apps，必须验证 `restorePreviousFast` 在不执行 `hideTarget` 的前提下，能可靠地让 target 不再 frontmost

### Milestone 3: Fast Lane Default For Normal Apps

目标：

- 正常 app 默认 direct-restore-first
- compatibility lane 仅服务系统/怪异 app 和 fast-lane miss
- 落实 cheap-confirmation-first
- 落实 temporary compatibility quarantine

退出标准：

- 正常 app toggle-off 默认不再依赖 hide-first
- fast lane 命中率、升级率、成功率可测
- `regularWindowed` app 的中位延迟与 P95 达到或接近性能预算
- 命名的 macOS 验证通过：Safari、Finder、Terminal 无回归，Home 与 System Settings 保持兼容路径正确性

### Milestone 4: Threshold Retuning And Cleanup

目标：

- 重新评估 debounce / cooldown
- 清理旧同步路径遗留代码
- 把 policy 收敛到新架构

退出标准：

- safety nets 不再成为常态延迟来源
- 新架构成为唯一默认路径

## Acceptance Criteria

- `[M2]` 主 actor 不再承担 AX / SkyLight 热路径的同步串行执行
- `[M2]` 只读预热与 mutating command 在执行模型上被明确分离
- `[M2]` 每类 command 都有明确 timeout budget 和 timeout 后语义
- `[M2]` runtime invariants 在实现与测试层都有对应保护
- `[M2]` 路线图包含 kill switch，可在迁移期快速退回 compatibility-first 或 legacy path
- `[M2.5]` shadow mode 作为默认切换前的中间阶段存在，并能证明 lane 决策与 legacy 结果基本一致
- `[M3]` 正常 app 的 toggle-off 默认走 fast lane，不再一律 hide-first
- `[M3]` fast lane miss 时，Quickey 自动升级 compatibility lane，而不是要求用户补按第二次
- `[M3]` cheap confirmation 成为默认确认策略，昂贵 AX/window observation 只在矛盾或 compatibility lane 中升级
- `[M3]` 系统/怪异 app 仍保留兼容与降级恢复能力
- `[M3]` bundle 级 temporary compatibility quarantine 生效，且不跨重启持久化
- `[M3]` 单次 attempt 遵守 `fast -> compatibility -> degraded` 的升级预算，不允许无限补救
- `[M4]` 阈值调优建立在新 pipeline 和真实度量数据之上，而不是拍脑袋改数字
- `[Validation]` 最终体验结论通过 macOS 真机验证获得，而不是 Linux-only 推断

## Risks And Mitigations

### 风险：后台执行器与主 actor 观察割裂

缓解：

- 明确只把 primitive values 带入后台执行器
- 所有时间敏感 observation 仍回主 actor 读取

### 风险：cache 失真导致快路径误判

缓解：

- 把 `PSN`、`windowID` 视为 hint
- 使用前重新验证 pid/bundle 仍匹配
- 使用前重新验证 cached `windowID` 仍归属原 process identity
- fast-lane miss 自动退回 compatibility lane
- miss 达阈值后启用 temporary compatibility quarantine

### 风险：PSN hint 的平台长期风险

缓解：

- 把 `PSN` 明确视为可选 hint，而不是设计前提
- 若 `PSN` 不可用或未来平台行为变化，runtime 必须退化到不依赖 PSN hint 的 compatibility 路径
- 不允许把 fast lane 的正确性绑定到“PSN 一定可预取且可复用”这一假设上

### 风险：迁移期新旧路径并存导致复杂度上升

缓解：

- 通过里程碑推进
- 每个阶段都定义退出标准与可回滚边界
- 通过 kill switch 保持快速回退能力

### 风险：确认逻辑自己变成性能瓶颈

缓解：

- cheap confirmation 默认优先
- 只有矛盾或兼容路径才升级到昂贵 observation
- 把 escalated confirmation 的命中率纳入结构化指标

### 风险：新 runtime 决策与 legacy 行为偏离

缓解：

- 在默认切换前增加 shadow mode
- 用 shadow mode 比较 lane 决策、fallback 触发点和最终确认结果
- 只在对齐度足够后才让 fast lane 成为默认

## Implementation Notes For Planning

- 不要把整个 `AppSwitcher` 一次性重写；优先把职责剥离，再逐步切默认路径
- `ToggleRuntime` 与 `ObservationBroker` 应继续尊重 `@MainActor` 约束
- `ActivationPipeline` 的第一版就应设计成结构化命令接口，而不是散落的 helper methods
- `ActivationPipeline` 的第一版就应把 timeout budget 和 timeout 语义一起落地
- `TapContextCache` 要从一开始就明确“hint 不是 truth”
- M1 的埋点是后续一切性能判断的前提，不应跳过
- Implementation plan 应按里程碑顺序推进，并在每个 milestone 结束后设置 review checkpoint；不要把整个路线图当成一次性落地任务
- 实现阶段应优先让 kill switch 与指标先落地，再切换默认 fast lane
- implementation plan 应把 runtime invariants 单列成一个检查清单，并给每条 invariant 对应测试
