# Release Pipeline Hardening Design

**Date:** 2026-06-11
**Branch:** main
**Issue:** to be split into three issues (see Issue Breakdown)
**Scope:** Harden the tag-driven release pipeline against appcast downgrade and concurrency accidents, move version/release-notes management behind local gate scripts, and add a full-chain dry-run rehearsal mode
**Reference:** `~/Projects/pomofox-design-reference` release pipeline (`.github/workflows/release.yml`, `scripts/bump-version.sh`, `scripts/release-notes.sh`, `scripts/release-dmg.sh`)

## Overview

Wink's release workflow already does the hard parts well: Developer ID signing, notarization, stapling, R2 distribution, and a feed-flips-last publish order. But the appcast handling and version management have gaps that the PomoFox reference pipeline solved:

- `scripts/generate-appcast.sh` regenerates `appcast.xml` from a staging directory containing **only the current release ZIP**, then the workflow overwrites the live feed on R2. Nothing validates that the new entry is actually newer than what is live. Two silent-failure modes follow:
  - Forgetting to bump `CFBundleVersion` ships a release that Sparkle clients never offer (equal or lower `sparkle:version`).
  - Re-running an old tag's release workflow replaces the live feed with the old version — a feed downgrade. Sparkle clients stop seeing the newest release entirely.
- The workflow concurrency group is keyed on `github.ref`, so two different tags (or a tag push plus a manual dispatch) can run concurrently and race on the R2 appcast upload. Last writer wins, in arbitrary order.
- Version bumping is "manually edit two Info.plist fields" per `docs/signing-and-release.md`. The tag↔`CFBundleShortVersionString` mismatch is caught only at release time; a stale `CFBundleVersion` is caught never (see above).
- Release notes are `gh release create --generate-notes` commit lists; there is no curated changelog.
- There is no way to rehearse the full release chain (sign → notarize → package → appcast) without publishing. `internal-package.yml` covers unsigned test builds only.
- Neither `release.yml` nor `ci.yml` caches SwiftPM build products.

This design closes those gaps with gate scripts that run locally and in CI, keeping `release.yml` a thin orchestrator in line with the repo's existing script-first style.

## Goals

- Make a feed downgrade impossible: every release must carry a `CFBundleVersion` strictly greater than the maximum `sparkle:version` already live on R2
- Preserve appcast history: new releases append entries instead of rewriting the feed to a single item
- Serialize all release runs so concurrent tags cannot race on the feed
- Move version bumping behind a gate script that enforces semver, monotonic `CFBundleVersion`, and a matching `CHANGELOG.md` section
- Replace auto-generated release notes with curated `CHANGELOG.md` sections, extracted by script and gated at release time
- Add a dry-run mode to `release.yml` that exercises the full chain (gate → test → sign → notarize → package → appcast → validate) and uploads artifacts without publishing
- Publish GitHub Releases atomically: draft → upload assets → publish, feed flip stays last
- Cache SwiftPM build products in `release.yml` and `ci.yml`

## Non-Goals

- In-app "What's New" UI (PomoFox-style launch popup and catalog) — a product feature, deferred to its own issue
- Changing the distribution channels (R2 + GitHub Releases stay as-is)
- Changing the signing, notarization, or stapling flow — Wink's chain is already stronger than the reference (PomoFox ships adhoc-signed with notarization stubbed)
- Sparkle delta updates (`--maximum-deltas 0` stays)
- Phased rollouts, release channels, or beta feeds

## Current Context

- [.github/workflows/release.yml](/Users/yvan/developer/Wink/.github/workflows/release.yml) — tag-driven release: readiness gate (secrets), sign, notarize, staple, package DMG/ZIP, generate appcast, upload to R2, GitHub Release, feed flip last
- [scripts/generate-appcast.sh](/Users/yvan/developer/Wink/scripts/generate-appcast.sh) — runs Sparkle `generate_appcast` over a fresh staging dir holding only the current ZIP; output overwrites `build/appcast.xml`
- [.github/workflows/internal-package.yml](/Users/yvan/developer/Wink/.github/workflows/internal-package.yml) — unsigned internal DMG artifact on push to main; not a release rehearsal
- [docs/signing-and-release.md](/Users/yvan/developer/Wink/docs/signing-and-release.md) — documents the manual version bump (edit both Info.plist fields by hand)
- `Sources/Wink/Resources/Info.plist` — `CFBundleShortVersionString` 0.4.1, `CFBundleVersion` 5 (integer, Sparkle compares this as `sparkle:version`)
- No `CHANGELOG.md` exists; no What's New mechanism exists in `Sources/`
- The repo has a bats test harness precedent (`scripts/e2e-lib.bats`)

### Lessons imported from the PomoFox reference

