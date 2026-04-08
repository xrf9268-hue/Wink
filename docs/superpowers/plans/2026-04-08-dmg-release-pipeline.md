# DMG Release Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local DMG packaging script and a GitHub Release workflow that publishes a signed, notarized, stapled Quickey DMG using Apple's recommended Developer ID workflow.

**Architecture:** Keep `scripts/package-app.sh` as the single `.app` bundle source of truth, extend it with release-signing inputs, then add a thin `scripts/package-dmg.sh` layer that wraps the packaged app into a drag-install DMG. Keep ordinary CI credential-free, and isolate certificate import, notarization, stapling, and GitHub Release publication inside a dedicated tag-driven workflow.

**Tech Stack:** Bash, GitHub Actions, macOS command-line tooling (`codesign`, `hdiutil`, `xcrun notarytool`, `xcrun stapler`, `spctl`), SwiftPM, Markdown

**Spec:** `docs/superpowers/specs/2026-04-08-dmg-release-pipeline-design.md`

---

## File Structure

- `scripts/package-app.sh`
  Existing app-bundle packager. Extend it so local builds keep the current signing fallback while release builds can opt into Developer ID signing, hardened runtime, timestamping, and entitlements.

- `scripts/package-dmg.sh`
  New DMG packager. It should build or reuse `build/Quickey.app`, stage `Quickey.app` plus an `Applications` symlink, optionally sign the finished DMG, and output `build/Quickey-<version>.dmg`.

- `entitlements.plist`
  New release entitlement file for the hardened runtime signing path.

- `.github/workflows/ci.yml`
  Existing CI workflow. Extend it to verify the DMG packaging path without release secrets.

- `.github/workflows/release.yml`
  New release workflow. It should run on `v*` tags or manual dispatch, import certificates into a temporary keychain, build, sign, notarize, staple, validate, and publish the DMG.

- `README.md`
  Update build and release guidance to mention the DMG path.

- `docs/README.md`
  Keep the docs index current by mentioning the release workflow documentation update.

- `docs/signing-and-release.md`
  Rewrite from ZIP-first guidance to DMG-first distribution, release secrets, tag format, and notarization flow.

- `docs/handoff-notes.md`
  Record that DMG packaging/release automation exists and call out any macOS-only validation still pending.

## Scope Guardrails

- Do not add `.pkg` packaging or installer scripts.
- Do not introduce third-party DMG tooling.
- Do not make ordinary CI depend on Apple credentials.
- Do not publish unsigned or unnotarized artifacts from the release workflow.
- Keep local packaging usable without release secrets.

### Task 1: Extend app packaging for release signing

**Files:**
- Modify: `scripts/package-app.sh`
- Create: `entitlements.plist`

- [ ] **Step 1: Capture the current failure for release-only inputs**

Run:

```bash
rg -n "options runtime|entitlements|timestamp|SIGN_IDENTITY" scripts/package-app.sh entitlements.plist
```

Expected before changes:
- no hardened runtime signing flags in `scripts/package-app.sh`
- no checked-in `entitlements.plist`

- [ ] **Step 2: Add the release entitlements file**

Create `entitlements.plist` with this initial content:

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

- [ ] **Step 3: Extend `scripts/package-app.sh` to support local and release signing modes**

Update the script so it:

- reads the bundle version from `Sources/Quickey/Resources/Info.plist`
- accepts signing-related environment variables
- keeps the current local fallback if no release identity is provided
- uses hardened runtime signing options only when a release identity is provided

Use this shell structure for the signing section:

```bash
SIGN_IDENTITY="${SIGN_IDENTITY:-Quickey}"
ENTITLEMENTS_PLIST="${ENTITLEMENTS_PLIST:-$PROJECT_DIR/entitlements.plist}"
ENABLE_HARDENED_RUNTIME="${ENABLE_HARDENED_RUNTIME:-0}"
ENABLE_TIMESTAMP="${ENABLE_TIMESTAMP:-0}"

if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$SIGN_IDENTITY"; then
    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID")

    if [ "$ENABLE_HARDENED_RUNTIME" = "1" ]; then
        SIGN_ARGS+=(--options runtime)
        if [ -f "$ENTITLEMENTS_PLIST" ]; then
            SIGN_ARGS+=(--entitlements "$ENTITLEMENTS_PLIST")
        fi
    fi

    if [ "$ENABLE_TIMESTAMP" = "1" ]; then
        SIGN_ARGS+=(--timestamp)
    fi

    codesign "${SIGN_ARGS[@]}" "$APP_DIR"
else
    echo "==> Ad-hoc signed (no '$SIGN_IDENTITY' cert found)."
fi
```

