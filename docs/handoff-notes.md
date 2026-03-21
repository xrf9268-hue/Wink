# Handoff Notes

## Current State
Quickey was broadly validated on macOS 15.3.1 on 2026-03-20. The 2026-03-21 remediation set is implemented and GitHub Actions-verified, but the changed runtime paths still need a fresh targeted macOS pass before we can call them revalidated. A signed and notarized distributable is still unresolved.

## Validated on macOS
- `swift build`, `swift test`, release build, and `./scripts/package-app.sh` passed on 2026-03-20
- LSUIElement startup and menu-bar presentation worked as expected
- Dual permission gating was confirmed: Accessibility plus Input Monitoring
- Shortcut recording worked for letters, modifiers, Hyper Key, F-keys, arrows, and space
- Global capture and toggle behavior worked across launch, restore, hide fallback, and launching a not-running app
- Minimized-window recovery via AX API worked
- Fullscreen switching worked across Spaces and dual monitors
- Insights D/W/M views, trend chart, ranking, and restart persistence were validated

## Follow-up Requiring macOS Validation
- Launch-at-login approval flow after the 2026-03-21 remediation set
- Active event-tap startup and readiness reporting after permission or lifecycle changes
- Hyper Key failure handling, especially persistence only after `hidutil` succeeds
- Insights date-window and refresh-race fixes
- Signed/notarized distributable workflow once a Developer ID certificate is available

## Operational Caveats
- CGEvent tap readiness depends on both Accessibility and Input Monitoring, plus a successfully started active event tap
- Ad-hoc signing changes can invalidate TCC state; use `tccutil reset` during development when needed
- Launch the app with `open`, not by executing the binary directly, so TCC matches the correct app identity
- SkyLight is a private API dependency for reliable activation from LSUIElement apps and may block App Store submission
- Unified logging can hide useful runtime details; file-based debug logs are more reliable for diagnosis

## Immediate Next Actions
1. Re-run the targeted macOS validation for the 2026-03-21 remediation changes
2. Produce a signed and notarized `.app` once a Developer ID certificate is available
3. Fold any new validation findings back into this note, not into the feature overview docs
