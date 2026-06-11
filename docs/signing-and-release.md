# Signing, Sparkle, and Release Workflow

## Overview

Wink's public release path now ships two distribution tracks from the same signed app bundle:

1. `Wink-<version>.dmg` for first-time install
2. `Wink-<version>.zip` plus `appcast.xml` for Sparkle auto updates

The release workflow signs `build/Wink.app`, wraps it in a notarization zip for `notarytool`, staples the notarized app bundle, packages both archives, uploads the versioned `Wink-<version>.dmg` and `Wink-<version>.zip` artifacts to Cloudflare R2, publishes the DMG on GitHub Releases, and only then uploads the live `appcast.xml` so Sparkle clients do not see a new update before the rest of the release succeeds.

Ordinary CI verifies the package structure, smoke-tests the Sparkle ZIP/appcast generation path with temporary signing keys, and dry-runs the R2 upload helper. The dedicated `Release` workflow still requires real Apple signing credentials, Sparkle signing keys, and R2 credentials.

## Prerequisites

- Apple Developer account
- Xcode command-line tools installed
- A `Developer ID Application` certificate exported as `.p12`
- App Store Connect API key for `notarytool`
- Sparkle EdDSA keypair generated with `generate_keys`
- A Cloudflare R2 bucket or public prefix for update artifacts
- macOS host or macOS GitHub Actions runner

## Sparkle Defaults

[`Sources/Wink/Resources/Info.plist`](../Sources/Wink/Resources/Info.plist) carries the checked-in Sparkle defaults:

- `SUEnableAutomaticChecks = YES`
- `SUScheduledCheckInterval = 86400`
- `SUAutomaticallyUpdate = YES`
- `SUEnableSystemProfiling = NO`
- `SUVerifyUpdateBeforeExtraction = YES`
- `SURequireSignedFeed = YES`

`SUFeedURL` and `SUPublicEDKey` are intentionally left blank in the repo and injected during packaging or release. Wink only starts the updater when both values are present in the packaged app.

Because signed feeds are enabled, `generate_appcast` must have access to the private EdDSA key whenever you publish update artifacts.

## Local Packaging

### App bundle

```bash
bash scripts/package-app.sh
```

This script:

- builds the release binary
- embeds `Sparkle.framework`
- removes Sparkle's unused XPC services because Wink is not sandboxed
- re-signs Sparkle helpers/framework
- signs `build/Wink.app`

Release-style signing is controlled by environment variables passed to `scripts/package-app.sh`:

- `SIGN_IDENTITY`
- `ENTITLEMENTS_PLIST`
- `ENABLE_HARDENED_RUNTIME=1`
- `ENABLE_TIMESTAMP=1`
- `REQUIRE_SIGN_IDENTITY=1`
- `SPARKLE_FEED_URL`
- `SPARKLE_PUBLIC_ED_KEY`

### Sparkle update ZIP

```bash
bash scripts/package-update-zip.sh
```

This creates `build/Wink-<CFBundleShortVersionString>.zip` from the already packaged `build/Wink.app` using `ditto --keepParent`, which preserves symlinks and matches Sparkle's archive guidance.

### Appcast

```bash
SPARKLE_PUBLIC_BASE_URL="https://downloads.example.com/wink/" \
SPARKLE_PRIVATE_ED_KEY="$(cat /path/to/exported-sparkle-private-key)" \
bash scripts/generate-appcast.sh
```

This creates `build/appcast.xml`.

Notes:

- `SPARKLE_PUBLIC_BASE_URL` should point at the public directory where the update ZIP and appcast will be served.
- `SPARKLE_PRIVATE_ED_KEY` should contain the contents of the private key file exported from `generate_keys -x /path/to/private-key-file`.
- If you provide release notes as `SPARKLE_RELEASE_NOTES_FILE`, the script copies them beside the archive so `generate_appcast` can include and sign them.
- With `SURequireSignedFeed = YES`, appcast generation fails closed if the private EdDSA key is unavailable.

### DMG

```bash
bash scripts/package-dmg.sh
```

This creates `build/Wink-<CFBundleShortVersionString>.dmg` containing:

- `Wink.app`
- `Applications` symlink for drag-install
- a branded Finder installer window backed by `assets/dmg/wink-dmg-background.png`

`scripts/package-dmg.sh` intentionally stays on built-in macOS tooling. It stages `assets/dmg/wink-dmg-background.svg` / `.png`, creates a writable HFS+ image with `hdiutil`, uses Finder scripting to save the icon-view layout into `.DS_Store`, then converts the result to the final compressed DMG. No extra Homebrew or Python DMG-packaging dependency is required for CI or release.

