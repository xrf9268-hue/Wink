---
name: babysit-prs
description: >-
  Autonomous PR/issue triage and implementation loop for the current repository.
  Processes open PRs (CI fixes, review feedback, merge), selects the next issue
  by priority, implements it, and submits a review-gated PR.
  Use when the user runs `/loop <interval> /babysit-prs`, says "help me
  automatically process PRs and issues", or sets up recurring autonomous
  development work. Do not use for one-off PR reviews, manual issue work,
  or single code-review requests.
---

# Babysit PRs

## Purpose

Autonomous iteration: process PRs → select issue → implement → review gate → submit. Each iteration is self-contained; leave clear breadcrumbs for the next one.

This skill is responsible for the full autonomous development loop. It is NOT responsible for: one-off code reviews (`/code-review`), manual issue investigation, or architecture decisions (label `arch-decision` and skip).

## Terminology

- **NEXT ITERATION**: End the current iteration. Return control to the /loop scheduler.
- **STOP LOOP**: Halt all work. Only if a safety constraint is violated or the repo is unrecoverably broken.

## Safety Constraints

- NEVER push directly to main. Always use feature branches.
- NEVER delete unmerged branches.
- NEVER modify CLAUDE.md or AGENTS.md core rules and architecture sections.
- NEVER run destructive commands (rm -rf, git reset --hard, git clean -f).
- NEVER modify CI/CD workflows or GitHub Actions configs.
- NEVER merge a PR in the same iteration that created it or pushed new commits to it.
- NEVER treat a missing review tool as a clean review. Missing tooling is a degraded gate — record it explicitly on the PR.
- If an issue is ambiguous or requires architectural decisions, add label `arch-decision` and skip it.

## Turn Budget

Each iteration has **25 turns**. Track your approximate count. At 25 turns without completion: comment on the issue/PR describing what remains, then NEXT ITERATION.

## Pipeline

### Iteration Guard

Before any work, check for duplicate fires:

```bash
gh pr list --search "author:@me" --state open --json updatedAt --limit 5
```

If any PR was updated < 5 minutes ago, this may be a duplicate fire. Proceed to **NEXT ITERATION** without changes.

#### Circuit Breaker (Rate Limit Protection)

Read `logs/loop-circuit-breaker.json` (create with defaults if missing). For full state machine details, see `references/circuit-breaker.md`.

- If `circuitState` is `"open"` and `cooldownUntil` is in the future: log and **NEXT ITERATION**.
- If `circuitState` is `"open"` and `cooldownUntil` has passed: set `"half-open"`, continue pipeline.
- On rate-limit or quota error at any step: increment failures; if ≥ 2, open breaker with exponential backoff (30min–4h).
- On successful iteration: reset to `"closed"`.

### Session Init (first iteration only)

If this is the first iteration in the session (no prior `/loop` history in session memory):

1. `gh auth status` — if fails, **STOP LOOP**
2. `git status --short --branch` — if worktree is dirty with unrelated changes, **STOP LOOP**
3. Check review tooling availability: determine whether `/simplify`, `/code-review`, and `/codex:review` are available in this session. Cache the result in session memory.

On subsequent iterations, only run `git status --short --branch`.

### Step 1: Process Existing PRs (max 2 per iteration)

Query: `gh pr list --state open --json number,title,headRefName,statusCheckRollup,labels,reviews`

Process each PR in order: **1b → 1c → 1a**.

**1b. CI failures**: Check `gh pr checks <number>`. Attempt fix (max 2 attempts). If still failing: add label `needs-human-review`, comment, move on. If you push a fix, leave the PR open for a later iteration.

**1c. Review feedback**: Read `references/review-gates.md` for tool-specific rules. Read PR comments: `gh pr view <number> --comments`. Check session memory for `/codex:review` findings. All bot review findings (any priority) and high-confidence `/code-review` findings (≥80): must-fix. Only skip a finding if it is clearly a false positive or provides no actionable value — in that case, comment on the PR explaining why it was dismissed. If a review tool is unavailable, comment that the gate was unavailable and leave the PR open.

**1a. Merge eligible**: A PR is eligible when ALL true:
- CI passes
- No unresolved high-confidence `/code-review` findings (≥80)
- No unresolved bot review findings (any priority)
- No unresolved critical `/codex:review` findings in session memory
- PR was NOT created or pushed to in this iteration
- No `needs-human-review` or `arch-decision` label

If eligible: `gh pr merge <number> --squash --delete-branch`.

### Step 2: Select Next Issue

```bash
gh issue list --state open --json number,title,labels,body --limit 50
```

Priority: P0-critical > P1-high > P2-medium > P3-low > unlabeled. Skip `arch-decision` issues. Skip issues with an open linked PR. Pick **ONE** issue. If none eligible → **NEXT ITERATION**.

### Step 3: Create Branch

```bash
git fetch origin
git checkout main
git pull --ff-only
git checkout -b loop/issue-<number>-<slug>
```

