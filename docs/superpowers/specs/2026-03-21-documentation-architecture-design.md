# Documentation Architecture and Cleanup Design

**Date:** 2026-03-21
**Status:** Approved for planning

## Overview

This design defines a cleaner documentation structure for Quickey with two goals:

1. Present a more professional, external-facing repository surface
2. Preserve development history and maintainer context without letting internal process notes dominate the primary docs

The result is a three-layer documentation model:

- Public-facing primary docs for external readers
- Maintainer docs for contributors and future maintainers
- Historical/process docs kept in the repository but clearly de-emphasized

## Goals

- Make the root `README.md` read like a polished product landing page instead of an execution board
- Remove `TODO.md` and make GitHub Issues the single task-tracking source of truth
- Keep operational and historical notes available without surfacing them as primary project documentation
- Normalize primary documentation language to English
- Reduce duplication across `README.md`, `docs/README.md`, and `docs/handoff-notes.md`

## Non-Goals

- No code or product behavior changes
- No large-scale rewrite of architectural content already captured accurately in `docs/architecture.md`
- No deletion of historical design and planning artifacts in `docs/superpowers/`
- No attempt to hide platform constraints such as macOS-only runtime validation or private SkyLight usage

## Audience Model

### Public-facing readers

Primary reader for the root `README.md`:

- people discovering the project for the first time
- potential users
- engineers quickly evaluating whether the project is real, current, and technically credible

### Maintainers

Primary readers for the docs index and operational notes:

- future contributors
- the current maintainer returning after time away
- agents or reviewers needing architecture, release, and validation context

## Documentation Layers

### 1. Public-facing primary docs

These documents should stay concise, stable, and professional:

- `README.md`
- `docs/architecture.md`
- `docs/signing-and-release.md`

`README.md` should answer:

- What Quickey is
- What it can do
- What platform constraints matter
- How to build or run it
- Where to find stable reference documentation

It should not function as a live status board, handoff note, or detailed validation log.

### 2. Maintainer docs

These documents remain current, but are explicitly contributor-oriented:

- `docs/README.md`
- `AGENTS.md`
- `docs/handoff-notes.md`
- `docs/lessons-learned.md`

`docs/README.md` becomes the maintainer-facing documentation map. It should categorize documents by role rather than present them as one flat list.

`docs/handoff-notes.md` remains useful, but should focus on:

- current validated state
- unresolved macOS-only follow-up items
- operational caveats that matter during maintenance

`docs/lessons-learned.md` should be rewritten in English and reframed as focused troubleshooting and validation guidance rather than personal debugging notes.

### 3. Historical and process docs

These documents remain in the repository, but are not part of the primary project narrative:

- `docs/archive/`
- `docs/superpowers/`

They should be reachable from `docs/README.md`, but described clearly as historical or process artifacts rather than current source-of-truth references.

## File-by-File Design

### `README.md`

Restructure into a public-facing landing page with these sections:

- short product description
- highlights
- requirements and constraints
- build and run
- documentation
- concise project status

Remove or demote:

- detailed validation checklists
- references to `TODO.md`
- handoff-style progress narration
- too many internal-only links

Keep the tone factual and stable. Avoid wording that will age quickly unless the statement is intentionally status-oriented.

### `TODO.md`

Remove the file entirely.

Task tracking should live in GitHub Issues. Any current state that still matters for maintainers belongs in `docs/handoff-notes.md`, not in a repository-root execution board.

### `docs/README.md`

Rewrite as a categorized documentation map with sections such as:

- Core docs
- Maintainer notes
- Historical and process docs

This file becomes the place where internal readers learn what is current, what is operational, and what is archival.

### `docs/handoff-notes.md`

Keep the file, but tighten it to avoid overlapping with the root `README.md`.

The document should emphasize:

- what has been validated
- what still requires real macOS verification
- what platform-specific caveats matter during maintenance

It should avoid re-documenting the full product scope unless needed for an operational conclusion.

### `docs/lessons-learned.md`

Keep the file, but rewrite it in English.

Recommended structure per section:

- issue
- cause
- practical guidance

The aim is to preserve the high-value macOS findings while improving consistency with the rest of the visible docs.

### `docs/superpowers/`

Keep the directory unchanged for now.

Do not present these files as user-facing project docs. In `docs/README.md`, describe them as agent-generated specs and plans retained for development history.

### `docs/archive/README.md`

Tighten the wording so it explicitly states that the archive contains superseded or completed historical documents and is not the current source of truth.

## Navigation Rules

- The root `README.md` should link only to a small set of stable, high-value documents
- Process-heavy or historical documents should be linked from `docs/README.md`, not emphasized on the repository homepage
- Primary docs should remain in English
- Internal notes may be detailed, but should still stay concise and scannable

## Risks and Trade-offs

### Benefits

- Stronger first impression for external readers
- Less duplication and fewer conflicting status summaries
- Better separation between stable docs and working notes
- Preserved historical context without cluttering the primary docs surface

### Trade-offs

- Some internal context becomes one click deeper
- Maintainers must rely on `docs/README.md` rather than the root README for process/history navigation
- Rewriting `docs/lessons-learned.md` adds small editorial work beyond simple file moves

## Verification

Success should be evaluated with lightweight documentation checks:

- the root `README.md` reads coherently for an external reader
- no visible primary doc references `TODO.md`
- `docs/README.md` makes the current-vs-historical distinction obvious
- primary visible docs use English consistently
- historical and process documents remain accessible without being over-promoted

## Implementation Outline

When implementation begins, the work should proceed in this order:

1. Rewrite `README.md` as the public-facing landing page
2. Rewrite `docs/README.md` as the categorized documentation map
3. Tighten `docs/handoff-notes.md`
4. Rewrite `docs/lessons-learned.md` in English
5. Update `docs/archive/README.md`
6. Remove `TODO.md`
7. Check for stale references to `TODO.md` and update them