- `generate_appcast` keeps existing appcast entries when the old `appcast.xml` is present where it scans/writes, but **defaults to keeping only the newest 3** — `--maximum-versions 0` is required to stop it pruning history
- **Never place old archives (ZIP/DMG) in the staging directory**: `--download-url-prefix` rewrites the URL of *every* entry whose archive is present in the directory, which would re-point old entries at files that may not exist under the new prefix
- `generate_appcast` silently rewrites an existing entry in place when two archives carry the same `sparkle:version` instead of erroring — which is why the strictly-greater gate must run *before* appcast generation
- Only HTTP 404 may be treated as "first release"; any other fetch failure (5xx, network) must hard-fail, or a transient outage silently discards feed history

## Approaches Considered

### 1. Workflow-inline gates (PomoFox style)

Put the feed fetch, downgrade check, and notes extraction directly into `release.yml` run steps.

Pros:
- Single file to read; matches the reference implementation closely

Cons:
- Not runnable or testable locally; the gate logic is exactly the kind of code that must be trustworthy
- Conflicts with Wink's existing style where `package-app.sh`, `package-dmg.sh`, `generate-appcast.sh` do the work and workflows orchestrate

### 2. Gate scripts + thin workflow (chosen)

New `scripts/verify-release-feed.sh`, `scripts/bump-version.sh`, `scripts/release-notes.sh`; `release.yml` calls them. Bats tests cover the scripts.

Pros:
- Locally reproducible and unit-testable; consistent with the repo's script-first layout
- The same gate runs in dry-run rehearsals

Cons:
- Three new scripts to maintain

### 3. Minimal fix

Only the downgrade gate and the serial concurrency group.

Pros:
- Smallest diff, fixes the two real accident paths

Cons:
- Leaves CHANGELOG, bump tooling, and rehearsal mode for another round; the stale-`CFBundleVersion` failure mode keeps relying on a release-time error instead of a local gate

**Decision: Approach 2.**

## Detailed Design

### 1. Feed safety gate — new `scripts/verify-release-feed.sh`

Runs in the release job **before** `swift test` (fail fast — notarization wall-clock is expensive) and also as the first step of appcast generation in dry runs.

Behavior:

