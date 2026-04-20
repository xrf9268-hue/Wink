# Issue #183 Evaluation: Rename `Quickey` to `Wink`

Date: 2026-04-18  
Issue: https://github.com/xrf9268-hue/Quickey/issues/183

## Decision

Current decision: **defer rename** (do not execute in this cycle).

## Why

The proposal is strong from a naming/branding perspective, but a full rename is currently high-risk for reliability and user continuity because it changes multiple runtime-sensitive identities at once:

- app name (`Quickey.app`)
- bundle identifier (`com.quickey.app`)
- persisted state locations (for example `~/.config/Quickey`, and user support/config paths)
- macOS permission (TCC) identity anchoring tied to app signature + bundle id + path
- login item identity and launch-at-login expectations

Given the project's current focus on capture/activation correctness and runtime validation, a rename now would introduce a large migration surface that is mostly orthogonal to the active stability work.

## Guardrails for a future rename

If we choose to rename later, ship it as a dedicated migration release with explicit scope:

1. Add one-time data migration from legacy `Quickey` paths to new `Wink` paths.
2. Preserve backward compatibility for at least one release window (read old path, write new path, log migration outcome).
3. Add explicit first-launch messaging that permissions may need to be re-granted due to identity/path changes.
4. Re-run full packaged-app macOS validation (Accessibility, Input Monitoring, event tap startup, Carbon registration, toggle E2E, launch-at-login state transitions).
5. Update docs/release notes and include rollback guidance.

## Implementation status for Issue #183

- No product rename applied.
- No bundle identifier rename applied.
- No user data path rename applied.
- Issue is handled as a documented product decision checkpoint and migration-plan placeholder.