If branch creation fails, comment on the issue and **NEXT ITERATION**.

### Step 4: Classify and Implement

If fewer than 10 turns remain → comment on issue, **NEXT ITERATION**.

- **Simple** (single-file, bug fix, docs): Implement with TDD directly.
- **Complex** (multi-file, new API, 200+ lines):
  - No plan exists: write plan to `docs/superpowers/plans/<topic>.md`, comment on issue, **NEXT ITERATION**.
  - Plan exists: implement ONE sub-task.

For runtime-sensitive changes on non-macOS hosts, see `references/macos-runtime-policy.md`.

### Step 5: Verify and Submit

**5a. Build and test**:
```bash
swift build && swift test && swift build -c release
```
Max 3 fix-build-test cycles. If still failing → comment, **NEXT ITERATION**.

**5b. Code quality**: If `/simplify` is available, run once before committing. If unavailable, note in PR body.

**5c. Commit and create PR**:
```bash
git add -A
git commit -m "<type>: <concise description> (#<N>)"
git push -u origin HEAD
gh pr create --title "<title under 70 chars>" --body "$(cat <<'EOF'
Closes #<N>

## Summary
<1-3 bullet points>

## Verification
- Automated: swift build, swift test, swift build -c release
EOF
)" --base main
```

**5d. Review gate (bounded)**: Fire reviews in parallel where possible:
1. `/codex:review --base main --background` first (async, if available)
2. `/code-review` (sync, if available)
3. Bot reviews arrive asynchronously — handled in Step 1c of a future iteration

Round 1: Fix high-confidence/critical issues, push, re-run each available tool once.
Round 2: If issues persist, fix if 1-2 changes suffice. Otherwise add `needs-human-review`.

Max **2 invocations per review tool per PR per iteration**.

**5e.** Do NOT merge. Leave the PR open for the next iteration so CI and async reviews can settle.

Proceed to **NEXT ITERATION**.

## Gotchas

- `/codex:review` results are **session-local only** — they do not appear as PR comments. Check session memory, not `gh pr view --comments`.
- `/code-review` and bot reviews post durable PR comments readable via `gh pr view --comments` across iterations.
- CronCreate can duplicate-deliver long prompts. This skill exists to avoid that — do not inline its content into `/loop`.
- Stop hooks that return `block` on infrastructure failures cause **infinite loops** (Claude responds → hook blocks → Claude responds again). The rate-limit-detector hook must always exit 0. See `docs/lessons-learned.md` § "Codex Stop Hook Infinite Loop".
- All bot review findings block merge regardless of priority level. A P2 finding that slips through causes follow-up fix PRs. See `docs/lessons-learned.md` § "babysit-prs Bot Review Findings Must All Block Merge".
- When API quota is fully exhausted, neither the circuit breaker nor the Stop hook can fire — the loop will empty-fire at the configured interval. This is a `/loop` infrastructure limitation, not a bug in this skill.
- `claude -p` (headless mode) does not support skills. Always use `/loop` for recurring work, never shell-scripted headless invocations.
- You MAY append entries to `docs/lessons-learned.md` when discovering operational insights.

## Example: Successful Simple Iteration

```
Iteration Guard  → no duplicate fires, circuit breaker closed
Session Init     → gh auth ok, worktree clean, /code-review available
Step 1           → PR #115 CI passes, reviews clean → merge
Step 2           → Issue #93 (P2-medium, no linked PR) selected
Step 3           → branch loop/issue-93-cooldown-metrics created
Step 4           → classified Simple (single test file + metric struct)
                 → implement with TDD
Step 5a          → swift build ✅, swift test ✅, swift build -c release ✅
Step 5b          → /simplify ran, no issues
Step 5c          → commit, push, gh pr create
Step 5d          → /code-review ran, 0 high-confidence findings
Step 5e          → PR left open for next iteration
Verification     → checklist all green, circuit breaker → closed
→ NEXT ITERATION
```

## Verification (self-check before NEXT ITERATION)

- [ ] No uncommitted changes left in worktree
- [ ] All PRs touched have clear status comments
- [ ] No missing review gates went unrecorded
- [ ] Branch is not `main`
- [ ] Circuit breaker state updated: `circuitState` → `"closed"`, `consecutiveFailures` → `0` on success

## Linked Resources

| File | When to read | Purpose |
|------|-------------|---------|
| `references/review-gates.md` | Step 1c (review feedback) | Three-tier review tool behavior, confidence thresholds, degraded-tooling handling |
| `references/macos-runtime-policy.md` | Step 4 (implement) | Runtime-sensitive change definition, validation tracking for non-macOS hosts |
| `references/circuit-breaker.md` | Iteration Guard (circuit breaker) | Full state machine, backoff schedule, Stop hook integration details |
| `docs/lessons-learned.md` | When discovering operational insights | Append new entries; check for relevant gotchas before implementing |
| `docs/loop-job-guide.md` | Session Init (first iteration) | `/loop` behavior, interval syntax, limitations |