## Required GitHub Secrets

### Apple signing and notarization

- `DEVELOPER_ID_APP_CERT_BASE64`
- `DEVELOPER_ID_APP_CERT_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `DEVELOPER_ID_APP_SIGNING_IDENTITY`
- `NOTARYTOOL_KEY`
- `NOTARYTOOL_KEY_ID`
- `NOTARYTOOL_ISSUER`

### Sparkle

- `SPARKLE_PUBLIC_ED_KEY`
- `SPARKLE_PRIVATE_ED_KEY`

Recommended setup:

1. Run Sparkle's `generate_keys` once on a trusted Mac.
2. Copy the printed public key into the `SPARKLE_PUBLIC_ED_KEY` secret.
3. Export the private key with `generate_keys -x /path/to/private-key-file`.
4. Store the contents of that exported file in the `SPARKLE_PRIVATE_ED_KEY` secret.

### Cloudflare R2

- `R2_ACCOUNT_ID`
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `R2_BUCKET`
- `R2_PUBLIC_BASE_URL`

`R2_PUBLIC_BASE_URL` should be the public base directory where release artifacts live, for example `https://pub-xxx.r2.dev/wink/`.

## GitHub Release Workflow

The release workflow lives at [release.yml](../.github/workflows/release.yml).

### Trigger

- push a tag named `v<CFBundleShortVersionString>` (real release)
- or run the workflow manually: provide an existing matching `release_tag` to operate on that tag, or leave it empty to rehearse the dispatched ref (forces a dry run)

The `dry_run` input (default `true` for manual runs) builds and validates everything but publishes nothing. Tag pushes always publish.

The workflow fails if the Git tag does not match `CFBundleShortVersionString` (skipped when rehearsing a ref without a tag).

If any required Apple, Sparkle, or R2 secret is missing, the workflow exits successfully with a summary that lists the missing secrets and publishes nothing.

### Release job flow

0. Check whether all required release secrets are present
1. Run `scripts/verify-release-feed.sh --mode release`: restore the live `appcast.xml` to `build/live-appcast.xml` and fail unless `CFBundleVersion` is strictly greater than the live feed's maximum `sparkle:version`
2. Run `scripts/release-notes.sh <version>`: fail unless `CHANGELOG.md` has a non-empty `## <version>` section, and stage it as the GitHub Release body
3. Import the `Developer ID Application` certificate into a temporary keychain
4. Write the `notarytool` API key to a temporary file
5. Run `swift test`
6. Run `scripts/package-app.sh` in hardened runtime signing mode, injecting `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY`
7. Verify `build/Wink.app`, archive it as a zip for `notarytool`, notarize that archive, and staple `build/Wink.app`
8. Run `scripts/package-update-zip.sh`
9. Run `scripts/generate-appcast.sh` with the private EdDSA key, merging the restored live feed so existing entries are preserved; `SPARKLE_FULL_RELEASE_NOTES_URL` points at the tag's GitHub Release page
10. Run `scripts/package-dmg.sh`, then notarize and staple `build/Wink-<version>.dmg`
11. Upload the versioned DMG and Sparkle ZIP to R2
12. Create or update the GitHub Release with the CHANGELOG-derived notes and upload `Wink-<version>.dmg`
13. Upload `appcast.xml` last so the live Sparkle feed only flips after the earlier release steps succeed

### Feed safety gate

Every release run starts by fetching the live `appcast.xml` from `R2_PUBLIC_BASE_URL`:

- The release proceeds only when this build's `CFBundleVersion` is strictly greater than the largest `sparkle:version` already live. A forgotten bump or an out-of-date tag fails before any signing work starts.
- The restored feed is merged into the generated appcast, so old entries (URLs, signatures) survive every release.
- A fetch error (5xx, network failure) always fails the run; it is never treated as a first release.
- If the live feed legitimately does not exist yet (HTTP 404), set the repository variable `WINK_ALLOW_FIRST_RELEASE` to `1` for the first run and delete the variable afterwards.
- All release runs share one concurrency group and execute serially. If three or more runs queue up, GitHub cancels the intermediate pending run — re-run it; the gate makes any re-run order safe.

### Dry run

A manual `Release` run with `dry_run` enabled (the default) rehearses the full chain — feed gate (report-only `--mode rehearse`), notes gate, tests, signing, notarization, stapling, DMG/ZIP packaging, appcast generation, and artifact validation — then uploads everything as the `release-dry-run-<version>` workflow artifact instead of publishing. R2 and GitHub Releases are never touched.

