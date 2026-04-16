# Loop Automation Prompt

This file is retained for reference. The active loop automation is now delivered as a skill: `/babysit-prs`.

Core repository state sync now lives in GitHub Actions:
- `.github/workflows/pr-metadata.yml` enforces `Fixes #...` and `Validation Status`
- `.github/workflows/project-sync.yml` reconciles `Quickey Backlog` issue/project state

## Usage

```
/loop 30m /babysit-prs
```

The skill lives at `.claude/skills/babysit-prs/SKILL.md` (in this repo) and uses progressive disclosure:

- `SKILL.md` — main pipeline: safety constraints, iteration guard, workflow steps
- `references/review-gates.md` — three-tier review tool behavior and degraded-tooling rules
- `references/macos-runtime-policy.md` — runtime-sensitive change tracking policy

## Why a Skill Instead of This File

The original `loop-prompt.md` was passed as raw text to CronCreate, causing:

1. **Prompt duplication**: CronCreate repeated the 1,300-word prompt 5 times in a single fire (see `docs/lessons-learned.md`)
2. **Silent tool skips**: Missing review plugins were treated as clean passes instead of degraded gates
3. **Prompt bloat**: PR #107's improvements grew the prompt 55%, worsening the duplication issue

The skill approach solves all three: CronCreate stores only `/babysit-prs` (a few characters), the skill content loads on demand, and progressive disclosure keeps the main pipeline concise while policy details live in `references/`.
