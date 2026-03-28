# Loop Job Hardening Design

Date: 2026-03-27

## Problem

当前 loop job 脚本（`scripts/run-loop.sh`、`scripts/start-loop.sh`、`docs/loop-prompt.md`）存在以下问题：

1. **无错误处理**：`while true` 循环无退出码检查、无熔断机制，连续失败会无限消耗 API 额度
2. **无信号处理**：kill 进程时无法优雅停止，可能中断正在进行的 PR 创建
3. **无日志持久化**：仅 stdout 输出到 tmux 缓冲区，无法事后审计
4. **Prompt 缺少安全约束**：无危险操作禁止清单、无分支保护、无复杂 Issue 分轮策略
5. **未使用 `--bare` 模式**：每次迭代加载 hooks/plugins/MCP，增加不必要的启动时间和上下文
6. **路径未加引号**：存在空格路径风险
7. **复杂 Issue 处理不当**：prompt 未体现 Wiki 中的 two-round strategy

## Approach

方案 B：标准加固。修改 3 个文件，覆盖所有已发现问题，不过度工程化。

排除方案：
- 方案 A（最小修复）：不解决错误处理和日志问题
- 方案 C（生产级）：systemd/监控/logrotate 对个人项目来说是 YAGNI

## Design

### 1. `scripts/run-loop.sh` 改造

#### 新增 CLI 参数

| 参数 | 理由 |
|------|------|
| `--bare` | 官方推荐用于脚本调用，跳过 hooks/plugins/MCP 自动发现，加速启动 |
| `--add-dir .` | **关键**：`--bare` 会跳过 CLAUDE.md 自动发现，必须通过 `--add-dir .` 让 claude 加载项目根目录的 CLAUDE.md 和 AGENTS.md |
| `--model opus` | 明确指定模型。使用别名 `opus` 而非固定 model ID（如 `claude-opus-4-6`），跟随 CLI 版本指向最新 Opus 模型。对于 loop job 场景，使用最新模型比可重现性更重要 |

保留不变的参数：`--dangerously-skip-permissions`、`--max-turns 50`、`--output-format text`。

不通过 `--tools`/`--allowedTools`/`--disallowedTools` 限制内置工具集，原因：
- `--bare` 隔离了外部 MCP servers 和 plugins（但不影响内置工具如 Bash、Read、WebFetch 等）
- loop job 可能需要 WebFetch/WebSearch 查询文档和 API 参考
- 安全边界放在 prompt 约束中

**风险声明**：`--dangerously-skip-permissions` 下安全完全依赖 prompt 约束，这是软性的 best-effort 保障，LLM 可能违反。接受这个风险权衡，原因：(1) loop job 运行在个人开发环境而非生产系统；(2) git 提供了回滚能力；(3) PR review 流程提供了人工审核门禁。如果未来需要更强保障，可引入 sandbox 模式或 `--tools` 白名单

#### 错误处理

- `set -euo pipefail`：基础安全设置
- claude 调用使用 `if claude ...; then ... else ... fi` 模式，避免 `set -e` 在非零退出时终止整个脚本
- 退出码检查：claude 进程非零退出时计入失败计数
- 熔断机制：连续失败时采用指数退避策略。初始间隔 30min，每次失败翻倍（30min → 60min → 120min），累计退避超过 4 小时后终止循环。成功一次即重置计数器和间隔。这比简单的"3 次失败即终止"更能应对临时性故障（网络抖动、API 限流）

#### 信号处理

- trap SIGINT/SIGTERM/SIGHUP
- 收到信号后设置 `RUNNING=false`，等当前 claude 进程自然结束后退出循环
- sleep 使用 `sleep $INTERVAL & wait $!` 模式，使信号可以中断 sleep 而非等待 30 分钟

#### 日志持久化

- 脚本启动时 `mkdir -p "$LOG_DIR"` 确保日志目录存在
- 所有输出通过 `2>&1 | stdbuf -oL tee -a` 同时捕获 stdout 和 stderr，`stdbuf -oL` 确保行缓冲，防止 claude 进程崩溃时最后一批输出丢失
- 写入 `logs/loop-YYYY-MM-DD.log`，按日期自动分割
- 保留会话记录（不使用 `--no-session-persistence`），用于审计

### 2. `scripts/start-loop.sh` 改造

- 路径加双引号防止空格问题
- 逻辑保持不变：kill 旧 session + 起新 session
- `tmux kill-session` 发送 SIGHUP，由 `run-loop.sh` 的 trap 处理

### 3. `docs/loop-prompt.md` 改造

#### 新增安全约束段

```
- NEVER push directly to main branch. Always work on feature branches.
- NEVER delete branches unless they have been merged. Clean up merged branches after PR merge.
- NEVER modify CLAUDE.md or AGENTS.md core rules and architecture sections.
- You MAY append new entries to docs/lessons-learned.md when discovering operational insights.
- NEVER run destructive commands (rm -rf, git reset --hard, git clean -f).
- NEVER modify CI/CD workflows or GitHub Actions configs.
- If an issue is ambiguous or requires architectural decisions, add label 'needs-decision' and skip it.
- If an iteration is taking too many turns without progress, stop and create a comment on the issue describing the blocker.
```

#### PR 处理逻辑增强

- 明确合并条件：有 approved reviews 且 CI 通过
- 未 review 的 PR 只修 CI，不合并
- 有 requested changes 的 PR 需处理反馈
- 合并后清理分支

#### Two-round strategy 明确写入

- 简单 Issue（单文件修改、bug fix、文档更新等）：当前迭代直接 TDD 实现
- 复杂 Issue（涉及多文件架构变更、需要新增公共 API、预估超过 200 行改动）：
  - 无 plan：本次迭代只产出 `docs/plans/<topic>.md`，实现留给后续迭代
  - 有 plan：每次迭代只实现 plan 中的一个子任务

#### PR review 来源说明

Loop job 只合并已有人工 review 通过的 PR。Loop job 自己创建的 PR 需要人工 review，在下次迭代时 loop job 会检查其状态：
- 无 review：跳过，处理下一个 issue
- 有 approved review + CI 通过：合并并清理分支
- 有 requested changes：处理反馈

注意：此 PR 合并策略是 loop-prompt.md 独有的运行时约束，不写入 AGENTS.md。AGENTS.md 定义的是项目级架构规范和编辑规则，由 `--add-dir .` 加载后与 prompt 约束互补：AGENTS.md 管"怎么写代码"，prompt 管"怎么选任务和提交"

## Files to modify

| File | Change type |
|------|-------------|
| `scripts/run-loop.sh` | Rewrite |
| `scripts/start-loop.sh` | Minor edit (add quotes) |
| `docs/loop-prompt.md` | Rewrite |
| `logs/` | New directory (created by script, add to .gitignore) |
| `.gitignore` | Append `logs/` entry |

## Out of scope

- Systemd service 替代 tmux
- 日志轮转（logrotate）
- 监控集成
- Dynamic Issue Triage 配置化（Wiki 提到但当前 prompt 直接内联优先级规则足够）
- 成本控制（`--max-budget-usd`）：指数退避熔断已防止连续失败场景的 API 消耗。`--max-turns 50` 限制了迭代轮次但不直接限制 token 消耗（单个复杂 turn 可能消耗大量 token）。接受这个风险，因为用户明确不要求成本控制，且 Opus 的 token 消耗模式在正常迭代中是可预期的
- 工具白名单/黑名单
- INTERVAL 参数化：当前 30 分钟硬编码满足需求，脚本顶部常量易于修改
