# Docs Index

This directory maps the maintainer-facing docs for Wink. Last reviewed: 2026-04-25 (issue #230). Next audit due: 2026-07-25.

## Core Docs
- [`architecture.md`](./architecture.md) — current architecture and module responsibilities (the source of truth for app shell, toggle pipeline, and activation; supersedes everything in `archive/`)
- [`github-automation.md`](./github-automation.md) — PR metadata enforcement, deterministic review gating, the checked-in `main` ruleset artifact, Wink Backlog project reconciliation, runtime-validation field sync, and required repository secrets
- [`privacy.md`](./privacy.md) — current local-data, permissions, and network-behavior note for the in-app Privacy link
- [`signing-and-release.md`](./signing-and-release.md) — local Sparkle-aware packaging, signed appcast generation, Cloudflare R2 upload requirements, internal-package artifacts, signing, notarization, and the tag-driven public release flow

## Maintainer Notes
- [`../AGENTS.md`](../AGENTS.md)
- [`handoff-notes.md`](./handoff-notes.md) — current runtime validation status, packaged-app caveats, latest toggle trace signatures, and the exact 2026-04-09 Safari launch/relaunch validation evidence
- [`lessons-learned.md`](./lessons-learned.md) — operational pitfalls, including session ownership across relaunches and the no-window success policy for regular apps

## Automation
- [`github-automation.md`](./github-automation.md) — GitHub-native PR and Project workflows that close the issue/project-status gap
- [`pr-governance-rollout.md`](./pr-governance-rollout.md) — one-time rollout runbook for the review gate and `main` ruleset apply sequence
- [`loop-prompt.md`](./loop-prompt.md) — reference and migration note; active automation is the `/babysit-prs` skill
- [`loop-job-guide.md`](./loop-job-guide.md) — how to run and manage loop jobs with `/loop 30m /babysit-prs`
- [`agent-workflow-harnesses`](https://github.com/xrf9268-hue/agent-workflow-harnesses) — external maintainer workflow harness repo for cross-session issue handoff, PR watch, and reusable automation templates across Wink and related repos

## Subdirectories

Each subdirectory has a single, narrow purpose. Anything outside that purpose belongs at the top level.

- [`archive/`](./archive/) — historical decision records, superseded plans, and closed-out handoff notes. **Not** a source of truth; do not link to entries here from `AGENTS.md` or `architecture.md` as if they were current. Treat as failure/decision evidence only.
- [`plans/`](./plans/) — design notes for in-flight work that has not yet shipped. When the plan lands in code, move the file to `archive/`. (Today: only `observation-broker.md`.)
- [`superpowers/`](./superpowers/) — process / agent workflow reference material (plans + specs for review automation, loop jobs, etc.). Operational, not architectural.
- [`design/`](./design/) — UI design references and exported HTML/JSX prototypes used during visual review. Not consumed by the runtime build.
- [`validation/`](./validation/) — dated validation evidence captured against a specific build (screenshots, harness output). Each subdirectory is named for the validation date it documents.

Anything in `archive/`, `superpowers/`, `design/`, or `validation/` is supporting evidence — not current behavior. If `AGENTS.md`, `README.md`, or `architecture.md` reference one of these as current guidance, that is a documentation bug (see issue #230 for the systemic write-up).

## Suggested Reading Order
1. [`../AGENTS.md`](../AGENTS.md)
2. [`architecture.md`](./architecture.md)
3. [`handoff-notes.md`](./handoff-notes.md)
4. [`lessons-learned.md`](./lessons-learned.md)
5. [`github-automation.md`](./github-automation.md)
6. [`signing-and-release.md`](./signing-and-release.md)
