# PR Governance And Review Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a versioned `main` governance baseline and a deterministic review gate that blocks unresolved actionable review feedback with a required GitHub check, without changing Quickey's current development-stage runtime-validation policy.

**Architecture:** Store the desired `main` ruleset in-repo as JSON so the merge contract lives beside the workflows it protects. Implement the review gate as a `pull_request_target` workflow that runs repository-owned Node code, with pure review-state helpers split into `.github/scripts/lib/` so thread classification and summary rendering stay fully unit-testable without live GitHub API calls.

**Tech Stack:** GitHub Actions YAML, Node.js `fetch`, GitHub GraphQL API, `node:test`, Markdown docs, `gh api` for repository-admin rollout verification

**Out of Scope For This Plan:** Phase 3 runtime evidence standardization and Phase 4 agent eval harness

---

## File Map

- Create: `.github/governance/main-ruleset.json` - versioned desired repository ruleset payload for `main`
- Create: `.github/scripts/tests/main-ruleset.test.mjs` - validates that the checked-in ruleset still requires PRs, approvals, conversation resolution, and the exact required checks
- Create: `.github/scripts/lib/review-state.mjs` - pure helpers for review-thread normalization, actionable-thread filtering, failure-state computation, and summary rendering
- Create: `.github/scripts/validate-review-state.mjs` - workflow entrypoint that loads PR context, queries GitHub review state, writes concise logs plus `$GITHUB_STEP_SUMMARY`, and exits non-zero when merge-blocking review state remains
- Create: `.github/scripts/tests/review-state.test.mjs` - deterministic tests for `CHANGES_REQUESTED`, unresolved threads, outdated threads, bot-vs-human treatment, and summary formatting
- Create: `.github/workflows/review-gate.yml` - repository-native required check with workflow name `Review Gate` and job name `Validate review state`
- Modify: `docs/github-automation.md` - document the new required check, the checked-in ruleset artifact, and the admin apply/verify flow
- Modify: `docs/README.md` - keep maintainer navigation current once governance docs expand
- Modify: `docs/loop-job-guide.md` - align `/loop` merge-gate language with the new repository-native review gate
- Modify: `docs/loop-prompt.md` - add the review-gate workflow to the reference list of GitHub-native automation
- Modify: `docs/handoff-notes.md` - record the rollout status and any remaining admin-only follow-up
- Modify: `AGENTS.md` - document the new deterministic review-state merge gate while preserving the existing `macOS runtime validation pending` vs `complete` policy

## Task 1: Check In The `main` Ruleset Contract

**Files:**
- Create: `.github/governance/main-ruleset.json`
- Create: `.github/scripts/tests/main-ruleset.test.mjs`

- [ ] **Step 1: Write the failing ruleset contract test**

Create `.github/scripts/tests/main-ruleset.test.mjs` with assertions that the checked-in ruleset targets the default branch and requires the full Phase 1 baseline:

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const ruleset = JSON.parse(
  await readFile(new URL('../../governance/main-ruleset.json', import.meta.url), 'utf8'),
);

function findRule(type) {
  return ruleset.rules.find((rule) => rule.type === type);
}

test('main ruleset requires pull requests and review freshness', () => {
  const pullRequestRule = findRule('pull_request');

  assert.equal(ruleset.target, 'branch');
  assert.equal(ruleset.enforcement, 'active');
  assert.deepEqual(ruleset.conditions.ref_name.include, ['~DEFAULT_BRANCH']);
  assert.equal(pullRequestRule.parameters.required_approving_review_count, 1);
  assert.equal(pullRequestRule.parameters.dismiss_stale_reviews_on_push, true);
  assert.equal(pullRequestRule.parameters.require_last_push_approval, true);
  assert.equal(pullRequestRule.parameters.required_review_thread_resolution, true);
});

