# Loop Job Guide

How to run automated Claude Code sessions for recurring project work using `/loop`. See also [Wiki: Loop Job Configuration](https://github.com/xrf9268-hue/Quickey/wiki/Loop-Job-Configuration).

## Quick Start

In a Claude Code interactive session, run:

```
/loop 30m Follow the instructions in docs/loop-prompt.md
```

This schedules a recurring task that fires every 30 minutes. Each iteration follows the workflow defined in `docs/loop-prompt.md`.

## How /loop Works

`/loop` is a bundled Claude Code skill that creates a cron-based scheduled task within the current session.

| Property | Value |
|----------|-------|
| Runs in | Current Claude Code session (interactive mode) |
| Commands and plugins | Inherits the current session's built-in commands, skills, and loaded plugins |
| Minimum interval | 1 minute |
| Priority | Low — runs between your turns, never interrupts |
| Persistence | Session-scoped — gone when you exit |
| Auto-expiry | 3 days after creation |
| Max concurrent tasks | 50 |

## Preflight and Prerequisites

Before relying on the loop job:

- Confirm Claude Code is new enough: `claude --version`
- Confirm GitHub auth works: `gh auth status`
- Confirm the repo starts in a safe git state: `git status --short --branch`
- Confirm review tooling is actually available in the session:
  - `/plugin` to inspect installed plugins
  - `/reload-plugins` after installing or enabling anything
  - `/code-review`, `/codex:review`, and `/simplify` should be treated as optional gates that must be present to run, not assumed silently

The v2 prompt now performs this preflight inside each iteration as well, so missing tools become an explicit degraded state instead of an implicit pass.

### Interval syntax

```
/loop 30m <prompt>              # leading interval
/loop <prompt> every 2 hours    # trailing interval
/loop <prompt>                  # defaults to 10 minutes
```

Supported units: `s` (seconds, rounded to nearest minute), `m` (minutes), `h` (hours), `d` (days).

### Skills in /loop

`/loop` runs prompts in interactive mode, so built-in skills and any already-loaded plugin commands work natively:

```
/loop 20m /code-review          # review PRs every 20 minutes
/loop 1h /simplify              # simplify code every hour
```

The prompt in `docs/loop-prompt.md` uses `/simplify` when available for pre-commit code quality, `/code-review` ([code-review plugin](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/code-review); posts findings as PR comments), and `/codex:review --base main --background` ([Codex Plugin CC](https://github.com/openai/codex-plugin-cc); session-local, retrieve with `/codex:status` + `/codex:result`). If any of those commands are unavailable in the current session, the prompt records the missing gate and defers merge rather than silently treating it as clean.

The current Quickey policy is intentionally development-stage biased:

- CI, review gates, and async bot feedback are the merge gate for `/loop`
- Runtime-sensitive macOS validation is still tracked, but as a release-readiness gate rather than a per-PR merge blocker
- Runtime-sensitive PRs must still carry an explicit `macOS runtime validation pending` note until they are validated on macOS

## Managing Tasks

```
what scheduled tasks do I have?    # list all tasks
cancel the loop job                # cancel by description
```

Under the hood, Claude uses `CronList` and `CronDelete` tools.

## Prompt Design

The task prompt (`docs/loop-prompt.md`) defines:

1. **Safety constraints** — NEVER rules for dangerous operations
2. **Preflight** — version/auth/plugin/git-state checks before each iteration
3. **Workflow steps** — process PRs → select issue → create branch → implement → verify
4. **Review gates** — `/simplify` before commit, `/code-review` and `/codex:review --base main --background` after PR creation when available
5. **Merge timing** — no merge in the same iteration that creates or updates a PR; async bot review and CI must settle first
6. **Platform awareness** — non-macOS runs can complete automated verification; runtime-sensitive changes may still merge during development, but must carry `macOS runtime validation pending` until release validation is complete

Keep prompts generic. Project-specific context belongs in `CLAUDE.md` / `AGENTS.md`.

## Limitations

- **Session-scoped**: Closing the terminal cancels all tasks
- **No catch-up**: Missed fires don't queue up
- **3-day expiry**: Recreate if needed for longer runs
- **No custom error handling**: `/loop` has no exponential backoff or circuit breaker

Use `/loop` for session-local polling and light autonomous maintenance while a session stays open. For recurring work that must survive restarts or run unattended for longer periods, prefer [Desktop scheduled tasks](https://code.claude.com/docs/en/desktop#schedule-recurring-tasks), [Cloud scheduled tasks](https://code.claude.com/docs/en/web-scheduled-tasks), or GitHub Actions.
