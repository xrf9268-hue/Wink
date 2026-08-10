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

4. **Immutable action references** (`.github/scripts/validate-workflow-pins.mjs`, run from `CI / Build and Test`)
   - Rejects any `uses:` reference that is not pinned to a full-length 40-character lowercase commit SHA
   - Requires a trailing `# vX.Y[.Z]` comment naming the exact upstream release the SHA came from
   - Rejects one upstream repository pinned to two different commits, or one commit documented as two different releases
   - Fails when it discovers zero definition files or zero references, so a bad glob cannot report a vacuous pass
   - Runs before the Swift toolchain steps, so a policy violation fails in seconds

5. **Bounded action updates** (`.github/dependabot.yml`)
   - Weekly grouped `github-actions` update PRs, capped at two open at a time
   - Dependabot rewrites the SHA and its `# vX.Y.Z` comment in the same commit, so the pin and its documentation never drift

6. **Versioned ruleset baseline** (`.github/governance/main-ruleset.json`)
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

## Immutable Action References And Upstream Updates

### Why a full SHA

GitHub resolves a tag or branch reference at run time. `actions/checkout@v6` executes whatever commit `v6` points at *today*, so an upstream owner — or anyone who compromises that account — can change what Wink's CI runs without a single byte changing in this repository. A full-length commit SHA is the only remote reference form the upstream owner cannot move.

Pinning is not the whole story: a pin that never advances accumulates unpatched upstream bugs. The two halves are split deliberately.

- `validate-workflow-pins.mjs` proves the reference **shape** is immutable and documented. It is offline and deterministic; it never contacts GitHub, so it cannot fail because an upstream repository is unreachable.
- Dependabot owns **advancing** those pins.

### The rules the validator enforces

| Rule | Rejected example |
| --- | --- |
| Remote references pin a 40-character lowercase commit SHA | `actions/checkout@v4`, `@main`, `@27d5ce7f`, `@27D5CE7F…` |
| Reusable workflows follow the same rule at job level | `org/repo/.github/workflows/build.yml@v1` |
| Every remote pin carries a version comment | `actions/upload-artifact@043fb46d…` with no `#` comment |
| The comment is exactly one release, at least `MAJOR.MINOR` | `# v7` — a moving tag, false as soon as upstream re-points it |
| Nothing follows the version in the comment | `# v7.0.1 (pinned, do not change)` |
| Local and `$/` self references carry no `@ref` | `./.github/actions/summarize@main`, `$/actions/summarize@v1` |
| Container references pin a digest | `docker://ghcr.io/org/scanner:latest` |
| One repository resolves to one commit repository-wide | `actions/upload-artifact` pinned to v7.0.0 in one workflow and v7.0.1 in another |
| One commit is documented as one release | `org/analysis/init@<sha> # v4.30.0` next to `org/analysis/analyze@<sha> # v4.29.0` |

The split-pin rules exist because Dependabot updates an action as a single dependency across every call site. A split pin is how a stale SHA survives an update — it is exactly how `internal-package.yml` ended up on `actions/upload-artifact` v7.0.0 while `release.yml` was on v7.0.1.

Sub-paths of one repository (`github/codeql-action/init` and `github/codeql-action/analyze`) share a repository, so they must share a SHA. The validator groups by `owner/repo` for this reason, case-insensitively — GitHub repository names are case-insensitive, so `Actions/checkout` and `actions/checkout` are one dependency.

`./…` local references and `$/…` self references are exempt from the SHA rule because both already resolve to the running commit; GitHub documents that a `$/` reference "must not include an `@{ref}` suffix", and the validator enforces that too.

The "nothing follows the version" rule is not style policing. Dependabot rewrites a pin comment only when the comment **ends with** the old version string; when there is trailing text it skips the rewrite for safety and bumps the SHA alone, which leaves the comment quietly lying about what is pinned.

### What the validator covers that GitHub's own setting does not

GitHub ships a repository policy, `Settings → Actions → General → Require actions to be pinned to a full-length commit SHA` (REST field `sha_pinning_required` on `/repos/{owner}/{repo}/actions/permissions`). It is worth enabling, but it is **not** a superset of this validator:

- GitHub's docs state plainly that reusable workflows "can still be referenced by tag" under that policy. Job-level `uses:` pinning is enforced here or nowhere.
- The policy says nothing about version comments, split pins, or comment/SHA agreement.
- A repo setting is invisible in the diff. The validator fails on the PR that introduces the violation, with a line annotation.

### Coverage gaps to keep in mind

- **Dependabot does not scan `.github/actions/**/action.yml`.** For the `github-actions` ecosystem, `directory: "/"` covers the root `action.yml` plus the files directly inside `.github/workflows` — it does not recurse into repo-local composite actions. The validator checks those files, but if Wink ever adds one, its pins must be advanced by hand.
- **SHA-pinned actions produce no Dependabot security alerts.** GitHub only alerts on actions using semantic versioning. Pinning trades alerting for immutability, which makes the weekly version-update PR the only lifecycle signal — do not let it sit unreviewed.

### Reviewing an upstream action update

1. Dependabot opens one grouped `ci: bump …` PR per week.
2. Confirm the new SHA really is the tag in the comment:
   ```bash
   gh api repos/OWNER/REPO/tags --paginate \
     --jq '.[] | select(.commit.sha=="<new-sha>") | .name'
   ```
   An annotated tag object SHA is **not** a valid `uses:` ref — always pin the commit the tag resolves to, which is what the command above returns.
3. Read the upstream release notes for behavior changes, not just the version delta.
4. `CI / Build and Test` re-runs the validator on the PR head; a bump that drops the version comment or splits a pin fails there.

Dependabot writes its own PR body, so it cannot include `Fixes #N` or the `Validation Status` checklist. `validate-pr-metadata.mjs` waives both requirements for `dependabot[bot]` only. It does **not** waive runtime sensitivity: a bot PR that touches a runtime-sensitive path fails and must be taken over as a maintainer PR.

### Known scanner limitation

The validator is a line scanner, not a YAML parser (the repository has no `package.json`, so it has no YAML dependency available). Every YAML shape GitHub honors is therefore either parsed or **failed closed**, never silently skipped:

| Shape | Handling |
| --- | --- |
| `uses:` inside `run: |` or `path: |` | ignored (block-scalar tracked) |
| `"uses": owner/repo@sha` | parsed as a real reference |
| `- { name: X, uses: … }` | `flow-mapping-reference` error |
| `steps: [ { uses: … } ]` | `flow-mapping-reference` error |
| `uses: >-` with the value on the next line | `block-scalar-reference` error |
| `uses: *alias` | `unparseable-reference` error |

Quoted *values* are blanked before flow detection while quoted *keys* are preserved, so `run: echo "{ uses: x }"` is a non-match and `{ "uses": … }` is not.

One known limitation remains: a literal mapping key named `uses:` nested under `with:` would be read as a reference. No GitHub action defines such an input, and the failure mode is a false positive a reviewer can see, not a silently accepted mutable reference.

### Repository-setting state

Reading or writing GitHub's own SHA-pinning policy needs a token belonging to a repository collaborator; a contributor token gets `403 You must have repository read permissions or have the repository Actions policies fine-grained permission`, regardless of its scopes. As of 2026-08-10 the owner account reports:

```console
$ gh api /repos/xrf9268-hue/Wink/actions/permissions
{"enabled":true,"allowed_actions":"all","sha_pinning_required":false}
```

So GitHub-side enforcement is **off**, and the repo-native validator is currently the only thing rejecting a mutable reference. To turn it on (note `enabled` is a required body field — a PUT carrying only `sha_pinning_required` is rejected, and the endpoint answers `204` with no body, so re-GET to confirm):

```bash
gh api -X PUT /repos/xrf9268-hue/Wink/actions/permissions \
  -F enabled=true -f allowed_actions=all -F sha_pinning_required=true
gh api /repos/xrf9268-hue/Wink/actions/permissions --jq '.sha_pinning_required'
```

`xrf9268-hue` is a user account rather than an organization, so there is no org-level layer above this; the repository setting is the only GitHub-side control point.

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
