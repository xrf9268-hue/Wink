# HotApp Clone

A macOS menu bar utility inspired by Thor and the recovered HotApp article. It binds global shortcuts to target apps, activates them quickly, and toggles them away when pressed again.

## Current scope
- Swift 6 / SPM-only project layout
- Menu bar app shell
- SwiftUI + AppKit settings window
- Persistent shortcut storage
- App picker and shortcut CRUD
- CGEvent tap baseline for global key capture
- Accessibility permission check/request flow
- Basic shortcut conflict detection
- Recorder-style shortcut capture UI
- Thor-like toggle semantics baseline
- Packaging scaffold for `.app`

## Project layout
- `Package.swift`
- `Sources/HotAppClone/`
- `Sources/HotAppClone/Resources/Info.plist`
- `Tests/HotAppCloneTests/`
- `docs/clone-scope.md`
- `docs/packaging-and-permissions.md`
- `docs/toggle-semantics.md`
- `docs/macos-validation-checklist.md`
- `docs/next-phase-plan.md`
- `docs/handoff-notes.md`
- `TODO.md`
- `scripts/package-app.sh`

## Run and build
This repository targets macOS 14+ with Swift 6.

### Build
```bash
swift build
swift test
```

### Package app scaffold
```bash
swift build -c release
./scripts/package-app.sh
cp .build/release/HotAppClone build/HotAppClone.app/Contents/MacOS/HotAppClone
```

### Accessibility
The app needs Accessibility permission to observe global key events.

- First launch should trigger the permission request path
- If not granted, open:
  - System Settings
  - Privacy & Security
  - Accessibility
- Enable the built app bundle

## Known gaps
- Recorder UI is basic and not yet a polished KeyboardShortcuts-style control
- No SkyLight/private activation path yet
- No signed/notarized release flow yet
- Not compiled on this Linux host; final verification must happen on macOS
- Toggle behavior is best-effort and still needs macOS edge-case validation

## Notes
This project is an independent clone implementation target, not a workspace snapshot.