- Leave `release_tag` empty to rehearse the dispatched ref (dry run is forced).
- Set `release_tag` to an existing tag with `dry_run` enabled to rehearse that tag.
- Dry runs require the same secrets as real releases; rehearsing the signed chain is the point.
- While no live feed exists yet, the rehearse-mode gate still fails on 404 unless the `WINK_ALLOW_FIRST_RELEASE` repository variable is set (the same opt-in a first real release needs).

When secrets are present, the workflow is fail-closed for the live Sparkle feed: if signing, notarization, appcast signing, GitHub Release publication, or the final appcast upload fails, Sparkle clients do not see the new update because `appcast.xml` is published last.

## Internal Package Workflow

For teams that do not yet have the full Apple + Sparkle + R2 secret set, Wink also defines [internal-package.yml](../.github/workflows/internal-package.yml).

It:

- builds and tests Wink on `macos-15`
- packages `build/Wink-<version>.dmg`
- uploads an Actions artifact
- refreshes the rolling `internal-downloads` prerelease page

The internal package path is for trusted testers only. It does not:

- notarize the build
- publish a Sparkle update feed
- upload release artifacts to R2

## Manual Release Checklist

1. Write the `## X.Y.Z` section in [CHANGELOG.md](../CHANGELOG.md), then run `./scripts/bump-version.sh X.Y.Z` (validates semver, requires the CHANGELOG section, and increments `CFBundleVersion`)
2. Run `swift test`
3. Run `bash scripts/package-app.sh`
4. Run `bash scripts/package-update-zip.sh`
5. Run `bash scripts/package-dmg.sh`
6. Tag the release: `git tag vX.Y.Z && git push origin vX.Y.Z`
7. If a run failed before the final appcast upload, re-run it manually: open `Release`, keep the branch on the default branch, and set `release_tag` to the existing `vX.Y.Z`. Re-running a tag **after** its feed entry is live is blocked by the feed gate — to repair a published release, bump to a new version instead
8. Confirm the `Release` workflow succeeds for both the DMG and the Sparkle feed upload
9. Validate the published DMG and Sparkle update path on a clean macOS machine, including the Finder background, icon layout, and drag-install affordance

## Validation Commands

Local packaging verification:

```bash
swift test
bash scripts/package-app.sh
bash scripts/package-update-zip.sh
bash scripts/package-dmg.sh
codesign --verify --deep --strict --verbose=2 build/Wink.app
```

Release verification:

```bash
spctl --assess --type exec --verbose build/Wink.app
xcrun stapler validate build/Wink-<version>.dmg
spctl --assess --type open --context context:primary-signature --verbose build/Wink-<version>.dmg
```

## Troubleshooting

### Sparkle private key missing

`generate_appcast` will fail if it cannot access a private EdDSA key.

- Export from a trusted Mac with `generate_keys -x /path/to/private-key-file`
- Store that file's contents in `SPARKLE_PRIVATE_ED_KEY`
- Or import locally with `generate_keys -f /path/to/private-key-file`

### Sparkle framework fails to load in a local release-like run

Sparkle's documentation notes that Hardened Runtime library validation can block ad-hoc local loading.

- The default local `scripts/package-app.sh` path keeps hardened runtime off, which is appropriate for ad-hoc builds.
- For a release-like local run, sign with an `Apple Development` or `Developer ID Application` identity instead of ad-hoc.

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
- nested Sparkle content was not re-signed after packaging changes

### TCC permissions changed after re-signing

macOS ties Accessibility and Input Monitoring permissions to the app signature. Re-signing can require re-granting those permissions in System Settings.

## CI Integration

- [ci.yml](../.github/workflows/ci.yml)
  Builds, tests, packages the app and DMG, smoke-tests Sparkle ZIP/appcast generation with temporary keys, and verifies the packaged app includes `Sparkle.framework`
- [release.yml](../.github/workflows/release.yml)
  Handles signing, notarization, Sparkle ZIP/appcast generation, R2 upload, and GitHub Release publication
- [internal-package.yml](../.github/workflows/internal-package.yml)
  Produces trusted-tester DMGs without publishing a production Sparkle feed

## Validation Limits

Sparkle feed signing, R2 uploads, Developer ID signing, notarization, stapling, and Gatekeeper assessment are macOS-and-credentials concerns. Linux-only review can inspect the code and workflows, but it cannot substitute for a credential-backed macOS release validation pass.
