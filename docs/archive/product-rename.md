# Product Rename: HotAppClone → Quickey

## Decision

**Selected name: Quickey**

Rationale:
- Short (7 chars) and memorable
- Combines "quick" + "key" — directly evokes keyboard shortcuts
- Feels native as a macOS utility name
- Not too generic, not too narrow
- Clean bundle identifier: `com.quickey.app`

## Status

**Fully completed.** All internal and user-facing names have been renamed.

### Phase 1 (PR #50) — User-facing display names
- `CFBundleName` and `CFBundleDisplayName` in Info.plist
- Settings window title
- General tab version string
- Menu bar accessibility description

### Phase 2 — Full internal rename
- Package name and executable target (`Package.swift`)
- Directory names: `Sources/Quickey/`, `Tests/QuickeyTests/`
- `CFBundleExecutable` and `CFBundleIdentifier` in Info.plist
- Logger subsystem strings → `com.quickey.app`
- Application Support directory path → `Quickey`
- Test imports (`@testable import Quickey`)
- `scripts/package-app.sh` (`APP_NAME`, `BUNDLE_ID`, paths)
- `.github/workflows/ci.yml` (bundle verification paths)
- All documentation references across `README.md`, `AGENTS.md`, `docs/`

### Not changed (by design)
- GitHub repository name (`hotapp-clone`) — requires owner action
- Repository root directory name — follows repo name
