# Loop Job Guide

How to run automated Claude Code sessions for recurring project work using `/loop`. See also [Wiki: Loop Job Configuration](https://github.com/xrf9268-hue/Wink/wiki/Loop-Job-Configuration).

Repository-native state sync is now handled separately by GitHub Actions:
- `.github/workflows/pr-metadata.yml` enforces PR issue linkage and validation-state metadata
- `.github/workflows/review-gate.yml` turns unresolved actionable review state into a deterministic required check
- `.github/workflows/project-sync.yml` keeps `Wink Backlog` `Status` and `Runtime Validation` aligned with issue/PR state
- [`github-automation.md`](./github-automation.md) documents the required `PROJECT_AUTOMATION_TOKEN` secret, checked-in ruleset artifact, and governance rollout order

## Quick Start

In a Claude Code interactive session, run:

```
/loop 30m /babysit-prs
```

This schedules a recurring task that fires every 30 minutes. Each iteration follows the pipeline defined in the `babysit-prs` skill (`.claude/skills/babysit-prs/SKILL.md` in this repo).

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
- Confirm review tooling is available in the session:
  - `/plugin` to inspect installed plugins
  - `/reload-plugins` after installing or enabling anything
  - `/code-review`, `/codex:review`, and `/simplify` should be treated as optional gates that must be present to run, not assumed silently

The `babysit-prs` skill performs a Session Init check on its first iteration and caches tool availability for the session.

### Interval syntax

```
/loop 30m /babysit-prs             # leading interval
/loop /babysit-prs every 2 hours   # trailing interval
/loop /babysit-prs                 # defaults to 10 minutes
```

Supported units: `s` (seconds, rounded to nearest minute), `m` (minutes), `h` (hours), `d` (days).

### Skills in /loop

`/loop` runs prompts in interactive mode, so built-in skills and any already-loaded plugin commands work natively:

```
/loop 20m /code-review          # review PRs every 20 minutes
/loop 1h /simplify              # simplify code every hour
/loop 30m /babysit-prs          # full autonomous PR/issue pipeline
```

The `babysit-prs` skill uses `/simplify` when available for pre-commit code quality, `/code-review` ([code-review plugin](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/code-review); posts findings as PR comments), and `/codex:review --base main --background` ([Codex Plugin CC](https://github.com/openai/codex-plugin-cc); session-local, retrieve with `/codex:status` + `/codex:result`). If any of those commands are unavailable in the current session, the skill records the missing gate and defers merge rather than silently treating it as clean.

## Managing Tasks

```
what scheduled tasks do I have?    # list all tasks
cancel the loop job                # cancel by description
```

Under the hood, Claude uses `CronList` and `CronDelete` tools.

## Skill Design

The `babysit-prs` skill uses progressive disclosure:

1. **`SKILL.md`** — main pipeline: safety constraints, iteration guard, session init, workflow steps (process PRs → select issue → create branch → implement → verify)
2. **`references/review-gates.md`** — three-tier review tool behavior, confidence thresholds, degraded-tooling handling
3. **`references/macos-runtime-policy.md`** — runtime-sensitive change definition, `macOS runtime validation pending/complete` tracking, merge vs release gate

Keep the skill generic. Project-specific context belongs in `CLAUDE.md` / `AGENTS.md`.

## Development-Stage Policy

The current Wink policy is intentionally development-stage biased:

- The durable merge gate lives in repository-native governance: required checks plus GitHub conversation resolution on `main`
- `/loop` should treat unresolved bot or human review feedback in GitHub as actionable because `Review Gate / Validate review state` will convert that state into a required check
- Pure thread-resolution changes may not rerun the review gate automatically, so `/loop` should not assume a resolved thread instantly clears the required check without another PR/review/comment event or a manual rerun
- Runtime-sensitive macOS validation is tracked but as a release-readiness gate, not a per-PR merge blocker
- Runtime-sensitive PRs must carry `macOS runtime validation pending` until validated on macOS (see `AGENTS.md` § macOS runtime validation policy)

## Release-Readiness Note

`/loop` is allowed to optimize for development throughput. It is not allowed to erase release obligations.

- Runtime-sensitive changes may merge before macOS runtime validation is complete.
- Before any release, packaging/signing handoff, or release-candidate signoff, all open `macOS runtime validation pending` items must be validated on macOS and updated to `macOS runtime validation complete`.
- Never rewrite history or PR descriptions to imply a pending runtime validation was completed when it was not.

## Limitations

- **Session-scoped**: Closing the terminal cancels all tasks
- **No catch-up**: Missed fires don't queue up
- **3-day expiry**: Recreate if needed for longer runs
- **No custom error handling**: `/loop` has no exponential backoff or circuit breaker
- **No rate limit handling**: When API quota is exhausted, `/loop` continues firing at the configured interval. The `babysit-prs` skill includes a file-based circuit breaker (`logs/loop-circuit-breaker.json`) with exponential backoff to mitigate partial limits, and a Stop hook (`.claude/hooks/rate-limit-detector.sh`) writes cooldown state when rate-limit signals are detected. Full quota exhaustion still causes empty fires — this is a `/loop` infrastructure limitation (#118)

Use `/loop` for session-local polling and light autonomous maintenance while a session stays open. For recurring work that must survive restarts or run unattended for longer periods, prefer [Desktop scheduled tasks](https://code.claude.com/docs/en/desktop#schedule-recurring-tasks), [Cloud scheduled tasks](https://code.claude.com/docs/en/web-scheduled-tasks), or GitHub Actions.
