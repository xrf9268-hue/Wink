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

### Launch-completion fault validation package

The default package is production-only: the launch-completion fault injector,
its argument parser, and its diagnostic markers are excluded at compile time.
For a packaged macOS ownership test, build the validation profile explicitly:

```bash
WINK_VALIDATION_LAUNCH_FAULT_INJECTION=1 bash scripts/package-app.sh
```

The resulting `build/Wink.app` carries
`WinkRuntimeValidationProfile=launch-fault-injection` in `Info.plist` and accepts
exactly one of these validation-only arguments:

```text
--validation-launch-fault=stale-error:<target-bundle-id>
--validation-launch-fault=current-error-once:<target-bundle-id>
```

`stale-error` holds the first matching launch completion, lets a second request
supersede it, then delivers the first request's injected error before forwarding
the second request to `NSWorkspace`. `current-error-once` fails the first matching
request and lets later matching requests pass through. Nonmatching app launches
always pass through unchanged.

Preserve the injected app at a separate absolute path before rebuilding because
the package script always writes `build/Wink.app`. Build the clean package from
the same 40-character Git head with the default command (or explicitly set the
profile to `0`):

```bash
WINK_VALIDATION_LAUNCH_FAULT_INJECTION=0 bash scripts/package-app.sh
```

Profile changes clean SwiftPM products while retaining dependency caches. A
clean build removes the validation `Info.plist` key and contains neither the
validation argument nor `LAUNCH_FAULT_INJECTION` marker; verify those properties
on the exact executable used for normal-path E2E. Never distribute the injected
bundle.

### EventTap lifecycle fault validation package

The EventTap failure factories and scenario driver are also compile-time-only.
Build that packaged validation profile explicitly:

```bash
WINK_VALIDATION_EVENT_TAP_FAULT_INJECTION=1 bash scripts/package-app.sh
```

The resulting bundle carries
`WinkRuntimeValidationProfile=event-tap-fault-injection` and accepts exactly one
of these arguments:

```text
--validation-event-tap-fault=replacement-tap-once
--validation-event-tap-fault=replacement-source-until-degraded
--validation-event-tap-fault=cycle20
```

The first mode fails one replacement-tap creation and requires the configured
retry to recover on the same thread within one second. The second fails two
replacement-source creations, requires degraded readiness, and proves that each
created tap plus the complete owned session is released. `cycle20` runs twenty
fail/stop-twice/restart generations, probes stopped-generation callbacks, proves
one owner after each restart, and finishes with all owned-resource counters at
zero.

The launch and EventTap injection profiles are mutually exclusive. Preserve
each injected bundle at a separate absolute path, then rebuild production from
the same 40-character Git head. The clean executable must have no runtime
validation profile, validation argument, `LAUNCH_FAULT_INJECTION`, or
`EVENT_TAP_FAULT_INJECTION` marker before normal-path E2E. Never distribute an
injected bundle.

### Local development signing identity ("Wink")

`SIGN_IDENTITY` defaults to `Wink`. Keep a self-signed code-signing
certificate named exactly **Wink** in the login keychain so local packages get
a **stable designated requirement** instead of the ad-hoc fallback:

- Ad-hoc signatures change every rebuild, which silently invalidates the TCC
  grants (Accessibility, Input Monitoring) for `build/Wink.app` — the e2e
  harness then fails capture readiness (`ax=false im=false`) until the rows
  are manually re-added in System Settings.
- TCC keys grants by bundle id plus the granted copy's code requirement.
  With `/Applications/Wink.app` and `build/Wink.app` signed by the **same**
  "Wink" certificate, one grant covers both copies and survives rebuilds.
  Do not let one copy drift back to ad-hoc: re-granting a differently signed
  copy of `com.wink.app` silently breaks the other copy's permissions.

Create the certificate either with Keychain Access → Certificate Assistant →
Create a Certificate (Name: `Wink`, Type: Code Signing), or from a terminal:

