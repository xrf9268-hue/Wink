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
- Preserve appcast history: old entries survive unchanged and each release adds its entry, instead of rewriting the feed to a single item
- Serialize all release runs so concurrent tags cannot race on the feed
- Move version bumping behind a gate script that enforces semver, monotonic `CFBundleVersion`, and a matching `CHANGELOG.md` section
- Replace auto-generated release notes with curated `CHANGELOG.md` sections, extracted by script and gated at release time
- Add a dry-run mode to `release.yml` that exercises the full chain (gate → test → sign → notarize → package → appcast → validate) and uploads artifacts without publishing
- Wire curated notes into the GitHub Release publish step, keeping it idempotent across re-runs; feed flip stays last
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

Runs in the release job **before** `swift test` (fail fast — notarization wall-clock is expensive).

Behavior:

- Inputs: `SPARKLE_PUBLIC_BASE_URL` (env; the R2 public base), Info.plist path (defaults to the repo's), and a mode flag: `--mode release` (default, enforcing) or `--mode rehearse` (dry runs: fetch + parse + report; fail only on fetch/parse errors, never on the version comparison — between releases main's `CFBundleVersion` legitimately equals the live maximum, so an enforcing gate would make every rehearsal fail by construction)
- Fetch the live `appcast.xml` to `build/live-appcast.xml` (a dedicated path so later packaging steps cannot plausibly clobber it), capturing the HTTP status with the `|| echo 000` pattern so transport-level curl failures are not eaten by `set -euo pipefail`; use `--retry 3 --retry-all-errors` (plain `--retry` skips connection-refused)
- **200** → parse the maximum `sparkle:version` across all entries, accepting both syntactic forms (`<sparkle:version>N</sparkle:version>` element and the legacy `sparkle:version="N"` enclosure attribute); if none parse, hard-fail ("feed corrupt?"). In `release` mode, require Info.plist `CFBundleVersion` to be a non-negative integer **strictly greater** than the maximum; otherwise hard-fail. The error message distinguishes the two causes: equal to live max → "this version is already live — re-publishing a released version is not supported, bump instead"; lower → "forgot to run scripts/bump-version.sh?"
- **404** → hard-fail unless `WINK_ALLOW_FIRST_RELEASE=1` is explicitly set. A wrong `SPARKLE_PUBLIC_BASE_URL` also yields 404, and silently treating it as a first release would fork the feed at a bogus prefix. Wink's feed already exists, so the opt-in is a one-time escape hatch, not a normal path
- **anything else** (5xx, connection failure) → hard-fail; a fetch error must never be treated as a first release
- On success with a restored feed, `build/live-appcast.xml` is the handoff artifact for appcast generation (§2)

Consequence, stated deliberately: re-running a tag **after** a fully successful release (feed already flipped) is blocked by the gate. The documented manual re-publish flow in `docs/signing-and-release.md` changes accordingly — repairing a published release means bumping to a new version, not re-running the old tag. Partial-failure re-runs (anything that died before the feed flip) still converge, because the feed flip is the last step.

### 2. Appcast history preservation — modify `scripts/generate-appcast.sh`

- Add `--maximum-versions 0` to the `generate_appcast` invocation (the tool defaults to keeping only the newest 3 entries)
- Merge against the restored feed: `generate_appcast` merges off an appcast file present in the **archives directory it scans**, not the `-o` target — so the script copies `build/live-appcast.xml` to `$STAGING_DIR/appcast.xml` before invoking the tool. The script takes the restored-feed path via env (`SPARKLE_RESTORED_APPCAST`, default `build/live-appcast.xml`); if the variable points at a declared-but-missing file it hard-fails rather than silently regenerating a single-entry feed. Absent variable and absent file = explicit fresh-feed mode (first release only)
- The merge semantics **must be pinned down by a local rehearsal during implementation**, asserting that (a) old entries are preserved unchanged (count, `sparkle:version` values, URLs, `edSignature`s), (b) the new entry is present and signed, and (c) per-release options like `--full-release-notes-url` do not rewrite old entries
- Keep the staging dir containing **only** the new ZIP, the optional release-notes file, and the restored `appcast.xml` — never old archives (`--download-url-prefix` rewrites the URL of every entry whose archive is present in the directory)
- Keep `--maximum-deltas 0` and the existing key-handling paths unchanged
- Strengthen the workflow's "Verify appcast" step from `test -f` to runtime assertions: the new `sparkle:shortVersionString` entry exists, it carries an `edSignature`, and when a feed was restored, the output's entry count is ≥ the restored feed's entry count

