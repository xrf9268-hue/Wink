# Signing, Notarization, and Release Workflow

## Overview

Quickey ships as a drag-install DMG. The release path is:

1. Build the release binary
2. Package `build/Quickey.app`
3. Sign the app with `Developer ID Application`
4. Package `build/Quickey-<version>.dmg`
5. Sign the DMG
6. Submit the DMG to Apple notarization
7. Staple the notarization ticket to the DMG
8. Publish the notarized DMG through GitHub Releases

Ordinary CI verifies that the `.app` and `.dmg` packaging paths work without Apple credentials. The dedicated release workflow handles Developer ID signing, notarization, stapling, and GitHub Release publication.

## Prerequisites

- Apple Developer account
- Xcode command-line tools installed
- A `Developer ID Application` certificate exported as `.p12`
- App Store Connect API key for `notarytool`
- macOS host or macOS GitHub Actions runner

## Local Packaging

### Build and package the app bundle

```bash
./scripts/package-app.sh
```

This creates `build/Quickey.app`.

### Build the DMG

```bash
./scripts/package-dmg.sh
```

This creates:

- `build/Quickey.app`
- `build/Quickey-<CFBundleShortVersionString>.dmg`

The DMG contains:

- `Quickey.app`
- `Applications` symlink for drag-install

### Local verification

```bash
swift test
codesign --verify --deep --strict --verbose=2 build/Quickey.app
```

You can also mount and inspect the DMG locally:

```bash
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Quickey/Resources/Info.plist)"
DMG="build/Quickey-${VERSION}.dmg"
MOUNT_OUTPUT="$(hdiutil attach "$DMG" -nobrowse)"
MOUNT_POINT="$(printf '%s\n' "$MOUNT_OUTPUT" | tail -n 1 | awk '{print $3}')"
ls "$MOUNT_POINT"
hdiutil detach "$MOUNT_POINT"
```

## Release Signing Inputs

Release-mode app signing is driven through environment variables passed to `scripts/package-app.sh`:

- `SIGN_IDENTITY`
- `ENTITLEMENTS_PLIST`
- `ENABLE_HARDENED_RUNTIME=1`
- `ENABLE_TIMESTAMP=1`
- `REQUIRE_SIGN_IDENTITY=1`

The checked-in [entitlements.plist](/Users/yvan/developer/Quickey/entitlements.plist) is the canonical release entitlement file.

Quickey's current entitlement set is intentionally minimal:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key>
  <true/>
</dict>
</plist>
```

Accessibility and Input Monitoring are still user-granted runtime permissions, not entitlements.

## GitHub Release Workflow

The release workflow lives at [release.yml](/Users/yvan/developer/Quickey/.github/workflows/release.yml).

### Trigger

- push a tag named `v<CFBundleShortVersionString>`
- or run the workflow manually from a matching `v*` tag ref

The workflow fails if the Git tag does not match `CFBundleShortVersionString`.

### Required GitHub Secrets

- `DEVELOPER_ID_APP_CERT_BASE64`
- `DEVELOPER_ID_APP_CERT_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `DEVELOPER_ID_APP_SIGNING_IDENTITY`
- `NOTARYTOOL_KEY`
- `NOTARYTOOL_KEY_ID`
- `NOTARYTOOL_ISSUER`

### Release job flow

1. Import the `Developer ID Application` certificate into a temporary keychain
2. Run `swift test`
3. Run `scripts/package-app.sh` in hardened runtime signing mode
4. Verify the signed app with `codesign` and `spctl`
5. Run `scripts/package-dmg.sh` with `DMG_SIGN_IDENTITY`
6. Submit the DMG with `xcrun notarytool submit --wait`
7. Staple the DMG with `xcrun stapler staple`
8. Validate the final DMG with `stapler validate` and `spctl --assess --type open`
9. Create or update the GitHub Release and upload `Quickey-<version>.dmg`

The workflow is fail-closed: if signing, notarization, stapling, or validation fails, no release asset is published.

## Manual Release Checklist

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in [Info.plist](/Users/yvan/developer/Quickey/Sources/Quickey/Resources/Info.plist)
2. Run `swift test`
3. Run `./scripts/package-app.sh`
4. Run `./scripts/package-dmg.sh`
5. Tag the release: `git tag vX.Y.Z && git push origin vX.Y.Z`
6. Confirm the `Release` workflow succeeds
7. Download the GitHub Release DMG and validate it on a clean macOS machine

## Validation Commands

Local packaging verification:

```bash
swift test
bash scripts/package-app.sh
bash scripts/package-dmg.sh
```

Release verification:

```bash
codesign --verify --deep --strict --verbose=2 build/Quickey.app
spctl --assess --type exec --verbose build/Quickey.app
xcrun stapler validate build/Quickey-<version>.dmg
spctl --assess --type open --context context:primary-signature --verbose build/Quickey-<version>.dmg
```

## Troubleshooting

### Signing identity not found

Check available identities:

```bash
security find-identity -v -p codesigning
```

If release mode is enabled and the specified identity is missing, `scripts/package-app.sh` will fail instead of silently falling back.

### Notarization rejected

Inspect the notarization log:

```bash
xcrun notarytool log <submission-id>
```

Common causes:

- hardened runtime was not enabled
- the signed DMG or app was modified after signing
- nested content is unsigned or signed inconsistently

### TCC permissions changed after re-signing

macOS ties Accessibility and Input Monitoring permissions to the app signature. Re-signing can require re-granting those permissions in System Settings.

## CI Integration

- [ci.yml](/Users/yvan/developer/Quickey/.github/workflows/ci.yml)
  Builds, tests, packages the app, packages the DMG, and verifies artifacts without Apple credentials
- [release.yml](/Users/yvan/developer/Quickey/.github/workflows/release.yml)
  Handles tag-driven signing, notarization, stapling, validation, and GitHub Release publication

## Validation Limits

DMG generation, Developer ID signing, notarization, stapling, and Gatekeeper assessment are macOS-only concerns. Linux-based inspection can review the scripts and workflow, but cannot substitute for credential-backed macOS validation.
