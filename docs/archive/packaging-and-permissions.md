# Packaging and Permissions

## Accessibility
Quickey uses a CGEvent tap for global shortcut capture. On macOS this requires Accessibility permission.

Expected flow:
1. Launch the app
2. The app requests Accessibility access on first shortcut-manager start
3. If not yet granted, the user opens System Settings > Privacy & Security > Accessibility
4. Enable the app and relaunch if needed

## Development caveat
Repeatedly changing the bundle identity or code signature can cause repeated permission prompts. Keep the bundle identifier stable during local iteration.

## Packaging baseline
This repo is SPM-first, but a distributable `.app` still needs an app bundle wrapper.

Recommended baseline:
- keep source in SPM
- generate a macOS app bundle via Xcode or a dedicated packaging script
- use a stable bundle identifier
- add `LSUIElement=1` in the app bundle Info.plist so the app stays out of the Dock

## Info.plist keys
- `LSUIElement` = `1`
- stable `CFBundleIdentifier`
- standard display name and version keys

## Completed hardening
- Login item support via `SMAppService.mainApp` (see `LaunchAtLoginService`)
- Permission diagnostics in Settings UI (Shortcuts tab shows accessibility status)
- Release packaging script (`scripts/package-app.sh`)

## Signing and release
See [signing-and-release.md](signing-and-release.md) for the full signing, notarization, and distribution workflow.
