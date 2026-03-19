# Quickey

A macOS menu bar utility inspired by Thor and the recovered HotApp article. It binds global shortcuts to target apps, activates them quickly, and toggles them away when pressed again.

## Current scope
- Swift 6 / SPM-only project layout
- Menu bar app (AppKit-first, selective SwiftUI)
- Tabbed settings window (Shortcuts / General / Insights)
- Persistent shortcut storage (SQLite)
- App picker and shortcut CRUD
- Global key capture via CGEvent tap (Input Monitoring permission)
- Permission check/request flow with recovery after changes (no relaunch needed)
- Shortcut conflict detection
- Recorder-style shortcut capture UI
- Thor-like toggle semantics (activate, restore previous app, hide as fallback)
- Hyper Key support (⌃⌥⇧⌘ combinations) with symbol display
- O(1) precompiled trigger index for hot-path matching
- EventTap lifecycle management with auto-recovery on disable/timeout
- Launch-at-login via SMAppService
- UsageTracker with SQLite daily aggregation
- Insights tab with trend chart and app ranking
- Automated `.app` packaging script
- GitHub Actions CI for macOS build validation
- Signing, notarization, and release workflow documented

## Quick navigation
- Agent guidance: [`AGENTS.md`](./AGENTS.md)
- Docs index: [`docs/README.md`](./docs/README.md)
- Issue tracker status: [`docs/issue-priority-plan.md`](./docs/issue-priority-plan.md)
- macOS validation checklist: [`docs/macos-validation-checklist.md`](./docs/macos-validation-checklist.md)
- Architecture: [`docs/architecture.md`](./docs/architecture.md)
- Signing and release: [`docs/signing-and-release.md`](./docs/signing-and-release.md)
- TODO board: [`TODO.md`](./TODO.md)

## Project layout
- `AGENTS.md`
- `Package.swift`
- `Sources/Quickey/`
- `Sources/Quickey/Resources/Info.plist`
- `Tests/QuickeyTests/`
- `docs/README.md`
- `docs/architecture.md`
- `docs/roadmap.md`
- `docs/issue-priority-plan.md`
- `docs/packaging-and-permissions.md`
- `docs/toggle-semantics.md`
- `docs/macos-validation-checklist.md`
- `docs/handoff-notes.md`
- `docs/signing-and-release.md`
- `docs/archive/` (completed development-era docs)
- `TODO.md`
- `scripts/package-app.sh`
- `.github/workflows/ci.yml`

## Run and build
This repository targets macOS 14+ with Swift 6.

### Build
```bash
swift build
swift test
```

### Package app bundle
```bash
swift build -c release
./scripts/package-app.sh
cp .build/release/Quickey build/Quickey.app/Contents/MacOS/Quickey
```

### Permissions
The app requires **Input Monitoring** permission to observe global key events via CGEvent tap.

- First launch should trigger the permission request path
- If not granted, open:
  - System Settings → Privacy & Security → Input Monitoring
- Enable the built app bundle
- Permission changes are recovered automatically without relaunch

## Known remaining gaps
- End-to-end validation on a real macOS device is still pending (build compiles cleanly, CI passes)
- No signed/notarized distributable yet (workflow documented in `docs/signing-and-release.md`, execution pending a Developer ID cert)
- No private SkyLight/low-latency activation path (intentionally deferred)
- Toggle behavior edge cases with fullscreen / multi-window apps need real device confirmation

## Notes
This project is an independent clone implementation target, not a workspace snapshot.
