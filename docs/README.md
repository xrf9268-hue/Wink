# Docs Index

This directory maps the maintainer-facing docs for Quickey.

## Core Docs
- [`architecture.md`](./architecture.md)
- [`signing-and-release.md`](./signing-and-release.md) — local DMG packaging, internal-package artifacts, signing, notarization, release secrets, and tag-driven GitHub Release flow

## Maintainer Notes
- [`../AGENTS.md`](../AGENTS.md)
- [`handoff-notes.md`](./handoff-notes.md) — current runtime validation status, packaged-app caveats, latest toggle trace signatures, and the exact 2026-04-09 Safari launch/relaunch validation evidence
- [`lessons-learned.md`](./lessons-learned.md) — operational pitfalls, including session ownership across relaunches and the no-window success policy for regular apps

## Automation
- [`loop-prompt.md`](./loop-prompt.md) — reference and migration note; active automation is the `/babysit-prs` skill
- [`loop-job-guide.md`](./loop-job-guide.md) — how to run and manage loop jobs with `/loop 30m /babysit-prs`

## Historical and Process Docs
- [`archive/`](./archive/)
- [`superpowers/`](./superpowers/)

`archive/` and `superpowers/` are historical or process-oriented references, not the current source of truth.

## Suggested Reading Order
1. [`../AGENTS.md`](../AGENTS.md)
2. [`architecture.md`](./architecture.md)
3. [`handoff-notes.md`](./handoff-notes.md)
4. [`lessons-learned.md`](./lessons-learned.md)
5. [`signing-and-release.md`](./signing-and-release.md)
