# Issue #183 Evaluation: Rename `Quickey` to `Wink`

Date: 2026-04-18  
Issue: https://github.com/xrf9268-hue/Quickey/issues/183

## Decision

Current decision: **clean-break rename applied**.

## Why

Before the clean-break rename was executed, the main concern was that a full rename would change multiple runtime-sensitive identities at once:

- app name (`Wink.app`)
- bundle identifier (`com.wink.app`)
- persisted state locations (for example `~/.config/Wink`, and user support/config paths)
- macOS permission (TCC) identity anchoring tied to app signature + bundle id + path
- login item identity and launch-at-login expectations

The clean-break implementation resolved that concern by choosing not to preserve a migration layer. This archival note keeps the original risk framing for context, but the executed outcome is the direct `Wink` rename recorded below.

## Post-rename follow-up notes

The clean-break execution deliberately avoided any compatibility layer for legacy `Quickey` paths or bundle identifiers. The practical follow-up is to validate the packaged app on macOS with the live permission and event-tap flow, then update any remaining docs or release notes that still describe the old identity as current state.

1. Validate the clean-break rename on macOS using the packaged app and the live permission / event-tap flow.
2. Update any remaining docs or release notes that still describe the old identity as current state.

## Implementation status for Issue #183

- Clean-break product rename applied.
- Bundle identifier renamed to `com.wink.app`.
- User data paths renamed to `Wink`.
- Legacy `Quickey` compatibility paths are intentionally not preserved.
