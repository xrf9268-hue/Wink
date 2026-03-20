# Quickey

A macOS menu bar utility inspired by Thor and the recovered HotApp article. It binds global shortcuts to target apps, activates them quickly, and toggles them away when pressed again.

## Current status

Real-device validation completed on macOS 15.3.1 (2026-03-20). All core flows verified and working:
- Build, test, release build, `.app` packaging
- Dual permission model (Accessibility + Input Monitoring)
- Shortcut recording (letters, modifiers, Hyper Key, F-keys, arrows, space)
- Global capture, toggle semantics, minimized window recovery, fullscreen switching
- SkyLight private API activation for reliable foreground switching from LSUIElement apps
- Insights tab with trend chart and app ranking

Remaining items are tracked in GitHub Issues and [`TODO.md`](./TODO.md).

## Current scope

- Swift 6 / SPM-only project layout (macOS 14+)
- Menu bar app (AppKit-first, selective SwiftUI)
- Tabbed settings window (Shortcuts / General / Insights)
- Persistent shortcut storage (SQLite) + usage tracking
- Global key capture via CGEvent tap (dual permission: Accessibility + Input Monitoring)
- Permission check/request flow with auto-recovery (no relaunch needed)
- Thor-like toggle semantics (activate, restore previous app, hide as fallback)
- SkyLight private API activation from LSUIElement background apps
- Hyper Key support with symbol display
- O(1) precompiled trigger index for hot-path matching
- EventTap lifecycle management with auto-recovery on disable/timeout
- Launch-at-login via SMAppService
- Automated `.app` packaging script
- GitHub Actions CI for macOS build validation
- Signing and release workflow documented

## Quick navigation

- Agent guidance: [`AGENTS.md`](./AGENTS.md)
- Docs index: [`docs/README.md`](./docs/README.md)
- Architecture: [`docs/architecture.md`](./docs/architecture.md)
- Signing and release: [`docs/signing-and-release.md`](./docs/signing-and-release.md)
- Lessons learned: [`docs/lessons-learned.md`](./docs/lessons-learned.md)
- TODO board: [`TODO.md`](./TODO.md)

## Run and build

```bash
swift build
swift test
swift build -c release
./scripts/package-app.sh
cp .build/release/Quickey build/Quickey.app/Contents/MacOS/Quickey
```

## Permissions

The app requires **both** Accessibility and Input Monitoring permissions for CGEvent tap:

- First launch triggers permission request prompts
- If not granted, open: System Settings > Privacy & Security > Accessibility / Input Monitoring
- Permission changes are recovered automatically without relaunch
- During development, ad-hoc signing changes invalidate TCC records; use `tccutil reset` to re-grant

## Notes

This project is an independent clone implementation target, not a workspace snapshot.
