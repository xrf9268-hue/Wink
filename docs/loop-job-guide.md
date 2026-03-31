# Loop Job Guide

How to run automated Claude Code sessions for recurring project work using `/loop`. See also [Wiki: Loop Job Configuration](https://github.com/xrf9268-hue/Quickey/wiki/Loop-Job-Configuration).

## Quick Start

In a Claude Code interactive session, run:

```
/loop 30m Follow the instructions in docs/loop-prompt.md
```

This schedules a recurring task that fires every 30 minutes. Each iteration follows the workflow defined in `docs/loop-prompt.md`.

## How /loop Works

`/loop` is a built-in Claude Code skill that creates a cron-based scheduled task within the current session.

| Property | Value |
|----------|-------|
| Runs in | Current Claude Code session (interactive mode) |
| Skills support | Full — `/code-review`, `/simplify`, `/codex:review`, etc. are available |
| Minimum interval | 1 minute |
| Priority | Low — runs between your turns, never interrupts |
| Persistence | Session-scoped — gone when you exit |
| Auto-expiry | 3 days after creation |
| Max concurrent tasks | 50 |

### Interval syntax

```
/loop 30m <prompt>              # leading interval
/loop <prompt> every 2 hours    # trailing interval
/loop <prompt>                  # defaults to 10 minutes
```

Supported units: `s` (seconds, rounded to nearest minute), `m` (minutes), `h` (hours), `d` (days).

### Skills in /loop

`/loop` runs prompts in interactive mode, so all skills work natively:

```
/loop 20m /code-review          # review PRs every 20 minutes
/loop 1h /simplify              # simplify code every hour
```

The prompt in `docs/loop-prompt.md` uses `/simplify` (pre-commit code quality), `/code-review` ([code-review plugin](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/code-review); posts findings as PR comments), and `/codex:review --base main --background` ([Codex Plugin CC](https://github.com/openai/codex-plugin-cc); session-local, retrieve with `/codex:status` + `/codex:result`).

## Managing Tasks

```
what scheduled tasks do I have?    # list all tasks
cancel the loop job                # cancel by description
```

Under the hood, Claude uses `CronList` and `CronDelete` tools.

## Prompt Design

The task prompt (`docs/loop-prompt.md`) defines:

1. **Safety constraints** — NEVER rules for dangerous operations
2. **Workflow steps** — what to do each iteration (process PRs → select issue → implement → verify)
3. **Review gates** — `/simplify` before commit, `/code-review` and `/codex:review --base main --background` after PR creation

Keep prompts generic. Project-specific context belongs in `CLAUDE.md` / `AGENTS.md`.

## Limitations

- **Session-scoped**: Closing the terminal cancels all tasks
- **No catch-up**: Missed fires don't queue up
- **3-day expiry**: Recreate if needed for longer runs
- **No custom error handling**: `/loop` has no exponential backoff or circuit breaker

For durable scheduling that survives restarts, consider [Cloud scheduled tasks](https://code.claude.com/docs/en/web-scheduled-tasks) or [Desktop scheduled tasks](https://code.claude.com/docs/en/desktop#schedule-recurring-tasks).
