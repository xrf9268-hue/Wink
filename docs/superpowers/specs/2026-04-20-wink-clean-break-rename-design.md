# Wink Clean-Break Rename Design

**Date:** 2026-04-20
**Branch:** codex/wink-clean-break-rename
**Issue:** #183
**Scope:** Replace the in-repo `Quickey` product identity with `Wink` as a clean break across source layout, runtime identity, packaging, tests, scripts, CI, and documentation, with no backward-compatibility layer for old names, paths, or bundle identifiers

## Overview

The repository currently treats `Quickey` as a first-class runtime identity, not just a display label. The name is embedded in the Swift package and executable names, source and test directory layout, `Info.plist`, bundle identifier, Application Support and debug-log paths, shell scripts, CI checks, worker-facing static content, and maintainer documentation. A partial rename would leave mixed identities and recurring cleanup debt.

This design executes a full clean-break rename to `Wink` inside the repository. After the change, the app should present itself, build itself, log itself, package itself, and document itself as `Wink`. The change explicitly does **not** preserve compatibility with legacy `Quickey` paths, bundle identifiers, TCC expectations, or login-item state. For a still-in-development app, the simpler and more honest model is that `Wink` is a new runtime identity.

## Goals

- Rename the app from `Quickey` to `Wink` across all in-repo product identity surfaces
- Change the bundle identifier from `com.quickey.app` to `com.wink.app`
- Rename the Swift package, executable target, test target, and source/test root folders to `Wink`
- Update default runtime storage and logging paths from `Quickey` to `Wink`
- Update packaging scripts, E2E harnesses, CI verification, and project automation to use `Wink`
- Update docs and static content so the repository consistently describes the product as `Wink`
- Make the clean-break policy explicit so no compatibility shim or migration layer is accidentally reintroduced

## Non-Goals

- Preserving read/write compatibility with `~/Library/Application Support/Quickey`
- Preserving read/write compatibility with `~/.config/Quickey/debug.log`
- Preserving the old bundle identifier `com.quickey.app`
- Preserving old TCC grants, launch-at-login registrations, or path-based macOS identity continuity
- Renaming the GitHub repository slug or the local checkout directory name; those are owner/environment actions outside normal repo file edits
- Redesigning icons, brand visuals, or marketing copy beyond required product-name substitution

## Current Context

- [Package.swift](/Users/yvan/developer/Quickey/Package.swift) still defines `Quickey` as the package name, executable product, executable target, and test target dependency
- [Sources/Quickey/Resources/Info.plist](/Users/yvan/developer/Quickey/Sources/Quickey/Resources/Info.plist) still defines `Quickey` as `CFBundleExecutable`, `CFBundleName`, `CFBundleDisplayName`, and `com.quickey.app` as `CFBundleIdentifier` and `OSLogPreferences` subsystem
- [Sources/Quickey/Services/StoragePaths.swift](/Users/yvan/developer/Quickey/Sources/Quickey/Services/StoragePaths.swift) still writes app support data under `Application Support/Quickey`
- [scripts/package-app.sh](/Users/yvan/developer/Quickey/scripts/package-app.sh), [scripts/package-dmg.sh](/Users/yvan/developer/Quickey/scripts/package-dmg.sh), and [scripts/e2e-lib.sh](/Users/yvan/developer/Quickey/scripts/e2e-lib.sh) still use `Quickey.app`, `Quickey-<version>.dmg`, `com.quickey.app`, and Quickey-owned log/data paths as the packaging and validation defaults
- [.github/workflows/ci.yml](/Users/yvan/developer/Quickey/.github/workflows/ci.yml) still verifies `build/Quickey.app` and `build/Quickey-<version>.dmg`
- [.github/scripts/lib/project-automation.mjs](/Users/yvan/developer/Quickey/.github/scripts/lib/project-automation.mjs) still classifies runtime-sensitive files under `Sources/Quickey/...`
- The repository still contains recently merged documentation asserting that issue #183 was deferred, including [docs/archive/issue-183-wink-rename-evaluation.md](/Users/yvan/developer/Quickey/docs/archive/issue-183-wink-rename-evaluation.md) and [docs/handoff-notes.md](/Users/yvan/developer/Quickey/docs/handoff-notes.md)

## Approved Product Decisions

| Topic | Decision |
|------|----------|
| Rename strategy | Full clean break |
| Product name | `Wink` |
| Bundle identifier | `com.wink.app` |
| Storage compatibility | None; old Quickey paths are ignored |
| TCC/login-item continuity | None; macOS should treat Wink as a new app identity |
| Repo-internal layout | Rename source/test roots and SPM targets to `Wink` |
| Docs/history handling | Update docs to reflect that rename is now executed, not deferred |

## Approaches Considered

### 1. Full clean-break rename across all repository identity surfaces

