# Issues Backlog

This file is a lightweight companion to the GitHub issue tracker.

## Use these as the primary execution sources
1. GitHub issues
2. `docs/issue-priority-plan.md`
3. `TODO.md`

## Why this file still exists
It records the main backlog themes at a glance, without repeating the full issue tracker.

## Completed themes (all original backlog resolved)

- ✅ macOS build validation — CI via GitHub Actions (#39); real device validation still pending
- ✅ Runtime reliability and architecture correctness — EventTap hardened, permission recovery, O(1) index (#23–#28, #32)
- ✅ Trigger-path performance improvements — O(1) precompiled trigger index (#27)
- ✅ Tests and repeatable validation — key mapping, conflict, lifecycle tests (#30); CI (#39)
- ✅ Interaction quality and behavior polish — recorder UX (#37), toggle semantics (#34), Hyper Key (#33, #36)
- ✅ Packaging, launch-at-login, and release hardening — packaging (#38), SMAppService (#31), signing docs (#49)
- ✅ Product naming and identity — renamed to Quickey (#50, #51)

## Architecture-specific themes (all resolved)
- ✅ Align permission handling with CGEvent tap monitoring model (#23)
- ✅ Tighten event tap lifecycle ownership and disabled/timeout recovery (#25, #26)
- ✅ Recover monitoring after permission changes without relaunch (#28)
- ✅ Replace linear scans with a precompiled trigger index (#27)
- ✅ Reduce unnecessary MainActor pressure in runtime services (#32)
- ✅ Clarify runtime state ownership boundaries (#29)

## Active backlog (what remains)

- Real macOS device validation — end-to-end shortcut capture, toggle, permissions
- Signed/notarized distributable — Developer ID cert required; workflow in `docs/signing-and-release.md`
- Per-shortcut toggle history stacks — beyond current single-memory previous-app approach
- Toggle edge cases — fullscreen / multi-window / multi-display behavior
- Private SkyLight low-latency activation path — intentionally deferred

## Rule of thumb
If a task is already represented clearly in GitHub issues or `docs/issue-priority-plan.md`, do not duplicate its full details here.