### 3. Serial releases — modify `.github/workflows/release.yml`

```yaml
concurrency:
  group: ${{ github.workflow }}
  cancel-in-progress: false
```

All release runs queue globally instead of per-ref. One-line change.

Known GitHub semantics, accepted: a concurrency group holds at most one running plus one pending run, so pushing 3+ tags in quick succession cancels the intermediate pending run. Remediation is simply re-running the cancelled workflow — the feed gate makes re-runs safe in any order (an out-of-date run fails the gate instead of downgrading the feed).

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
- Sparkle side: pass `SPARKLE_FULL_RELEASE_NOTES_URL` (already supported by `generate-appcast.sh`) pointing at the **per-tag** release page (`…/releases/tag/vX.Y.Z`); no HTML embedding in the appcast. The value changes per release while old entries must keep theirs — covered by the §2 rehearsal assertion (c)

### 6. Dry-run rehearsal — modify `.github/workflows/release.yml`

- `workflow_dispatch` inputs become:
  - `release_tag` (optional): an existing `v*` tag to operate on; **empty = rehearse the dispatched ref**, which forces dry run regardless of the flag
  - `dry_run` (boolean, default `true`): build everything, publish nothing
- Tag-push behavior is unchanged (real release, `dry_run=false`)
- A dry run executes the full chain: feed gate (`--mode rehearse`, §1) → notes gate → `swift test` → sign → notarize → staple → DMG/ZIP → appcast → artifact validation, then uploads `build/` release artifacts via `actions/upload-artifact` and **skips** the R2 uploads and the GitHub Release steps
- Ref-rehearsal mode (empty `release_tag`) skips both the "Checkout manual release tag" step and the tag↔`CFBundleShortVersionString` equality check (there is no tag to compare); the version for the notes gate derives from `CFBundleShortVersionString`
- Secrets: dry runs require the same full secret set as real releases — rehearsing the *signed* chain is the point, and this repo has all secrets configured. The existing `release-readiness` job stays as-is, with one adjustment: its `release_ref` output falls back to `github.ref_name` when the `release_tag` input is empty
- Division of labor with `internal-package.yml`: internal-package = fast unsigned test build on main pushes; dry run = full signed release rehearsal

### 7. GitHub Release publish step — notes wiring, no draft flow

The originally considered draft → upload → publish sequence is **dropped**: `gh release view` resolves releases by tag ref and cannot see drafts (drafts have no tag ref until published), so a re-run after a crash between create-draft and publish would create duplicate drafts. The atomicity it buys is negligible here — `gh release create` already attaches the DMG atomically at creation, and the real publish boundary is the feed flip, which is already last.

What changes instead:

- `gh release create` switches from `--generate-notes` to `--notes-file` fed by `scripts/release-notes.sh`
- The existing-release re-run path additionally runs `gh release edit --notes-file` so a re-run refreshes the body, not just the asset (`--clobber`)
- Feed flip (appcast upload to R2) stays the final step — Wink already orders this correctly; preserve it

### 8. SwiftPM cache — modify `release.yml` and `ci.yml`

```yaml
- uses: actions/cache@<pinned-sha> # v5, pin by commit SHA per repo convention
  with:
    path: .build
    key: spm-${{ runner.os }}-xcode${{ env.XCODE_VERSION }}-${{ hashFiles('Package.resolved') }}
    restore-keys: spm-${{ runner.os }}-xcode${{ env.XCODE_VERSION }}-
```

