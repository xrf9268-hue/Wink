# Signing, Sparkle Publishing, and Release Workflow

## Overview

Quickey now has a dual-track release model:

1. Build the release binary
2. Package `build/Quickey.app`
3. Embed and sign `Sparkle.framework` inside the app bundle
4. Package `build/Quickey-<version>.zip` for Sparkle updates
5. Generate `build/appcast.xml`
6. Package `build/Quickey-<version>.dmg`
7. Sign, notarize, staple, and validate the DMG
8. Upload the DMG to GitHub Releases
9. Upload the Sparkle ZIP and `appcast.xml` to Cloudflare R2

The split is intentional:

- GitHub Releases DMG remains the first-install and manual-download artifact
- Sparkle ZIP plus `appcast.xml` powers in-app updates

Ordinary CI stays credential-free and verifies structure only. The dedicated `Release` workflow owns Developer ID signing, notarization, Sparkle signing, and R2 publication.

## Prerequisites

- Apple Developer account
- Xcode command-line tools installed
- A `Developer ID Application` certificate exported as `.p12`
- App Store Connect API key for `notarytool`
- Sparkle EdDSA key pair
- Cloudflare R2 bucket plus public base URL
- macOS host or macOS GitHub Actions runner

## Local Packaging

### Package the app bundle

```bash
bash scripts/package-app.sh
```

This creates `build/Quickey.app` and embeds `Sparkle.framework` under `Contents/Frameworks`.

Optional release-time overrides:

- `SIGN_IDENTITY`
- `ENTITLEMENTS_PLIST`
- `ENABLE_HARDENED_RUNTIME=1`
- `ENABLE_TIMESTAMP=1`
- `REQUIRE_SIGN_IDENTITY=1`
- `SPARKLE_FEED_URL`
- `SPARKLE_PUBLIC_ED_KEY`

`scripts/package-app.sh` explicitly signs nested Sparkle components instead of relying on `codesign --deep`.

### Package the Sparkle ZIP

```bash
bash scripts/package-update-zip.sh
```

This creates `build/Quickey-<CFBundleShortVersionString>.zip` from `build/Quickey.app` using Sparkle-compatible `ditto` flags.

### Generate the appcast

```bash
SPARKLE_PUBLIC_BASE_URL="https://downloads.example.com/quickey/" \
SPARKLE_PRIVATE_ED_KEY="..." \
bash scripts/generate-appcast.sh
```

This creates `build/appcast.xml`.

Supported inputs:

- `SPARKLE_PUBLIC_BASE_URL` required public directory URL for ZIP and notes assets
- `SPARKLE_PRIVATE_ED_KEY` inline private EdDSA key
- `SPARKLE_PRIVATE_ED_KEY_FILE` path to the private EdDSA key file
- `SPARKLE_RELEASE_NOTES_FILE` optional local release-notes file copied beside the ZIP
- `SPARKLE_FULL_RELEASE_NOTES_URL` optional absolute URL written into the appcast
- `SPARKLE_PRODUCT_LINK` optional product page URL

This implementation does not enable signed appcasts. Archive signatures come from Sparkle's EdDSA signing flow.

### Package the DMG

```bash
bash scripts/package-dmg.sh
```

This creates:

- `build/Quickey.app`
- `build/Quickey-<CFBundleShortVersionString>.dmg`
- `build/Quickey-<CFBundleShortVersionString>.zip`
- `build/appcast.xml` if you ran the appcast step

The DMG still contains:

- `Quickey.app`
- `Applications` symlink for drag-install

## Release Signing Inputs

The checked-in [`entitlements.plist`](../entitlements.plist) is the canonical release entitlement file.

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

Accessibility and Input Monitoring remain user-granted runtime permissions, not entitlements.

## GitHub Release Workflow

The release workflow lives at [`release.yml`](../.github/workflows/release.yml).

### Trigger

- push a tag named `v<CFBundleShortVersionString>`
- or run the workflow manually from the default branch and provide an existing matching `release_tag` input

The workflow fails if the Git tag does not match `CFBundleShortVersionString`.
If any required release secret is missing, the workflow exits with a summary and publishes nothing.

### Required GitHub Secrets

Apple signing and notarization:

- `DEVELOPER_ID_APP_CERT_BASE64`
- `DEVELOPER_ID_APP_CERT_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `DEVELOPER_ID_APP_SIGNING_IDENTITY`
- `NOTARYTOOL_KEY`
- `NOTARYTOOL_KEY_ID`
- `NOTARYTOOL_ISSUER`

Sparkle and R2 publishing:

- `SPARKLE_PUBLIC_ED_KEY`
- `SPARKLE_PRIVATE_ED_KEY`
- `R2_ACCOUNT_ID`
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `R2_BUCKET`
- `R2_PUBLIC_BASE_URL`

### Release job flow

0. Check whether all signing, Sparkle, and R2 secrets are present
1. Import the `Developer ID Application` certificate into a temporary keychain
2. Run `swift test`
3. Run `scripts/package-app.sh` in hardened runtime signing mode with `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY`
4. Verify the signed app with `codesign`, `spctl`, and a framework presence check
5. Run `scripts/package-update-zip.sh`
6. Run `scripts/generate-appcast.sh`
7. Run `scripts/package-dmg.sh` with `DMG_SIGN_IDENTITY`
8. Submit the DMG with `xcrun notarytool submit --wait`
9. Staple and validate the DMG
10. Upload the Sparkle ZIP to R2
11. Create or update the GitHub Release and upload `Quickey-<version>.dmg`
12. Upload `appcast.xml` to R2 last so the feed only points at already-published artifacts

The workflow is fail-closed:

- ordinary CI never depends on release secrets
- release publication stops on any signing, ZIP, appcast, notarization, or R2 failure
- appcast upload is the activation step, so it happens after the ZIP and DMG are already in place

## Cloudflare R2 Layout

The current workflow assumes a stable public directory like:

- `https://<public-host>/quickey/appcast.xml`
- `https://<public-host>/quickey/Quickey-<version>.zip`