Rename every in-repo `Quickey` identity anchor to `Wink`, including source layout, targets, bundle metadata, storage/logging paths, scripts, CI, tests, worker content, and documentation.

Pros:
- Matches the user's stated goal of leaving no naming debt behind
- Keeps runtime identity, package identity, and docs aligned
- Avoids maintaining dual-name logic during an active development phase
- Simplifies reasoning about future validation because there is only one product identity

Cons:
- Invalidates any local `Quickey` runtime data and permissions
- Requires broad but mechanical file/path updates
- Demands a full macOS revalidation under the new identity

### 2. Runtime-only rename while leaving package and directory names as `Quickey`

Rename only user-visible and runtime metadata, but leave SPM target names, folder names, and test target names untouched.

Pros:
- Smaller initial patch
- Lower immediate refactor risk

Cons:
- Leaves mixed identity debt in the repo indefinitely
- Makes tests, paths, and automation harder to understand
- Conflicts with the explicit clean-break requirement

### 3. Dual-identity migration layer

Ship `Wink`, but keep fallback reads from old `Quickey` paths and optionally preserve old bundle-related assumptions where possible.

Pros:
- Gentler for existing local developer state
- More forgiving for a hypothetical external beta cohort

Cons:
- Directly violates the requested clean-break policy
- Introduces migration and fallback logic that would need maintenance and testing
- Keeps the old identity alive in code and docs

### Recommendation

Use approach 1. The app is still in development, and the user explicitly wants no naming debt. A full clean break is the cleanest long-term architecture, even though it requires broader edits and fresh macOS validation.

## Design

### 1. Repository and Swift Package Identity

The Swift package should be renamed from `Quickey` to `Wink` in [Package.swift](/Users/yvan/developer/Quickey/Package.swift). This includes:

- `name: "Wink"` for the package
- `.executable(name: "Wink", targets: ["Wink"])`
- executable target name `Wink`
- test target name `WinkTests`
- test target dependency updated from `Quickey` to `Wink`

The source and test directory roots should be renamed to match:

- `Sources/Quickey/` -> `Sources/Wink/`
- `Tests/QuickeyTests/` -> `Tests/WinkTests/`

The repository should not keep a stale internal `Quickey` target name while presenting itself externally as `Wink`. The package graph, folder layout, and test imports must all agree on the new name.

### 2. Runtime Identity and macOS Metadata

The canonical app identity should move to `Wink` in [Sources/Quickey/Resources/Info.plist](/Users/yvan/developer/Quickey/Sources/Quickey/Resources/Info.plist), which will move with the renamed source root. The following keys should change:

- `CFBundleExecutable` -> `Wink`
- `CFBundleIdentifier` -> `com.wink.app`
- `CFBundleName` -> `Wink`
- `CFBundleDisplayName` -> `Wink`
- `OSLogPreferences` subsystem key -> `com.wink.app`

Any runtime logger subsystem or dispatch queue label that still bakes in `quickey` should be updated to a `wink` equivalent so diagnostics and crash/log metadata do not keep the old identity.

This is a true runtime identity reset. We should assume:

- old Accessibility/Input Monitoring grants do not carry over
- old login-item registration state does not carry over
- any docs or scripts that instruct maintainers to reset `com.quickey.app` must be updated to `com.wink.app`

### 3. Clean-Break Storage and Logging

The repository currently uses both Application Support and `~/.config` paths as persistent identity anchors. Those should move cleanly:

- `Application Support/Quickey` -> `Application Support/Wink`
- `~/.config/Quickey/debug.log` -> `~/.config/Wink/debug.log`

[Sources/Quickey/Services/StoragePaths.swift](/Users/yvan/developer/Quickey/Sources/Quickey/Services/StoragePaths.swift) should update `appDirectoryName` to `Wink`.

Any code or shell defaults referencing:

- `shortcuts.json`
- `usage.sqlite`
- debug log paths
- test harness file locations

must point only at `Wink` locations after the change. This design intentionally rejects a "read old path, write new path" bridge. If legacy `Quickey` data exists on a machine, it is treated as obsolete development residue, not as a migration source.

### 4. Packaging, Scripts, and CI

All package/build artifacts should move to the `Wink` identity:

- `.build/release/Wink`
- `build/Wink.app`
- `build/Wink-<version>.dmg`

The following script surfaces must be updated:

- [scripts/package-app.sh](/Users/yvan/developer/Quickey/scripts/package-app.sh)
- [scripts/package-dmg.sh](/Users/yvan/developer/Quickey/scripts/package-dmg.sh)
- [scripts/e2e-lib.sh](/Users/yvan/developer/Quickey/scripts/e2e-lib.sh)
- [scripts/e2e-full-test.sh](/Users/yvan/developer/Quickey/scripts/e2e-full-test.sh)
- related `scripts/e2e-test-*.sh` helpers and Bats fixtures