- Inputs: `SPARKLE_PUBLIC_BASE_URL` (env; the R2 public base), Info.plist path (defaults to the repo's)
- `curl -sSL --retry 3` the live `appcast.xml` to `build/appcast.xml`, capturing the HTTP status
- **200** → parse the maximum `sparkle:version` across all entries; if none parse, hard-fail ("feed corrupt?"). Require Info.plist `CFBundleVersion` to be a non-negative integer **strictly greater** than the maximum; otherwise hard-fail with a "forgot to bump?" message
- **404** → first release: remove the empty download file, exit 0
- **anything else** (5xx, connection failure) → hard-fail; a fetch error must never be treated as a first release
- On success with a restored feed, leave `build/appcast.xml` in place for the appcast generation step to merge against

Failure messages name the exact remediation (`scripts/bump-version.sh`, re-run, or feed inspection).

### 2. Appcast history preservation — modify `scripts/generate-appcast.sh`

- Add `--maximum-versions 0` to the `generate_appcast` invocation
- Merge against the restored feed: ensure the old `appcast.xml` restored by the gate participates in generation so existing entries are preserved and the new entry is appended. The exact placement (`-o` target vs. a copy inside the staging dir) is a `generate_appcast` behavioral detail that **must be pinned down by a local rehearsal during implementation**, with an assertion that (a) old entries survive and (b) old entries' URLs are not rewritten
- Keep the staging dir containing **only** the new ZIP (and optional release-notes file) — never old archives
- Keep `--maximum-deltas 0` and the existing key-handling paths unchanged

### 3. Serial releases — modify `.github/workflows/release.yml`

```yaml
concurrency:
  group: ${{ github.workflow }}
  cancel-in-progress: false
```

All release runs queue globally instead of per-ref. One-line change.

### 4. Version bump gate — new `scripts/bump-version.sh`

`./scripts/bump-version.sh X.Y.Z`:

- Reject non-three-part-semver arguments
- Reject bumping to the current `CFBundleShortVersionString`
- Require a `## X.Y.Z` section heading in `CHANGELOG.md` (notes are creative content — written by a human first; the script only gates)
- Validate the current `CFBundleVersion` is a non-negative integer, then write `CFBundleShortVersionString = X.Y.Z` and `CFBundleVersion += 1` via PlistBuddy
- Print the follow-up steps: `swift test` → commit → `git tag vX.Y.Z` → `git push origin main --tags`

### 5. Curated release notes — new `CHANGELOG.md` + new `scripts/release-notes.sh`

- `CHANGELOG.md` at the repo root, newest first, one `## X.Y.Z` section per release, hand-written
- `scripts/release-notes.sh X.Y.Z` prints the body of that section (everything until the next `## ` heading or EOF), hard-failing if the section is missing or empty
- The release job calls it both as a gate (early, alongside the feed gate) and to produce the GitHub Release body, replacing `--generate-notes`
- Sparkle side: pass `SPARKLE_FULL_RELEASE_NOTES_URL` (already supported by `generate-appcast.sh`) pointing at the GitHub Releases page; no HTML embedding in the appcast

### 6. Dry-run rehearsal — modify `.github/workflows/release.yml`

- `workflow_dispatch` inputs become:
  - `release_tag` (optional): an existing `v*` tag to operate on; **empty = rehearse the current default branch**, which forces dry run regardless of the flag
  - `dry_run` (boolean, default `true`): build everything, publish nothing
- Tag-push behavior is unchanged (real release, `dry_run=false`)
- A dry run executes the full chain: feed gate → notes gate → `swift test` → sign → notarize → staple → DMG/ZIP → appcast → artifact validation, then uploads `build/` release artifacts via `actions/upload-artifact` and **skips** the R2 uploads and the GitHub Release steps
- The tag↔`CFBundleShortVersionString` equality check is skipped only in branch-rehearsal mode (no tag to compare); the feed downgrade gate still runs so a rehearsal also detects a forgotten bump
- Division of labor with `internal-package.yml`: internal-package = fast unsigned test build on main pushes; dry run = full signed release rehearsal

### 7. Atomic GitHub Release — modify the publish step

- `gh release create --draft` with the DMG and the CHANGELOG-derived notes → `gh release edit --draft=false`
- Keep the existing idempotent re-run handling (release already exists → `gh release upload --clobber`, then ensure published)
- Feed flip (appcast upload to R2) stays the final step — Wink already orders this correctly; preserve it

### 8. SwiftPM cache — modify `release.yml` and `ci.yml`

```yaml
- uses: actions/cache@<pinned-sha> # v5
  with:
    path: .build
    key: spm-${{ runner.os }}-${{ hashFiles('Package.resolved') }}
    restore-keys: spm-${{ runner.os }}-
```

Pin the action by commit SHA, matching the repo's existing pinning convention.

## Error Handling Summary

| Failure | Where caught | Outcome |
|---|---|---|
| Forgot `CFBundleVersion` bump | `bump-version.sh` locally; `verify-release-feed.sh` in CI | Hard fail before any build work |
| Re-run of an old tag | `verify-release-feed.sh` (old build ≤ live max) | Hard fail; feed never downgraded |
| Two tags pushed close together | Serial concurrency group | Second run queues; its feed gate then sees the first run's published feed |
| Live feed fetch 5xx/network error | `verify-release-feed.sh` | Hard fail; never misread as first release |
| Live feed present but unparseable | `verify-release-feed.sh` | Hard fail ("feed corrupt?") |
| Tag without `CHANGELOG.md` section | `bump-version.sh` locally; notes gate in CI | Hard fail before build work |
| Re-run after partial publish | Existing idempotent release step + appcast merge | Converges; assets clobbered, feed unchanged or appended |

## Testing

- **Bats unit tests** (extending the `e2e-lib.bats` precedent) for the three new scripts:
  - `verify-release-feed.sh`: mock `curl` via PATH shim; cases for 200-with-greater-build, 200-with-equal/lower-build, 200-unparseable, 404, 500, network failure
  - `release-notes.sh`: fixture CHANGELOG; cases for present, missing, and empty sections
  - `bump-version.sh`: temp Info.plist + fixture CHANGELOG; cases for bad semver, same version, missing section, non-integer build, successful bump
- **Appcast merge rehearsal** (implementation-time, local): build an "old appcast + new ZIP" fixture, run `generate-appcast.sh`, assert old entries survive with unchanged URLs and the new entry is appended and signed
- **Full-chain dry run** in CI after each issue lands, as the acceptance check
- **Docs**: update `docs/signing-and-release.md` (bump script, CHANGELOG requirement, dry-run usage) in the same PRs that change behavior

## Issue Breakdown (dependency order)

1. **Issue A — Feed safety**: `verify-release-feed.sh` + appcast history preservation + serial concurrency (Design §1–3). Closes both accident paths; highest priority
2. **Issue B — Version & notes management**: `CHANGELOG.md` + `bump-version.sh` + `release-notes.sh` + release-body wiring (Design §4–5). The bump script gates on CHANGELOG, so these ship together
3. **Issue C — Rehearsal & robustness**: dry-run mode + atomic draft→publish + SPM cache (Design §6–8)

Each issue is one PR through the existing review-gate flow.