`R2_PUBLIC_BASE_URL` should point at the directory prefix, not the file itself. The workflow normalizes a trailing slash before generating the feed URL and object keys.

## Internal Package Workflow

For teams that want tester-facing builds without release credentials, Quickey still defines [`internal-package.yml`](../.github/workflows/internal-package.yml).

That workflow:

- builds and tests Quickey on `macos-15`
- packages `build/Quickey-<version>.dmg`
- uploads an Actions artifact
- updates the rolling `internal-downloads` prerelease page

It does not:

- Developer ID sign the app
- notarize the DMG
- publish Sparkle ZIPs
- generate or upload `appcast.xml`
- publish to R2

The internal package path is for trusted testers only.

## Manual Release Checklist

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in [`Info.plist`](../Sources/Quickey/Resources/Info.plist)
2. Run `swift test`
3. Run `bash scripts/package-app.sh`
4. Run `bash scripts/package-update-zip.sh`
5. Run `SPARKLE_PUBLIC_BASE_URL=... SPARKLE_PRIVATE_ED_KEY=... bash scripts/generate-appcast.sh`
6. Run `bash scripts/package-dmg.sh`
7. Tag the release: `git tag vX.Y.Z && git push origin vX.Y.Z`
8. If you need to rerun release automation manually, open `Release`, keep the branch on the default branch, and set `release_tag` to the existing `vX.Y.Z`
9. Confirm the `Release` workflow succeeds
10. Validate the GitHub Release DMG on a clean macOS machine
11. Validate Sparkle update checks against the published R2 `appcast.xml` on a real installed build

If release secrets are missing, use the `Internal Package` workflow for DMG-only tester builds until the full release credentials exist.

## Validation Commands

Credential-free packaging verification:

```bash
swift test
bash scripts/package-app.sh
bash scripts/package-update-zip.sh
bash scripts/package-dmg.sh
```

Sparkle packaging verification:

```bash
test -d build/Quickey.app/Contents/Frameworks/Sparkle.framework
test -f build/Quickey-<version>.zip
```

Signed release verification:

```bash
codesign --verify --deep --strict --verbose=2 build/Quickey.app
spctl --assess --type exec --verbose build/Quickey.app
xcrun stapler validate build/Quickey-<version>.dmg
spctl --assess --type open --context context:primary-signature --verbose build/Quickey-<version>.dmg
```

## Troubleshooting

### Sparkle framework not found during packaging

`scripts/package-app.sh` expects Sparkle's SwiftPM binary artifact under `.build/artifacts`. If packaging fails here, resolve dependencies first with a macOS `swift build`.

### `generate_appcast` not found

`scripts/generate-appcast.sh` also reads Sparkle's binary artifact from `.build/artifacts`. If it is missing, run a macOS `swift build` so SwiftPM downloads the Sparkle artifact bundle.

### Signing identity not found

Check available identities:

```bash
security find-identity -v -p codesigning
```

If release mode is enabled and the specified identity is missing, `scripts/package-app.sh` fails instead of silently falling back.

### Notarization rejected

Inspect the notarization log:

```bash
xcrun notarytool log <submission-id>
```

Common causes:

- hardened runtime was not enabled
- the signed DMG or app was modified after signing
- nested Sparkle content was unsigned or signed inconsistently

### R2 upload succeeded for ZIP but appcast is missing

This is expected fail-closed behavior if publication stops before the final appcast upload step. Sparkle clients will not see the new update until `appcast.xml` is uploaded.

### TCC permissions changed after re-signing

macOS ties Accessibility and Input Monitoring permissions to the app signature. Re-signing can require re-granting those permissions in System Settings.

## CI Integration

- [`ci.yml`](../.github/workflows/ci.yml)
  Builds, tests, packages the app, packages the DMG, packages the Sparkle ZIP, and verifies artifacts without release credentials
- [`release.yml`](../.github/workflows/release.yml)
  Handles tag-driven signing, notarization, Sparkle appcast generation, R2 publication, and GitHub Release DMG publication

## Validation Limits

DMG generation, Developer ID signing, notarization, Sparkle framework loading, Sparkle feed retrieval, archive replacement, and Gatekeeper assessment are macOS-only concerns. Linux-based inspection can review the scripts and workflows, but cannot substitute for:

- `swift build` / `swift test` on macOS
- credential-backed release execution
- real Sparkle update checks against a published feed
- manual post-install validation on `/Applications/Quickey.app`