Keep the existing local-friendly behavior when no release cert is available.

- [ ] **Step 4: Verify the new script shape**

Run:

```bash
rg -n "ENABLE_HARDENED_RUNTIME|ENABLE_TIMESTAMP|ENTITLEMENTS_PLIST|options runtime|timestamp" scripts/package-app.sh
plutil -lint entitlements.plist
```

Expected:
- the new environment variables and `codesign` flags are present
- `entitlements.plist` reports `OK`

- [ ] **Step 5: Run packaging and verify the app bundle still builds locally**

Run:

```bash
bash scripts/package-app.sh
codesign --verify --deep --strict --verbose=2 build/Quickey.app
```

Expected:
- `build/Quickey.app` is recreated
- `codesign --verify` exits 0

### Task 2: Add native DMG packaging

**Files:**
- Create: `scripts/package-dmg.sh`

- [ ] **Step 1: Verify the DMG packager does not exist yet**

Run:

```bash
test -f scripts/package-dmg.sh
```

Expected before changes:
- exit status 1

- [ ] **Step 2: Create `scripts/package-dmg.sh`**

Create the script with this structure:

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Quickey"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
INFO_PLIST="$PROJECT_DIR/Sources/Quickey/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"
STAGING_DIR="$(mktemp -d "$BUILD_DIR/${APP_NAME}.dmg.staging.XXXXXX")"
VOLUME_NAME="${APP_NAME}"
DMG_SIGN_IDENTITY="${DMG_SIGN_IDENTITY:-}"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [ ! -d "$APP_DIR" ]; then
  bash "$SCRIPT_DIR/package-app.sh"
fi

rm -rf "$DMG_PATH"
cp -R "$APP_DIR" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [ -n "$DMG_SIGN_IDENTITY" ]; then
  codesign --force --sign "$DMG_SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi
```

Make the script executable.

- [ ] **Step 3: Run the new script and verify the first green path**

Run:

```bash
bash scripts/package-dmg.sh
test -f build/Quickey-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Quickey/Resources/Info.plist).dmg
```

Expected:
- the script exits 0
- the DMG file exists in `build/`

- [ ] **Step 4: Mount the DMG and verify its contents**

Run:

```bash
DMG="build/Quickey-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Quickey/Resources/Info.plist).dmg"
MOUNT_OUTPUT="$(hdiutil attach "$DMG" -nobrowse)"
MOUNT_POINT="$(printf '%s\n' "$MOUNT_OUTPUT" | tail -n 1 | awk '{print $3}')"
test -d "$MOUNT_POINT/Quickey.app"
test -L "$MOUNT_POINT/Applications"
hdiutil detach "$MOUNT_POINT"
```

Expected:
- both content checks succeed
- detach exits 0

### Task 3: Extend CI to verify the DMG path

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add the DMG packaging and verification steps**

Extend the existing workflow after the app-bundle packaging step with:

```yaml
      - name: Package DMG
        run: bash scripts/package-dmg.sh

      - name: Verify DMG
        run: |
          VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Quickey/Resources/Info.plist)"
          test -f "build/Quickey-${VERSION}.dmg"
```

Keep `permissions.contents` read-only in CI.

- [ ] **Step 2: Sanity-check the workflow diff**

Run:

```bash
git diff -- .github/workflows/ci.yml
rg -n "Package DMG|Verify DMG" .github/workflows/ci.yml
```

Expected:
- the workflow now verifies the DMG path
- no release secrets are referenced

### Task 4: Add a release workflow for signed, notarized DMG publication

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create the release workflow**

Add `.github/workflows/release.yml` with these key sections:

```yaml
name: Release