The defaults embedded in those scripts should become:

- app path `build/Wink.app`
- executable path `Wink.app/Contents/MacOS/Wink`
- bundle id `com.wink.app`
- log path `~/.config/Wink/debug.log`
- shortcuts file `~/Library/Application Support/Wink/shortcuts.json`

CI should verify the renamed bundle and DMG paths in [.github/workflows/ci.yml](/Users/yvan/developer/Quickey/.github/workflows/ci.yml). Any path-based automation under `.github/scripts` that keys off `Sources/Quickey` must be updated to `Sources/Wink`.

### 5. Tests and Verification Seams

The rename is mostly mechanical, but tests should protect the identity surfaces that are easiest to miss:

- package/test imports compile under `Wink`
- storage-path tests or targeted assertions cover `Application Support/Wink`
- launch-at-login tests and E2E helpers assert `Wink.app` and `com.wink.app`
- packaging and CI checks assert the renamed bundle/artifact paths

Because this repository uses SPM and target-name-based test imports, the test rename is not optional. Leaving even one `@testable import Quickey` behind will cause obvious build failures once the target is renamed.

### 6. Documentation and Historical Corrections

The documentation layer should stop describing issue #183 as "evaluated and deferred." That was accurate for the earlier docs-only PR, but it becomes false once the actual rename ships.

The update strategy should be:

- rewrite the current-state note in [docs/handoff-notes.md](/Users/yvan/developer/Quickey/docs/handoff-notes.md) to say the clean-break rename to `Wink` has been executed
- update [README.md](/Users/yvan/developer/Quickey/README.md), [AGENTS.md](/Users/yvan/developer/Quickey/AGENTS.md), [docs/README.md](/Users/yvan/developer/Quickey/docs/README.md), and other maintainer docs to use `Wink`
- revise or replace [docs/archive/issue-183-wink-rename-evaluation.md](/Users/yvan/developer/Quickey/docs/archive/issue-183-wink-rename-evaluation.md) so the archive reflects the final outcome rather than remaining a contradictory "do not execute" note
- keep historical context where useful, but not at the cost of lying about the current state

Worker-facing or public static content, such as [worker/src/index.ts](/Users/yvan/developer/Quickey/worker/src/index.ts), should also move to `Wink`.

### 7. Out-of-Repo Identity Surfaces

Two identity surfaces are intentionally outside the code-change scope:

- GitHub repository name and URL slug
- developer-local checkout folder name

The codebase should stop *describing* itself as `Quickey` in repo content, but links or local paths that inherently depend on the still-existing repo slug or checkout directory may continue to reference the old slug/path until the owner renames them outside the repository. This is not naming debt in the product; it is infrastructure state outside normal source edits.

## Testing Strategy

### Automated verification in this repo

- Run targeted `swift test` coverage for renamed identity seams where possible
- Run full `swift test`
- Run `swift build -c release`
- Run `bash scripts/package-app.sh`
- Run `bash scripts/package-dmg.sh`
- Verify CI path checks match `Wink.app` and `Wink-<version>.dmg`

### Required macOS follow-up

The repository guidance already states that Linux-only inspection cannot prove macOS correctness. After the rename, macOS validation must be treated as first-time validation for a new app identity:

- launch packaged `build/Wink.app`
- re-grant Accessibility and, if needed, Input Monitoring to `Wink`
- verify event tap / Carbon / readiness diagnostics use `Wink` paths and identifiers
- verify launch-at-login behavior under the new bundle id and install path
- verify E2E scripts read/write only the new `Wink` paths

## Risks and Mitigations

- **Risk:** Mechanical rename misses a path-sensitive script or CI assertion.
  - **Mitigation:** treat scripts/CI as a first-class rename surface and add verification for bundle, DMG, bundle id, and log/data paths.

- **Risk:** Historical docs contradict the new shipped state.
  - **Mitigation:** update the issue #183 archive note and handoff docs in the same change set as the code rename.

- **Risk:** macOS validation appears broken because old `Quickey` permissions no longer apply.
  - **Mitigation:** document explicitly that this is expected under the clean-break policy and revalidate `Wink` from scratch.

- **Risk:** Repository slug references are confused with product-name debt.
  - **Mitigation:** separate "repo URL not renamed yet" from "app identity renamed" in the docs.

## Success Criteria

- A fresh build produces `Wink.app` and `Wink-<version>.dmg`
- The packaged app advertises itself as `Wink` with bundle id `com.wink.app`
- Default runtime storage/logging paths point only at `Wink`
- The SPM package, executable target, source root, and test target are all renamed to `Wink`
- CI and local scripts no longer assume `Quickey` artifact names or bundle identifiers
- Maintainer and user-facing docs describe the product as `Wink`
- No compatibility code remains that reads from or writes to legacy `Quickey` identity paths by default