test('main ruleset requires the deterministic Quickey checks', () => {
  const statusChecksRule = findRule('required_status_checks');
  const contexts = statusChecksRule.parameters.required_status_checks.map(
    (check) => check.context,
  );

  assert.deepEqual(contexts, [
    'CI / Build and Test',
    'PR Metadata / Validate PR metadata',
    'Review Gate / Validate review state',
  ]);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test .github/scripts/tests/main-ruleset.test.mjs`
Expected: FAIL because `.github/governance/main-ruleset.json` does not exist yet.

- [ ] **Step 3: Add the versioned ruleset artifact**

Create `.github/governance/main-ruleset.json` with the repository-owned merge contract. Keep the payload limited to the Phase 1 baseline so Phase 3 and Phase 4 do not accidentally become required merge gates.

```json
{
  "name": "main merge governance",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    }
  },
  "bypass_actors": [],
  "rules": [
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "CI / Build and Test" },
          { "context": "PR Metadata / Validate PR metadata" },
          { "context": "Review Gate / Validate review state" }
        ]
      }
    }
  ]
}
```

- [ ] **Step 4: Run the ruleset test to verify it passes**

Run: `node --test .github/scripts/tests/main-ruleset.test.mjs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add .github/governance/main-ruleset.json .github/scripts/tests/main-ruleset.test.mjs
git commit -m "ci: define main ruleset contract"
```

## Task 2: Build The Pure Review-State Policy Helpers

**Files:**
- Create: `.github/scripts/lib/review-state.mjs`
- Create: `.github/scripts/tests/review-state.test.mjs`

- [ ] **Step 1: Write the failing policy tests**

Create `.github/scripts/tests/review-state.test.mjs` with focused unit tests that cover the Phase 2 policy directly:

```js
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  evaluateReviewState,
  firstLine,
  summarizeBlockingThreads,
} from '../lib/review-state.mjs';

test('evaluateReviewState fails when reviewDecision is CHANGES_REQUESTED', () => {
  const result = evaluateReviewState({
    reviewDecision: 'CHANGES_REQUESTED',
    reviewThreads: [],
  });

  assert.equal(result.ok, false);
  assert.equal(result.reasons[0], 'changes-requested');
});

test('evaluateReviewState fails on unresolved non-outdated inline threads', () => {
  const result = evaluateReviewState({
    reviewDecision: 'APPROVED',
    reviewThreads: [
      {
        isResolved: false,
        isOutdated: false,
        path: 'Sources/Quickey/AppController.swift',
        line: 88,
        reviewer: 'quickey-review-bot',
        bodyText: 'Guard the no-window path before marking activation stable.',
      },
    ],
  });

  assert.equal(result.ok, false);
  assert.equal(result.blockingThreads.length, 1);
});

test('evaluateReviewState ignores outdated unresolved threads', () => {
  const result = evaluateReviewState({
    reviewDecision: 'APPROVED',
    reviewThreads: [
      {
        isResolved: false,
        isOutdated: true,
        path: 'Sources/Quickey/AppController.swift',
        line: 88,
        reviewer: 'octocat',
        bodyText: 'Old comment',
      },
    ],
  });

  assert.equal(result.ok, true);
});

test('summarizeBlockingThreads renders file reviewer and first line', () => {
  const summary = summarizeBlockingThreads([
    {
      path: 'Sources/Quickey/AppController.swift',
      line: 88,
      reviewer: 'octocat',
      bodyText: 'Guard the no-window path before marking activation stable.\nExtra detail.',
    },
  ]);

  assert.match(summary, /AppController\.swift:88/);
  assert.match(summary, /octocat/);
  assert.match(summary, /Guard the no-window path before marking activation stable\./);
});