on:
  push:
    tags:
      - "v*"
  workflow_dispatch:

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-15
```

The workflow should:

- checkout the repo
- import the base64-encoded `.p12` certificate into a temporary keychain
- run `swift test`
- run `scripts/package-app.sh` with:
  `SIGN_IDENTITY`
  `ENABLE_HARDENED_RUNTIME=1`
  `ENABLE_TIMESTAMP=1`
  `ENTITLEMENTS_PLIST=$GITHUB_WORKSPACE/entitlements.plist`
- run `scripts/package-dmg.sh` with:
  `DMG_SIGN_IDENTITY`
- submit the DMG with `xcrun notarytool submit --wait`
- staple the DMG
- validate with `xcrun stapler validate` and `spctl`
- create a GitHub Release and upload the DMG asset

Use secrets with these names:

- `DEVELOPER_ID_APP_CERT_BASE64`
- `DEVELOPER_ID_APP_CERT_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `DEVELOPER_ID_APP_SIGNING_IDENTITY`
- `NOTARYTOOL_KEY`
- `NOTARYTOOL_KEY_ID`
- `NOTARYTOOL_ISSUER`

- [ ] **Step 2: Review the release workflow for fail-closed behavior**

Run:

```bash
rg -n "notarytool submit|stapler staple|stapler validate|spctl|upload-release-asset|softprops/action-gh-release" .github/workflows/release.yml
```

Expected:
- notarization, stapling, validation, and release upload steps are all present
- there is no branch that uploads a release asset before notarization succeeds

- [ ] **Step 3: Review the secret usage**

Run:

```bash
rg -n "secrets\\." .github/workflows/ci.yml .github/workflows/release.yml
```

Expected:
- only `release.yml` references release secrets
- `ci.yml` remains credential-free

### Task 5: Update release documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/README.md`
- Modify: `docs/signing-and-release.md`
- Modify: `docs/handoff-notes.md`

- [ ] **Step 1: Rewrite the public release guidance around DMG distribution**

Make these documentation changes:

- `README.md`
  mention `scripts/package-dmg.sh` in build/release commands
- `docs/signing-and-release.md`
  replace ZIP-first guidance with DMG-first distribution, release secrets, tag format, notarization, and GitHub Release flow
- `docs/README.md`
  keep the docs index accurate if release workflow coverage or release docs wording changes
- `docs/handoff-notes.md`
  note that DMG packaging/release automation exists and what still requires macOS credential-backed validation

- [ ] **Step 2: Verify the docs mention the new DMG flow**

Run:

```bash
rg -n "package-dmg|DMG|notarytool|v\\*" README.md docs/README.md docs/signing-and-release.md docs/handoff-notes.md
```

Expected:
- all key release docs mention the DMG path and notarization flow

### Task 6: Run the end-to-end verification set

**Files:**
- Modify: `scripts/package-app.sh`
- Modify: `scripts/package-dmg.sh`
- Modify: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`
- Modify: `README.md`
- Modify: `docs/README.md`
- Modify: `docs/signing-and-release.md`
- Modify: `docs/handoff-notes.md`
- Create: `entitlements.plist`

- [ ] **Step 1: Run the local verification commands**

Run:

```bash
swift test
bash scripts/package-app.sh
bash scripts/package-dmg.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Quickey/Resources/Info.plist)"
test -f "build/Quickey-${VERSION}.dmg"
```

Expected:
- tests pass
- the packaged app and DMG both exist

- [ ] **Step 2: Mount and inspect the final DMG**

Run:

```bash
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Quickey/Resources/Info.plist)"
DMG="build/Quickey-${VERSION}.dmg"
MOUNT_OUTPUT="$(hdiutil attach "$DMG" -nobrowse)"
MOUNT_POINT="$(printf '%s\n' "$MOUNT_OUTPUT" | tail -n 1 | awk '{print $3}')"
ls "$MOUNT_POINT"
hdiutil detach "$MOUNT_POINT"
```

Expected:
- mounted contents include `Quickey.app` and `Applications`
- detach exits 0

- [ ] **Step 3: Review the final diff**

Run:

```bash
git diff -- scripts/package-app.sh scripts/package-dmg.sh entitlements.plist .github/workflows/ci.yml .github/workflows/release.yml README.md docs/README.md docs/signing-and-release.md docs/handoff-notes.md
```

Expected:
- the diff stays focused on packaging, release automation, and documentation
- no unrelated app runtime code changed

- [ ] **Step 4: Commit**

```bash
git add scripts/package-app.sh scripts/package-dmg.sh entitlements.plist .github/workflows/ci.yml .github/workflows/release.yml README.md docs/README.md docs/signing-and-release.md docs/handoff-notes.md docs/superpowers/plans/2026-04-08-dmg-release-pipeline.md
git commit -m "增加 DMG 打包与发布流程"
```
