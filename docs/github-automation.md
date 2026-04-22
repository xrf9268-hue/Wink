# GitHub Automation

Wink now uses repository-native GitHub Actions and a checked-in ruleset artifact to keep issue closure, review state, project state, and runtime-validation state aligned.

## What Is Automated

1. **PR metadata enforcement** (`.github/workflows/pr-metadata.yml`)
   - Every PR must include a closing keyword such as `Fixes #135`
   - Every PR must keep the `Validation Status` checklist and select exactly one option
   - If the PR touches runtime-sensitive files, `Not runtime-sensitive` is rejected automatically

2. **Review-state merge gate** (`.github/workflows/review-gate.yml`)
   - Fails when GitHub reports `reviewDecision == CHANGES_REQUESTED`
   - Fails when unresolved, non-outdated inline review threads remain
   - Treats unresolved inline feedback from both humans and trusted bots as actionable when it lives in GitHub review threads
   - Writes a step summary with file anchors, reviewer, and the first-line finding text so maintainers can understand the block without reading raw API payloads
   - Refreshes on PR, review, and review-comment activity; GitHub Actions does not currently expose a dedicated review-thread resolved/unresolved workflow trigger, so a pure thread-resolution change may need a manual rerun or another PR activity before the check turns green again

3. **Project reconciliation** (`.github/workflows/project-sync.yml`)
   - Adds the event issue or linked issue into the `Wink Backlog` Project V2 if it is missing
   - Scheduled and manual reconciliation runs backfill any repository issues that are still missing from `Wink Backlog`
   - Syncs `Status` to `Ready`, `In Progress`, or `Done`
   - Syncs `Runtime Validation` to `None`, `macOS pending`, or `macOS complete`
   - Re-runs every 6 hours so transient event failures do not leave the project permanently stale

4. **Versioned ruleset baseline** (`.github/governance/main-ruleset.json`)
   - Captures the desired `main` merge policy in-repo
   - Requires pull requests, last-push freshness, conversation resolution, and the required deterministic checks
   - Keeps one-approval review gating for normal PR flows while allowing repository admins to bypass the pull-request rule in solo-maintainer cases
   - Gives repository admins a reviewable artifact to apply after the workflow changes are present on `main`
   - Is kept in the same schema shape used by GitHub's repository ruleset REST `POST`/`PUT` endpoints so the checked-in file can be applied directly

## Required Repository Setup

Store a repository secret named `PROJECT_AUTOMATION_TOKEN`.

Recommended scopes for the token:
- `repo`
- `project`
- `read:org`

`GITHUB_TOKEN` is enough for PR-body validation, but it is not sufficient for Wink's Project V2 field updates. The project-sync workflow uses `PROJECT_AUTOMATION_TOKEN` for GraphQL mutations.

## Recommended Governance Rollout

1. Merge the governance workflow changes to `main`.
2. Apply `.github/governance/main-ruleset.json` as a repository ruleset on `main`.

For the one-time PR body draft, verification steps, and `gh api` apply commands, use [`pr-governance-rollout.md`](./pr-governance-rollout.md).

The ruleset should require these status checks:

- `CI / Build and Test`
- `PR Metadata / Validate PR metadata`
- `Review Gate / Validate review state`

It should also require:

- pull requests for all changes to `main`
- at least one human approval for normal contributors
- approval freshness for the latest reviewable push
- resolved review conversations

Repository admins are allowed to bypass the pull-request rule in `pull_request` mode for solo-maintainer repos, but they still must satisfy the required status checks because those live in a separate ruleset rule.

Do not apply the ruleset before the `Review Gate` workflow exists on `main`, or all PRs to `main` will be blocked by a missing required check.

GitHub's required conversation resolution remains important even after `Review Gate` exists: it is the durable merge blocker for the specific case where a thread is resolved without any new PR/review/comment event to rerun the check automatically.

## Runtime Validation Boundary

The governance harness does **not** change Wink's runtime-validation policy:

- `Validation Status` in the PR template remains a declaration of what the author claims was validated
- hosted GitHub checks remain deterministic repo-policy/build/test signals
- manual macOS runtime validation is still required for runtime-sensitive work before release-readiness signoff

`Review Gate / Validate review state` blocks unresolved actionable review feedback. It does **not** assert that runtime-sensitive behavior has been validated on macOS.

## Runtime-Sensitive Detection

The current automation treats the following areas as runtime-sensitive:
- shortcut capture transport (`CarbonHotKeyProvider`, `EventTapCaptureProvider`, `ShortcutCaptureCoordinator`, `ShortcutManager`, `EventTapManager`)
- permissions and activation (`AccessibilityPermissionService`, `AppSwitcher`, `SkyLightBridge`, `ApplicationObservation`)
- launch and startup flow (`WinkApp`, `SettingsLauncher`, `LaunchAtLoginService`, `AppController`, `AppDelegate`)
- packaging/runtime scripts (`package-app.sh`, `package-dmg.sh`, `e2e-*`, `cgevent-helper.swift`)
- signing/runtime metadata (`entitlements.plist`, `Sources/Wink/Resources/Info.plist`)

If Wink grows new runtime-sensitive surfaces, update `.github/scripts/lib/project-automation.mjs` so the automation keeps matching reality.