Include the toolchain in the key (an `xcodebuild -version`-derived env value, captured in a prior step) so a runner-image Xcode bump does not restore stale `.build` products.

## Error Handling Summary

| Failure | Where caught | Outcome |
|---|---|---|
| Forgot `CFBundleVersion` bump | `bump-version.sh` locally; `verify-release-feed.sh` in CI | Hard fail before any build work |
| Re-run of an old tag | `verify-release-feed.sh` (old build ≤ live max) | Hard fail; feed never downgraded |
| Re-run of the current tag after a fully successful release | `verify-release-feed.sh` (build = live max) | Hard fail with "already live — bump instead"; deliberate behavior change vs. the documented re-publish flow |
| Re-run after partial failure (died before feed flip) | Idempotent release step (`--clobber` + `edit --notes-file`) + appcast merge | Converges; gate passes because the feed never flipped |
| Two tags pushed close together | Serial concurrency group | Second run queues; its feed gate then sees the first run's published feed |
| 3+ tags pushed in quick succession | GitHub concurrency semantics (1 running + 1 pending) | Intermediate pending run is cancelled; re-run it manually — the gate makes any re-run order safe |
| Live feed fetch 5xx/network error | `verify-release-feed.sh` | Hard fail; never misread as first release |
| Live feed 404 (deleted, or wrong base URL) | `verify-release-feed.sh` | Hard fail unless `WINK_ALLOW_FIRST_RELEASE=1` is explicitly set |
| Live feed present but unparseable | `verify-release-feed.sh` | Hard fail ("feed corrupt?") |
| Restored feed declared but missing at generation time | `generate-appcast.sh` | Hard fail instead of silently regenerating a single-entry feed |
| Generated appcast missing the new entry, its signature, or restored history | Strengthened "Verify appcast" workflow step | Hard fail before any upload |
| Tag without `CHANGELOG.md` section | `bump-version.sh` locally; notes gate in CI | Hard fail before build work |

## Testing

- **Bats unit tests** (extending the `e2e-lib.bats` precedent) for the three new scripts, run in a new `ci.yml` step (install `bats-core` via Homebrew on the macOS runner):
  - `verify-release-feed.sh`: mock `curl` via PATH shim; cases for 200-with-greater-build, 200-with-equal/lower-build (both modes — `release` fails, `rehearse` passes), 200-unparseable, both `sparkle:version` syntactic forms, 404 with and without `WINK_ALLOW_FIRST_RELEASE`, 500, network failure
  - `release-notes.sh`: fixture CHANGELOG; cases for present, missing, and empty sections
  - `bump-version.sh`: temp Info.plist + fixture CHANGELOG; cases for bad semver, same version, missing section, non-integer build, successful bump
- **Appcast merge rehearsal** (implementation-time, local): build an "old appcast + new ZIP" fixture, run `generate-appcast.sh`, assert the §2 invariants (old entries unchanged including URLs and signatures; new entry present and signed; per-release options don't touch old entries)
- **Acceptance per issue**: Issues A and B — bats green plus the next real release passing its strengthened verify steps; Issue C — a full-chain dry run from `workflow_dispatch`
- **Docs**: update `docs/signing-and-release.md` (bump script, CHANGELOG requirement, dry-run usage, the new "bump instead of re-running a published tag" rule) in the same PRs that change behavior

## Issue Breakdown (dependency order)

1. **Issue A — Feed safety**: `verify-release-feed.sh` + appcast history preservation + serial concurrency (Design §1–3). Closes both accident paths; highest priority
2. **Issue B — Version & notes management**: `CHANGELOG.md` + `bump-version.sh` + `release-notes.sh` + publish-step notes wiring (Design §4–5, §7). The bump script gates on CHANGELOG, so these ship together
3. **Issue C — Rehearsal & efficiency**: dry-run mode + SPM cache (Design §6, §8)

Each issue is one PR through the existing review-gate flow.
