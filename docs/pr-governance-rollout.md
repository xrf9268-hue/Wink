# PR Governance Rollout

This runbook captures the recommended rollout order for the PR governance and review-gate changes on `codex/pr-governance-harness`.

## Recommended PR Title

`ci: add PR governance review gate and ruleset baseline`

## Rollout Order

1. Open a PR from `codex/pr-governance-harness` into `main`.
2. Verify the new required check behavior on that PR.
3. Merge the PR to `main`.
4. Apply `.github/governance/main-ruleset.json` as the live repository ruleset.
5. Run one small smoke-test PR against `main` after the ruleset is active.

Do not apply the ruleset before the workflow changes are on `main`, or `main` will be blocked by a missing `Review Gate / Validate review state` check.

## PR Body Draft

Replace the issue number in the first line before opening the PR.

```md
Fixes #<issue>

## Summary
- add a repository-owned review gate that fails on `CHANGES_REQUESTED` and unresolved actionable inline review threads
- check in the desired `main` ruleset baseline as `.github/governance/main-ruleset.json`
- document the rollout order and the boundary between deterministic merge gates and manual macOS runtime validation

## Testing
- [x] `node --test .github/scripts/tests/project-automation.test.mjs .github/scripts/tests/main-ruleset.test.mjs .github/scripts/tests/review-state.test.mjs`
- [x] `ruby -e 'require "yaml"; YAML.load_file(".github/workflows/review-gate.yml"); puts "review-gate.yml OK"'`
- [x] `git diff --check`
- [x] Additional validation noted below when needed

## Validation Status
- [x] Not runtime-sensitive
- [ ] macOS runtime validation pending
- [ ] macOS runtime validation complete

## Notes
- This PR intentionally does not apply the live GitHub ruleset yet; the ruleset should be applied only after these workflow changes land on `main`.
- GitHub Actions does not expose a dedicated review-thread resolved/unresolved workflow trigger, so a pure thread-resolution change may require another PR/review/comment event or a manual rerun before `Review Gate / Validate review state` refreshes.
```

The summary bullets above are already suitable for the PR body. If you want a shorter version, keep the first two bullets and move the runtime-validation boundary note into `## Notes`.

## PR Verification Checklist

- Confirm the PR shows all three checks:
  - `CI / Build and Test`
  - `PR Metadata / Validate PR metadata`
  - `Review Gate / Validate review state`
- Leave one unresolved inline review thread on a changed line and ensure a review-related event occurs.
- Confirm `Review Gate / Validate review state` fails.
- Resolve the thread or push a change that makes it outdated.
- If no new PR/review/comment activity occurs after resolution, manually rerun the review-gate workflow.
- Confirm `Review Gate / Validate review state` passes.
- Confirm the PR still uses `Not runtime-sensitive` truthfully.

## Post-Merge Ruleset Apply

Inspect existing rulesets:

```bash
gh api repos/xrf9268-hue/Quickey/rulesets \
  -H "Accept: application/vnd.github+json" \
  --jq '.[] | {id, name, target, enforcement}'
```

Create the ruleset if it does not exist:

```bash
gh api repos/xrf9268-hue/Quickey/rulesets \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  --input .github/governance/main-ruleset.json
```

Update the ruleset if it already exists:

```bash
RULESET_ID="$(gh api repos/xrf9268-hue/Quickey/rulesets --jq '.[] | select(.name=="main merge governance") | .id')"
gh api "repos/xrf9268-hue/Quickey/rulesets/$RULESET_ID" \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  --input .github/governance/main-ruleset.json
```

Verify the live ruleset after apply:

```bash
gh api repos/xrf9268-hue/Quickey/rulesets \
  -H "Accept: application/vnd.github+json" \
  --jq '.[] | select(.name=="main merge governance")'
```

The live ruleset should require:

- pull requests for `main`
- one approval
- stale review dismissal or latest-push freshness
- resolved conversations
- these required checks:
  - `CI / Build and Test`
  - `PR Metadata / Validate PR metadata`
  - `Review Gate / Validate review state`

## Smoke Test After Ruleset Apply

Open a small documentation-only or comments-only PR against `main` and verify:

- the PR cannot merge without the required checks
- the PR cannot merge while an inline conversation remains unresolved
- the PR can merge after the conversation is resolved and the review gate is rerun or refreshed

## Known Caveat

GitHub's required conversation resolution is the durable blocker for thread resolution. `Review Gate / Validate review state` refreshes on PR activity, review activity, and review-comment activity, but not on a pure review-thread resolve/unresolve event.
