# Product Rename: HotAppClone → Quickey

## Decision

**Selected name: Quickey**

Rationale:
- Short (7 chars) and memorable
- Combines "quick" + "key" — directly evokes keyboard shortcuts
- Feels native as a macOS utility name
- Not too generic, not too narrow
- Clean bundle identifier: `com.quickey.app`

## What This PR Does

Updates all **user-facing** display names:
- `CFBundleName` and `CFBundleDisplayName` in Info.plist
- Settings window title
- General tab version string
- Menu bar accessibility description

## What a Full Rename Would Require

The following are **not** changed in this PR to avoid unnecessary churn. They can be done incrementally if/when the project is published:

### Package / build artifacts
- `Package.swift`: rename package and executable target
- Directory: `Sources/HotAppClone/` → `Sources/Quickey/`
- Directory: `Tests/HotAppCloneTests/` → `Tests/QuickeyTests/`
- `@testable import HotAppClone` → `@testable import Quickey`
- `scripts/package-app.sh`: update `APP_NAME`

### Bundle identity
- `CFBundleExecutable`: `HotAppClone` → `Quickey`
- `CFBundleIdentifier`: `com.xrf9268.hotapp-clone` → `com.quickey.app`
- Logger subsystem strings: `com.hotappclone` → `com.quickey.app`

### Repository
- GitHub repo name (requires owner action)
- CI workflow references
- Documentation references throughout `docs/`

### Data migration
- `~/Library/Application Support/HotAppClone/` → new path
- Existing SQLite database would need migration or symlink
- LaunchAtLogin registration uses bundle ID — users would need to re-enable

### Risk notes
- Changing `CFBundleIdentifier` resets macOS Accessibility permission
- Changing the executable name breaks existing launch-at-login registrations
- Users on the old name would lose their shortcut configurations unless migration is handled
