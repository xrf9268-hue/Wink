---
name: pr-review-loop
description: Wink's layered PR review protocol — local Codex pre-push review for runtime-sensitive changes, the GitHub Codex bot's trigger/terminal semantics, thread etiquette, and the merge checklist. Load before opening, updating, or shepherding any PR in this repository.
---

# Wink PR Review Loop

The repository's review protocol is layered. Each layer has caught real
defects the previous layers missed (calibration data: 2026-07-22, PRs
#374–#379); skipping a layer is how plausible-but-wrong code merges.

## Layer 0 — author self-check

Beyond `swift build` / `swift test`:

- Diff-based review cannot see lines that SHOULD have changed but didn't.
  For sweeping changes, run a task-specific reverse audit (e.g. the #374
  localization pass needed catalog-vs-source orphan checks in both
  directions: keys without live call sites AND call sites bypassing the
  catalog).
- Check every new value against dual-use: does it feed an identifier,
  persistence key, comparison, or notification identity? Localized or
  session-scoped values must never reach those (see AGENTS.md and the
  #323/#375 lessons).

## Layer 1 — local Codex review BEFORE the first push (hard gate)

If the change touches any of: hot paths (event tap, Carbon handlers,
toggle/dispatch), persistence compatibility (shortcuts.json, .winkrecipe,
usage.db), or concurrency boundaries (locks, queued deliveries, actor
hops) — run a local Codex deep review over the full branch diff before
pushing. Purely presentational changes may skip this.

Prompt it with the diff range, the architectural context, and an explicit
list of already-known findings to exclude. Full-repo local review sees
cross-file lifecycle interactions that per-diff bot review repeatedly
misses (measured: 4 P2 + 2 P3 found locally after four clean-ish bot
rounds on #379, including generation-binding and deadline-timing holes).

Fix confirmed findings before the first push: every post-push fix round
costs a bot review cycle and pollutes the PR timeline.

## Layer 2 — the GitHub Codex bot

- Triggers: opening a PR, marking a draft ready, or commenting
  `@codex review`.
- Working signal: 👀 reaction on the trigger. Do not conclude anything
  (and do not re-trigger) while 👀 is present.
- Terminal signals — THREE forms, any one of them:
  1. a review object with inline threads (findings);
  2. a 👍 reaction on the trigger (clean pass, common on first rounds);
  3. a top-level comment "Codex Review: Didn't find any major issues"
     (clean pass, common on re-reviews).
  A watcher that only checks two of the three will misread "still
  running" and waste a quota round on a duplicate trigger.
- After pushing fixes: reply on each thread with the commit hash and what
  changed, resolve the thread, and trigger a fresh round. Repeat until a
  clean pass on the current head commit. Never resolve a thread whose fix
  is not on the branch.
- The `Review Gate / Validate review state` check fails while actionable
  threads are unresolved; after resolving, rerun the stale check run
  (requires repository admin).

## Layer 3 — merge checklist

- The PR body satisfies the `Validate PR metadata` gate: a closing
  keyword (`Fixes #N`) linking an issue, and the template's three
  `Validation Status` checklist lines kept verbatim with EXACTLY ONE
  checked. The gate computes runtime-sensitive paths itself and rejects
  `Not runtime-sensitive` for them — the checkbox is what it enforces;
  no label substitutes for it.
- All checks green on the HEAD commit (a clean bot pass on an older
  commit does not count).
- Zero unresolved actionable threads.
- Runtime-sensitive PRs (per AGENTS.md's definition) ADDITIONALLY carry
  the `macOS runtime validation pending` label (tracking convention on
  top of the enforced checkbox) and enumerate their physical validation
  items in the PR body; the label flips to complete only after on-device
  validation, typically batched (see the batch-validation issues, e.g.
  #371).
- Bot findings verify against source before accepting: the bot has been
  wrong about liveness before (a "dead" catalog key with a real consumer)
  — confirm each finding the same way you'd confirm a human reviewer's.

## Escalation pattern observed

The bot presses progressively deeper on the same seam across rounds
(e.g. #378: handler-install order inside start() → SwiftUI scene
construction preceding start() entirely → suspension-state coupling).
Treat each round's finding as a pointer to a CLASS of defect and sweep
the class yourself before re-triggering, or the next round finds the
sibling you left behind.
