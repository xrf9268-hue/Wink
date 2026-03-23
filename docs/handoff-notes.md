# Handoff Notes

## Current State
Quickey was broadly validated on macOS 15.3.1 on 2026-03-20. On 2026-03-23, the runtime hardening follow-up added service-level test seams for permission, app discovery, frontmost-app restore, preferences, and activation fallback paths, and replaced the deprecated `activateIgnoringOtherApps` fallback with a modern `NSWorkspace` reopen request. Issue #67's launch-at-login approval-state UX also landed on 2026-03-23, including Settings foreground refresh coverage for launch-at-login state changes, and `swift test`, `swift build`, `swift build -c release`, and `./scripts/package-app.sh` were rerun afterward. Coverage for the newly targeted services is now measurable: `AccessibilityPermissionService` 64.29%, `AppListProvider` 40.78%, `AppPreferences` 72.50%, `FrontmostApplicationTracker` 43.64%, and `AppSwitcher` 10.55%. The changed activation/runtime paths still need a fresh targeted macOS pass before we can call them revalidated. A signed and notarized distributable is still unresolved.

## Validated on macOS
- Broad real-device validation completed on macOS 15.3.1 on 2026-03-20
- `swift build`, `swift test`, release build, and `./scripts/package-app.sh` passed
- Dual permission gating, active capture startup, and end-to-end shortcut interception were validated
- Runtime toggle behavior, restore/hide fallback, and window recovery paths were exercised successfully
- Insights persistence and restart behavior were confirmed during the macOS pass

## Follow-up Requiring macOS Validation
- Launch-at-login approval flow after the 2026-03-23 issue #67 approval-state UX update, especially `.requiresApproval` -> `.enabled` foreground refresh and `.notFound` behavior on real installs
- Active event-tap startup and readiness reporting after permission or lifecycle changes
- AppSwitcher fallback behavior after SkyLight failure now that it re-requests activation via `NSWorkspace`
- Hyper Key failure handling, especially persistence only after `hidutil` succeeds
- Insights date-window and refresh-race fixes
- Signed/notarized distributable workflow once a Developer ID certificate is available

## Operational Caveats
- CGEvent tap readiness depends on both Accessibility and Input Monitoring, plus a successfully started active event tap
- Ad-hoc signing changes can invalidate TCC state; use `tccutil reset` during development when needed
- Launch the app with `open`, not by executing the binary directly, so TCC matches the correct app identity
- SkyLight is a private API dependency for reliable activation from LSUIElement apps and may block App Store submission
- If SkyLight activation fails, Quickey now falls back to an `NSWorkspace` reopen request instead of the deprecated `activateIgnoringOtherApps` path
- Unified logging can hide useful runtime details; file-based debug logs (`~/.config/Quickey/debug.log`) are more reliable for diagnosis

## Immediate Next Actions
1. Re-run the targeted macOS validation for the 2026-03-21 remediation changes
2. Produce a signed and notarized `.app` once a Developer ID certificate is available
3. Fold any new validation findings back into this note, not into the feature overview docs