```bash
cat > /tmp/wink-cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no
[dn]
CN = Wink
[v3_codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -keyout /tmp/wink-key.pem \
  -out /tmp/wink-cert.pem -days 3650 -nodes -config /tmp/wink-cert.cnf
openssl pkcs12 -export -legacy -out /tmp/wink.p12 \
  -inkey /tmp/wink-key.pem -in /tmp/wink-cert.pem -passout pass:winktmp
security import /tmp/wink.p12 -k ~/Library/Keychains/login.keychain-db \
  -P winktmp -T /usr/bin/codesign
security add-trusted-cert -p codeSign \
  -k ~/Library/Keychains/login.keychain-db /tmp/wink-cert.pem   # approve the dialog
rm -f /tmp/wink-key.pem /tmp/wink.p12 /tmp/wink-cert.pem /tmp/wink-cert.cnf
```

(`-legacy` matters: macOS `security import` rejects OpenSSL 3's default
PKCS#12 encoding with "MAC verification failed".)

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

Secret requirements are split into two groups (issue #283):

- **Core (always required):** the two Sparkle keys and the five R2 credentials. If any is missing, the workflow exits successfully with a summary that lists the missing secrets and publishes nothing.
- **Apple (optional as a complete set):** the four signing secrets (including `KEYCHAIN_PASSWORD`) and the three notarytool secrets. All seven present → Developer ID signing plus notarization (`signing_mode=developer-id`). All seven absent → ad-hoc interim mode (`signing_mode=adhoc`). A partial set fails the run instead of silently degrading.

### Ad-hoc interim mode

While the maintainer has no Apple Developer Program membership, releases ship ad-hoc signed and unnotarized:

- the app bundle is ad-hoc signed (`codesign -s -`) without hardened runtime; the DMG is unsigned
- all notarization, stapling, and Gatekeeper (`spctl`) steps are skipped — `codesign --verify` still runs
- Sparkle's EdDSA feed signature remains the update trust anchor, so in-app auto updates work exactly as in the full path
- first install on macOS 15+ requires System Settings → Privacy & Security → **Open Anyway**; the release workflow appends this hint to the GitHub Release notes automatically
- enrolling in the Apple Developer Program later requires no workflow changes: configure the seven Apple secrets and the next release is signed and notarized

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

### Local end-to-end update-flow validation

The in-app update UI (check → available → download → extract → ready →
install/relaunch, Issue #298) can be exercised against a fully local feed,
no release infrastructure needed:

1. Generate a throwaway EdDSA keypair under a dedicated keychain account and
   export the private key:
   `generate_keys --account wink-local-test && generate_keys --account wink-local-test -x /tmp/wink-test-ed.key`
   (the tool lives under `.build/artifacts/*/bin/`).
2. Package the app-under-test with only the public key injected
   (`SPARKLE_PUBLIC_ED_KEY=<pubkey> bash scripts/package-app.sh`) and stash a
   copy — the feed URL comes from the override below, so `SPARKLE_FEED_URL`
   is not needed.
3. Temporarily bump `CFBundleShortVersionString`/`CFBundleVersion` in
   `Sources/Wink/Resources/Info.plist`, package again, run
   `bash scripts/package-update-zip.sh`, then
   `WINK_ALLOW_FIRST_RELEASE=1 SPARKLE_PUBLIC_BASE_URL="http://localhost:8000/" SPARKLE_PRIVATE_ED_KEY_FILE=/tmp/wink-test-ed.key bash scripts/generate-appcast.sh`,
   and revert the plist.
4. Serve the zip + `appcast.xml` with `python3 -m http.server 8000` and point
   the app at it: `defaults write com.wink.app updateFeedURLOverride "http://localhost:8000/appcast.xml"`.
   The override accepts https plus loopback http only
   (`SparkleUpdaterDelegate.sanitizedOverride`).
5. Launch the stashed lower-version copy and drive Check for Updates…
   end-to-end; Sparkle installs the new version in place and relaunches.
6. Clean up: delete the `updateFeedURLOverride`/`SULastCheckTime` defaults,
   `security delete-generic-password -a wink-local-test`, and remove the
   exported key file.

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
