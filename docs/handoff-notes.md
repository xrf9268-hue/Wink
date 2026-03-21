# Handoff Notes

## Current state
Quickey completed broad real-device validation on macOS 15.3.1 on 2026-03-20. The 2026-03-21 code-review remediation set is now implemented and CI-verified on GitHub Actions, but the changed platform behaviors still need a fresh targeted manual pass on macOS before claiming runtime revalidation.

### What is in place
- SPM-only Swift 6 project structure
- Menu bar app (AppKit-first, selective SwiftUI — architecture decision documented in `docs/archive/app-structure-direction.md`)
- Tabbed settings window: Shortcuts, General, Insights
- Persistent shortcut storage + SQLite usage tracking
- Global key capture via CGEvent tap (requires both Accessibility + Input Monitoring permissions)
- Shortcut readiness modeled explicitly from Accessibility + Input Monitoring + active event-tap state
- O(1) precompiled trigger index for hot-path matching
- EventTap lifecycle hardened: auto-recovery on disable/timeout, autorepeat filtering
- Passive `.listenOnly` fallback removed from the normal interception path
- Permission flow: recovers monitoring after permission changes without relaunch
- Hyper Key support with symbol display and "Hyper" badge
- Hyper Key persistence only updates after `hidutil` succeeds
- Toggle semantics: activate → restore previous app → hide fallback
- Minimized window recovery via AX API (`kAXMinimizedAttribute`)
- No-window fallback: sends ⌘N when app is running but has 0 visible windows
- SkyLight private API activation for reliable foreground switching from LSUIElement apps
- Launch-at-login via SMAppService
- Launch-at-login approval-needed and not-found states surfaced in the UI
- Automated `.app` packaging script
- GitHub Actions CI for macOS build validation
- Signing and release workflow documented in `docs/signing-and-release.md`
- Product renamed from HotAppClone to Quickey throughout

### Real-device validation results (2026-03-20)
- **Build**: swift build, swift test, release build, package-app.sh all pass ✅
- **Startup & menu bar**: LSUIElement works, menu items correct ✅
- **Permissions**: Dual permission (Accessibility + Input Monitoring) required and verified ✅
- **Shortcut recording**: Letters, modifiers, Hyper Key (⌃⌥⇧⌘), F-keys, arrows, space all work ✅
- **Global capture & toggle**: Activate, restore, hide fallback, launch not-running app all work ✅
- **Minimized windows**: AX API unminimize works ✅
- **Fullscreen**: Switching works across Spaces and dual monitors ✅
- **Insights**: D/W/M views, trend chart, ranking, persistence across restart all work ✅

### Resolved since validation
- **Toggle stability** (#57): Systematic refactor — async event tap, three-layer activation, windowless recovery
- **Hyper Key** (#56): Built-in Caps Lock → Hyper mapping via hidutil + CGEvent tap
- **Logging** (#55): Redesigned with DiagnosticLog + os.log per Apple best practices
- **Insights correctness**: exact 1/7/30-day windows and last-selection-wins refresh scheduling
- **Launch at Login state modeling**: UI now surfaces `SMAppService.requiresApproval` instead of collapsing to a bool
- **Shortcut readiness truthfulness**: UI now distinguishes Accessibility, Input Monitoring, and active event-tap startup

### What remains unresolved
- **Signed/notarized distributable**: workflow documented in `docs/signing-and-release.md`; Developer ID certificate required
- **Private SkyLight activation path**: Works but is private API; may block App Store submission
- **Targeted macOS revalidation for 2026-03-21 remediation**: launch-at-login approval flow, active event tap startup, Hyper Key failure handling, Insights date/race fixes

### Key lessons learned
- macOS 15 CGEvent tap requires **both** Accessibility and Input Monitoring permissions
- Both permissions are still insufficient unless the active event tap starts successfully
- Ad-hoc code signing changes on every rebuild, invalidating TCC permissions — use `tccutil reset` during development
- NSLog/os_log output is filtered by macOS unified logging; use file-based logging (`~/.config/Quickey/debug.log`) for reliable diagnostics
- `NSRunningApplication.activate()` is unreliable from LSUIElement apps on macOS 14+; use `_SLPSSetFrontProcessWithOptions` via SkyLight
- Minimize ≠ hide on macOS; need AX API `kAXMinimizedAttribute` to detect and unminimize
- Filter `keyboardEventAutorepeat` to prevent key-repeat from cycling toggle state
- Always launch via `open xxx.app`, not direct binary execution, for correct TCC permission matching

## Immediate next actions
1. Re-run targeted macOS validation for the 2026-03-21 remediation changes
2. Produce a signed/notarized `.app` once a Developer ID cert is available
3. New feature work or UX improvements