test('firstLine trims blank lines and collapses whitespace', () => {
  assert.equal(firstLine('\n  Needs follow-up here.  \n\nSecond line'), 'Needs follow-up here.');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `node --test .github/scripts/tests/review-state.test.mjs`
Expected: FAIL because `.github/scripts/lib/review-state.mjs` does not exist yet.

- [ ] **Step 3: Implement the pure review-state helpers**

Create `.github/scripts/lib/review-state.mjs` so the workflow wrapper only handles API I/O and process exit behavior. Keep the policy narrow and deterministic:

```js
export function firstLine(bodyText) {
  return bodyText
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find(Boolean) ?? '(no summary text)';
}

export function isActionableThread(thread) {
  return thread.isResolved === false && thread.isOutdated === false;
}

export function evaluateReviewState({ reviewDecision, reviewThreads }) {
  const blockingThreads = reviewThreads.filter(isActionableThread);
  const reasons = [];

  if (reviewDecision === 'CHANGES_REQUESTED') {
    reasons.push('changes-requested');
  }

  if (blockingThreads.length > 0) {
    reasons.push('unresolved-thread');
  }

  return {
    ok: reasons.length === 0,
    reasons,
    blockingThreads,
  };
}

export function summarizeBlockingThreads(blockingThreads) {
  return blockingThreads
    .map((thread) => {
      const anchor = thread.line ?? thread.originalLine ?? thread.startLine ?? '?';
      return `- ${thread.path}:${anchor} - ${thread.reviewer} - ${firstLine(thread.bodyText)}`;
    })
    .join('\n');
}
```

Treat both humans and trusted bots as actionable when the feedback exists as an unresolved inline review thread. Do not add severity parsing or top-level comment parsing in this phase.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `node --test .github/scripts/tests/review-state.test.mjs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add .github/scripts/lib/review-state.mjs .github/scripts/tests/review-state.test.mjs
git commit -m "ci: add review state policy helpers"
```

## Task 3: Add The Workflow Entrypoint And Required Check

**Files:**
- Create: `.github/scripts/validate-review-state.mjs`
- Create: `.github/workflows/review-gate.yml`
- Modify: `.github/scripts/tests/review-state.test.mjs`

- [ ] **Step 1: Add an integration-style test for the CLI wrapper**

Extend `.github/scripts/tests/review-state.test.mjs` with one script-level test that executes the entrypoint using an environment override instead of hitting GitHub:

```js
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

test('validate-review-state writes a step summary and exits non-zero for blocking threads', async () => {
  const tempDir = await mkdtemp(join(tmpdir(), 'quickey-review-gate-'));
  const eventPath = join(tempDir, 'event.json');
  const summaryPath = join(tempDir, 'summary.md');

  await writeFile(
    eventPath,
    JSON.stringify({
      repository: { owner: { login: 'xrf9268-hue' }, name: 'Quickey' },
      pull_request: { number: 999, body: '' },
    }),
  );

  const result = spawnSync('node', ['.github/scripts/validate-review-state.mjs'], {
    cwd: process.cwd(),
    encoding: 'utf8',
    env: {
      ...process.env,
      GITHUB_EVENT_PATH: eventPath,
      GITHUB_STEP_SUMMARY: summaryPath,
      PR_REVIEW_STATE: JSON.stringify({
        reviewDecision: 'APPROVED',
        reviewThreads: [
          {
            isResolved: false,
            isOutdated: false,
            path: 'Sources/Quickey/AppController.swift',
            line: 88,
            reviewer: 'quickey-review-bot',
            bodyText: 'Guard the no-window path before marking activation stable.',
          },
        ],
      }),
    },
  });

  assert.equal(result.status, 1);
  assert.match(await readFile(summaryPath, 'utf8'), /AppController\.swift:88/);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `node --test .github/scripts/tests/review-state.test.mjs`
Expected: FAIL because `.github/scripts/validate-review-state.mjs` does not exist yet.

- [ ] **Step 3: Implement the CLI wrapper and workflow**

Create `.github/scripts/validate-review-state.mjs` with these constraints:

```js
import { appendFile, readFile } from 'node:fs/promises';

import { evaluateReviewState, summarizeBlockingThreads } from './lib/review-state.mjs';

const apiVersion = '2022-11-28';

async function graphqlRequest(query, variables) {
  const response = await fetch('https://api.github.com/graphql', {
    method: 'POST',
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${process.env.GITHUB_TOKEN}`,
      'Content-Type': 'application/json',
      'User-Agent': 'quickey-review-gate',
      'X-GitHub-Api-Version': apiVersion,
    },
    body: JSON.stringify({ query, variables }),
  });

  const payload = await response.json();
  if (!response.ok || payload.errors?.length) {
    throw new Error(JSON.stringify(payload.errors ?? payload));
  }

  return payload.data;
}

async function loadReviewState(owner, repo, pullRequestNumber) {
  if (process.env.PR_REVIEW_STATE) {
    return JSON.parse(process.env.PR_REVIEW_STATE);
  }

  let after = null;
  let reviewDecision = null;
  const reviewThreads = [];

  do {
    const data = await graphqlRequest(
      `
        query ReviewState($owner: String!, $repo: String!, $pullRequestNumber: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $pullRequestNumber) {
              reviewDecision
              reviewThreads(first: 100, after: $after) {
                pageInfo {
                  hasNextPage
                  endCursor
                }
                nodes {
                  isResolved
                  isOutdated
                  path
                  line
                  originalLine
                  startLine
                  originalStartLine
                  comments(first: 1) {
                    nodes {
                      bodyText
                      author {
                        login
                      }
                    }
                  }
                }
              }
            }
          }
        }
      `,
      { owner, repo, pullRequestNumber, after },
    );

    const pullRequest = data.repository.pullRequest;
    reviewDecision = pullRequest.reviewDecision;

    for (const thread of pullRequest.reviewThreads.nodes) {
      const comment = thread.comments.nodes[0];
      reviewThreads.push({
        isResolved: thread.isResolved,
        isOutdated: thread.isOutdated,
        path: thread.path,
        line:
          thread.line ?? thread.originalLine ?? thread.startLine ?? thread.originalStartLine ?? null,
        reviewer: comment?.author?.login ?? 'ghost',
        bodyText: comment?.bodyText ?? '',
      });
    }

    after = pullRequest.reviewThreads.pageInfo.hasNextPage
      ? pullRequest.reviewThreads.pageInfo.endCursor
      : null;
  } while (after);

  return { reviewDecision, reviewThreads };
}

function stepSummary(result) {
  if (result.ok) {
    return '## Review Gate\n\nNo unresolved actionable review feedback remains.\n';
  }

  const lines = [
    '## Review Gate',
    '',
    'Merge is blocked until the following review state is cleared:',
    '',
  ];

  if (result.reasons.includes('changes-requested')) {
    lines.push('- Pull request review decision is `CHANGES_REQUESTED`.');
  }

  if (result.blockingThreads.length > 0) {
    lines.push('- Unresolved actionable inline review threads remain.');
    lines.push('');
    lines.push(summarizeBlockingThreads(result.blockingThreads));
  }

  return lines.join('\n');
}
```

Create `.github/workflows/review-gate.yml` with the same repository-owned pattern as `pr-metadata.yml`:

```yaml
name: Review Gate

on:
  pull_request_target:
    types: [opened, edited, reopened, synchronize, ready_for_review, converted_to_draft, review_requested, review_request_removed]

permissions:
  contents: read
  pull-requests: read

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  validate-review-state:
    name: Validate review state
    runs-on: ubuntu-latest
    steps:
      - name: Checkout base workflow code
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd
        with:
          persist-credentials: false
          ref: ${{ github.event.pull_request.base.sha }}

      - name: Validate review state
        env:
          GITHUB_TOKEN: ${{ github.token }}
        run: node .github/scripts/validate-review-state.mjs
```

Use `pull_request_target` so the workflow can safely read review state on fork PRs while still executing base-branch code. Keep the check name stable by preserving workflow name `Review Gate` and job name `Validate review state`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `node --test .github/scripts/tests/review-state.test.mjs`
Expected: PASS

Run:

```bash
tmpdir="$(mktemp -d)"
cat > "$tmpdir/event.json" <<'JSON'
{
  "repository": { "owner": { "login": "xrf9268-hue" }, "name": "Quickey" },
  "pull_request": { "number": 999, "body": "" }
}
JSON
GITHUB_EVENT_PATH="$tmpdir/event.json" \
GITHUB_STEP_SUMMARY="$tmpdir/summary.md" \
PR_REVIEW_STATE='{"reviewDecision":"APPROVED","reviewThreads":[{"isResolved":false,"isOutdated":false,"path":"Sources/Quickey/AppController.swift","line":88,"reviewer":"quickey-review-bot","bodyText":"Guard the no-window path before marking activation stable."}]}' \
node .github/scripts/validate-review-state.mjs
```

Expected: exit code `1`, logs mention unresolved actionable review feedback, and `$tmpdir/summary.md` contains the file anchor plus reviewer summary.

- [ ] **Step 5: Commit**

```bash
git add .github/scripts/validate-review-state.mjs .github/workflows/review-gate.yml .github/scripts/tests/review-state.test.mjs
git commit -m "ci: add review gate workflow"
```

## Task 4: Document The Merge Gate And Runtime-Policy Boundary

**Files:**
- Modify: `docs/github-automation.md`
- Modify: `docs/README.md`
- Modify: `docs/loop-job-guide.md`
- Modify: `docs/loop-prompt.md`
- Modify: `docs/handoff-notes.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Update the repository docs**

Make the policy changes explicit in the docs contributors already read:

- `docs/github-automation.md`
  - add the checked-in ruleset artifact
  - add `Review Gate / Validate review state` to the required checks list
  - document that unresolved actionable inline review threads and `CHANGES_REQUESTED` now block merge
  - preserve the statement that `macOS runtime validation pending` is still a development-stage declaration, not a required hosted CI check
- `docs/README.md`
  - mention the governance/ruleset artifact and review-gate workflow in the Automation section
- `docs/loop-job-guide.md`
  - change "CI, review gates, and async bot feedback are the merge gate for `/loop`" to language that points at the repository-native review gate as the durable merge signal
- `docs/loop-prompt.md`
  - add the review gate to the reference list of GitHub-native automation
- `docs/handoff-notes.md`
  - record the rollout date, what is now enforced automatically, and any remaining admin-only apply/verify follow-up
- `AGENTS.md`
  - add a short note in the workflow/policy guidance that unresolved actionable review threads now fail a required check, while macOS runtime validation remains a separate truthfulness obligation

- [ ] **Step 2: Verify the docs stay internally consistent**

Run:

```bash
rg -n "Review Gate|Validate review state|main-ruleset|macOS runtime validation pending|required status check" AGENTS.md docs .github
```

Expected: the new workflow, ruleset artifact, and runtime-policy boundary all appear in the updated docs without contradictory wording.

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md docs/github-automation.md docs/README.md docs/loop-job-guide.md docs/loop-prompt.md docs/handoff-notes.md
git commit -m "docs: document pr governance and review gate"
```

## Task 5: Apply And Verify The Ruleset In GitHub

**Files:**
- Modify: none

- [ ] **Step 1: Inspect the live rulesets**

Run:

```bash
gh api repos/xrf9268-hue/Quickey/rulesets \
  -H "Accept: application/vnd.github+json" \
  --jq '.[] | {id, name, target, enforcement}'
```

Expected: either no `main merge governance` ruleset exists yet, or an existing ruleset id is returned for update.

- [ ] **Step 2: Create or update the ruleset from the checked-in artifact**

If the ruleset does not exist:

```bash
gh api repos/xrf9268-hue/Quickey/rulesets \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  --input .github/governance/main-ruleset.json
```

If the ruleset already exists:

```bash
RULESET_ID="$(gh api repos/xrf9268-hue/Quickey/rulesets --jq '.[] | select(.name=="main merge governance") | .id')"
gh api "repos/xrf9268-hue/Quickey/rulesets/$RULESET_ID" \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  --input .github/governance/main-ruleset.json
```

Expected: GitHub returns the active branch ruleset payload with the default-branch target and the three required checks.

- [ ] **Step 3: Verify the required checks and conversation policy on a PR**

Use a disposable PR or the implementation PR for this branch:

1. Confirm the PR shows check runs named `CI / Build and Test`, `PR Metadata / Validate PR metadata`, and `Review Gate / Validate review state`.
2. Leave or keep one unresolved inline review thread and verify `Review Gate / Validate review state` fails.
3. Resolve the thread or push an update that makes the thread outdated and verify the review gate passes.
4. Confirm the merge box still does not claim that macOS runtime validation is automatically complete.

Expected: merge is blocked by unresolved actionable review state, and runtime validation remains a separate truthful declaration.

- [ ] **Step 4: Record any admin-only residual follow-up**

If the repository admin action cannot be completed in the implementation session, add a short note to the implementation PR and `docs/handoff-notes.md` that the checked-in ruleset artifact is ready but live application remains pending.

## Coverage Check

- Phase 1 governance baseline is covered by Task 1, Task 4, and Task 5.
- Phase 2 review gate is covered by Task 2, Task 3, Task 4, and Task 5.
- The plan intentionally defers `scripts/capture-runtime-validation.sh`, CI `bats` expansion, `.github/workflows/agent-evals.yml`, and eval fixtures so this branch does not drift into Phase 3 or Phase 4 before the governance baseline is landed.
