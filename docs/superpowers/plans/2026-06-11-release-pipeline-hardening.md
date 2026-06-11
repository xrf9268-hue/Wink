# Release Pipeline Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the release pipeline hardening spec ([2026-06-11-release-pipeline-hardening-design.md](../specs/2026-06-11-release-pipeline-hardening-design.md)) as three sequential PRs: feed safety gate (#277), version & notes management (#278), dry-run rehearsal & caching (#279).

**Architecture:** Gate logic lives in new bash scripts under `scripts/` with bats unit tests; `release.yml` and `ci.yml` stay thin orchestrators. The CI appcast step doubles as a permanent merge-semantics rehearsal using a committed fixture old appcast.

**Tech Stack:** bash, bats-core, GitHub Actions, Sparkle `generate_appcast`, PlistBuddy.

**Key facts an implementer must know:**

- The repo has **never published a `v*` release** (no `v*` tags, no GitHub releases). The live R2 feed most likely 404s. The first real release therefore needs the `WINK_ALLOW_FIRST_RELEASE=1` escape hatch, wired as a GitHub repository **variable** (`vars.WINK_ALLOW_FIRST_RELEASE`) the maintainer sets once and removes afterwards.
- `Info.plist` is at `Sources/Wink/Resources/Info.plist`; current `CFBundleShortVersionString` 0.4.1, `CFBundleVersion` 5.
- `generate_appcast` merges off an appcast file present in the directory it scans; `--maximum-versions` defaults to 3. We copy the restored feed into **both** the staging dir and the `-o` path — whichever one the tool merges from, the result is identical, and the CI assertions prove it.
- Repo convention: actions pinned by commit SHA; PRs squash-merged with `(#NNN)` suffix; every PR goes through the review-gate workflow.
- Each PR branch starts from up-to-date `main`. PR A also carries the already-committed spec commits if they are not yet on `origin/main`.

---

## PR A — Feed safety gate (closes #277)

Branch: `release/feed-safety-gate`

### Task A1: `scripts/verify-release-feed.sh` with bats tests (TDD)

**Files:**
- Create: `scripts/verify-release-feed.bats`
- Create: `scripts/verify-release-feed.sh`

- [ ] **Step 1: Write the failing tests**

Create `scripts/verify-release-feed.bats`:

```bash
#!/usr/bin/env bats
# Unit tests for scripts/verify-release-feed.sh (spec §1). curl is shimmed via PATH.

setup() {
  SHIM_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$SHIM_DIR"
  cat >"$SHIM_DIR/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: honors -o <file>, body from $FAKE_BODY_FILE, status from $FAKE_HTTP_CODE,
# transport failure when FAKE_CURL_FAIL=1.
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  prev="$arg"
done
if [ "${FAKE_CURL_FAIL:-}" = "1" ]; then exit 6; fi
if [ -n "$out" ]; then
  if [ -n "${FAKE_BODY_FILE:-}" ]; then cp "$FAKE_BODY_FILE" "$out"; else : >"$out"; fi
fi
printf '%s' "${FAKE_HTTP_CODE:-200}"
SH
  chmod +x "$SHIM_DIR/curl"

  PLIST="$BATS_TEST_TMPDIR/Info.plist"
  cat >"$PLIST" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>0.4.1</string>
  <key>CFBundleVersion</key><string>5</string>
</dict></plist>
XML

  RESTORED="$BATS_TEST_TMPDIR/live-appcast.xml"
  SCRIPT="$BATS_TEST_DIRNAME/verify-release-feed.sh"
}

make_feed() { # $1 = sparkle:version value, element form
  local f="$BATS_TEST_TMPDIR/feed.xml"
  cat >"$f" <<XML
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><title>old</title><sparkle:version>$1</sparkle:version></item>
</channel></rss>
XML
  printf '%s' "$f"
}

run_gate() { # extra env pairs as args, then optional --mode
  run env PATH="$SHIM_DIR:$PATH" \
    INFO_PLIST="$PLIST" \
    SPARKLE_PUBLIC_BASE_URL="https://example.invalid/wink" \
    SPARKLE_RESTORED_APPCAST="$RESTORED" \
    "$@" bash "$SCRIPT"
}

@test "passes when live max is lower than CFBundleVersion" {
  run_gate FAKE_HTTP_CODE=200 FAKE_BODY_FILE="$(make_feed 4)"
  [ "$status" -eq 0 ]
  [ -f "$RESTORED" ]
}

@test "fails in release mode when CFBundleVersion equals live max" {
  run_gate FAKE_HTTP_CODE=200 FAKE_BODY_FILE="$(make_feed 5)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already live"* ]]
}

@test "fails in release mode when CFBundleVersion is lower than live max" {
  run_gate FAKE_HTTP_CODE=200 FAKE_BODY_FILE="$(make_feed 6)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bump-version"* ]]
}

@test "rehearse mode passes on equal version" {
  run env PATH="$SHIM_DIR:$PATH" INFO_PLIST="$PLIST" \
    SPARKLE_PUBLIC_BASE_URL="https://example.invalid/wink" \
    SPARKLE_RESTORED_APPCAST="$RESTORED" \
    FAKE_HTTP_CODE=200 FAKE_BODY_FILE="$(make_feed 5)" \
    bash "$SCRIPT" --mode rehearse
  [ "$status" -eq 0 ]
}

@test "parses legacy enclosure-attribute sparkle:version form" {
  local f="$BATS_TEST_TMPDIR/feed-attr.xml"
  cat >"$f" <<'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><enclosure url="https://x.invalid/a.zip" sparkle:version="4" /></item>
</channel></rss>
XML
  run_gate FAKE_HTTP_CODE=200 FAKE_BODY_FILE="$f"
  [ "$status" -eq 0 ]
}

@test "fails on feed with no parseable sparkle:version" {
  local f="$BATS_TEST_TMPDIR/garbage.xml"
  echo "<rss><channel></channel></rss>" >"$f"
  run_gate FAKE_HTTP_CODE=200 FAKE_BODY_FILE="$f"
  [ "$status" -ne 0 ]
  [[ "$output" == *"corrupt"* ]]
}

@test "404 fails without WINK_ALLOW_FIRST_RELEASE" {
  run_gate FAKE_HTTP_CODE=404
  [ "$status" -ne 0 ]
  [[ "$output" == *"WINK_ALLOW_FIRST_RELEASE"* ]]
}

@test "404 passes with WINK_ALLOW_FIRST_RELEASE=1 and leaves no restored file" {
  run_gate FAKE_HTTP_CODE=404 WINK_ALLOW_FIRST_RELEASE=1
  [ "$status" -eq 0 ]
  [ ! -f "$RESTORED" ]
}

@test "5xx hard-fails even with WINK_ALLOW_FIRST_RELEASE=1" {
  run_gate FAKE_HTTP_CODE=500 WINK_ALLOW_FIRST_RELEASE=1
  [ "$status" -ne 0 ]
}

@test "transport-level curl failure hard-fails" {
  run_gate FAKE_CURL_FAIL=1
  [ "$status" -ne 0 ]
}

@test "rejects unknown arguments" {
  run_gate FAKE_HTTP_CODE=200 FAKE_BODY_FILE="$(make_feed 4)" -- --bogus || true
  run env PATH="$SHIM_DIR:$PATH" INFO_PLIST="$PLIST" \
    SPARKLE_PUBLIC_BASE_URL="https://example.invalid/wink" \
    bash "$SCRIPT" --bogus
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats scripts/verify-release-feed.bats` (install once: `brew install bats-core`)
Expected: all tests FAIL (script does not exist).

- [ ] **Step 3: Implement the script**

Create `scripts/verify-release-feed.sh` (mode 755):

```bash
#!/usr/bin/env bash
# Release feed safety gate (spec docs/superpowers/specs/2026-06-11-release-pipeline-hardening-design.md §1).
# Restores the live Sparkle appcast to $SPARKLE_RESTORED_APPCAST and blocks any release whose
# CFBundleVersion would not move the feed strictly forward. --mode rehearse reports without enforcing.
# Only HTTP 404 *with* WINK_ALLOW_FIRST_RELEASE=1 may skip the comparison; fetch errors always fail.
set -euo pipefail

MODE="release"
while [ $# -gt 0 ]; do
    case "$1" in
        --mode)
            MODE="${2:?--mode requires release|rehearse}"
            shift 2
            ;;
        *)
            echo "Error: unknown argument '$1' (usage: verify-release-feed.sh [--mode release|rehearse])" >&2
            exit 64
            ;;
    esac
done
case "$MODE" in
    release|rehearse) ;;
    *)
        echo "Error: --mode must be release or rehearse, got '$MODE'" >&2
        exit 64
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="${INFO_PLIST:-$PROJECT_DIR/Sources/Wink/Resources/Info.plist}"
RESTORED_APPCAST="${SPARKLE_RESTORED_APPCAST:-$PROJECT_DIR/build/live-appcast.xml}"

if [ -z "${SPARKLE_PUBLIC_BASE_URL:-}" ]; then
    echo "Error: SPARKLE_PUBLIC_BASE_URL must point to the public update directory." >&2
    exit 1
fi
SPARKLE_PUBLIC_BASE_URL="$(printf '%s' "$SPARKLE_PUBLIC_BASE_URL" | sed 's#/*$#/#')"
FEED_URL="${SPARKLE_PUBLIC_BASE_URL}appcast.xml"

NEW_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
if ! printf '%s' "$NEW_BUILD" | grep -qE '^[0-9]+$'; then
    echo "Error: CFBundleVersion '$NEW_BUILD' is not a non-negative integer — fix $INFO_PLIST." >&2
    exit 1
fi

mkdir -p "$(dirname "$RESTORED_APPCAST")"
HTTP="$(curl -sSL --retry 3 --retry-all-errors -w '%{http_code}' -o "$RESTORED_APPCAST" "$FEED_URL" || echo 000)"
HTTP="${HTTP##*$'\n'}"

if [ "$HTTP" = "404" ]; then
    rm -f "$RESTORED_APPCAST"
    if [ "${WINK_ALLOW_FIRST_RELEASE:-}" = "1" ]; then
        echo "Live feed returned 404 and WINK_ALLOW_FIRST_RELEASE=1 — treating as first release."
        exit 0
    fi
    echo "Error: live feed $FEED_URL returned 404." >&2
    echo "If this is genuinely the first release, set WINK_ALLOW_FIRST_RELEASE=1; otherwise check SPARKLE_PUBLIC_BASE_URL." >&2
    exit 1
fi

if [ "$HTTP" != "200" ]; then
    rm -f "$RESTORED_APPCAST"
    echo "Error: fetching live feed $FEED_URL failed (HTTP $HTTP)." >&2
    echo "A fetch error must never be treated as a first release — re-run or investigate the feed host." >&2
    exit 1
fi

MAX_LIVE="$(
    {
        grep -oE '<sparkle:version>[0-9]+</sparkle:version>' "$RESTORED_APPCAST" || true
        grep -oE 'sparkle:version="[0-9]+"' "$RESTORED_APPCAST" || true
    } | grep -oE '[0-9]+' | sort -n | tail -1 || true
)"
if [ -z "$MAX_LIVE" ]; then
    echo "Error: restored feed $RESTORED_APPCAST has no parseable sparkle:version — feed corrupt?" >&2
    exit 1
fi

echo "Live feed max sparkle:version: $MAX_LIVE; this build's CFBundleVersion: $NEW_BUILD"

if [ "$MODE" = "rehearse" ]; then
    echo "Rehearse mode: version comparison reported, not enforced."
    exit 0
fi

if [ "$NEW_BUILD" -eq "$MAX_LIVE" ]; then
    echo "Error: CFBundleVersion $NEW_BUILD is already live — re-publishing a released version is not supported; bump a new version instead (scripts/bump-version.sh)." >&2
    exit 1
fi
if [ "$NEW_BUILD" -lt "$MAX_LIVE" ]; then
    echo "Error: CFBundleVersion $NEW_BUILD is lower than the live feed's $MAX_LIVE — forgot to run scripts/bump-version.sh?" >&2
    exit 1
fi

echo "Feed gate passed: $NEW_BUILD > $MAX_LIVE; restored live feed at $RESTORED_APPCAST"
```

(Note: the script mentions `scripts/bump-version.sh` which ships in PR B; the message is forward-looking on purpose.)

- [ ] **Step 4: Run tests, verify pass**

Run: `bats scripts/verify-release-feed.bats`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/verify-release-feed.sh scripts/verify-release-feed.bats
git commit -m "feat: add release feed safety gate script (Issue #277)"
```

### Task A2: appcast merge in `generate-appcast.sh` + CI fixture

**Files:**
- Modify: `scripts/generate-appcast.sh` (after the ZIP copy into `$STAGING_DIR`, around line 55; and the `APPCAST_CMD` array around line 67)
- Create: `scripts/fixtures/ci-old-appcast.xml`

- [ ] **Step 1: Create the fixture old appcast**

Create `scripts/fixtures/ci-old-appcast.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!-- CI fixture: a pre-existing feed entry whose archive is NOT in the staging dir.
     ci.yml feeds this to generate-appcast.sh via SPARKLE_RESTORED_APPCAST and then asserts
     the entry survives unchanged (URL, version, signature) next to the freshly generated one. -->
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Wink</title>
        <item>
            <title>0.0.1</title>
            <pubDate>Wed, 01 Jan 2025 00:00:00 +0000</pubDate>
            <sparkle:version>1</sparkle:version>
            <sparkle:shortVersionString>0.0.1</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <enclosure url="https://old.example.invalid/Wink-0.0.1.zip" length="100" type="application/octet-stream" sparkle:edSignature="fixturesignature==" />
        </item>
    </channel>
</rss>
```

- [ ] **Step 2: Modify `scripts/generate-appcast.sh`**

Immediately after `cp "$ZIP_PATH" "$STAGING_DIR/$(basename "$ZIP_PATH")"`, insert:

```bash
# Merge against the restored live feed (spec §2). generate_appcast merges off an appcast
# present where it scans; we copy to both the staging dir and the -o path so the merge
# happens regardless of which one this Sparkle version reads. Never put old archives here.
RESTORED_APPCAST="${SPARKLE_RESTORED_APPCAST:-$BUILD_DIR/live-appcast.xml}"
if [ -f "$RESTORED_APPCAST" ]; then
    cp "$RESTORED_APPCAST" "$STAGING_DIR/appcast.xml"
    cp "$RESTORED_APPCAST" "$APPCAST_PATH"
    echo "==> Merging against restored live feed: $RESTORED_APPCAST"
elif [ "${WINK_ALLOW_FIRST_RELEASE:-}" = "1" ]; then
    echo "==> No restored feed; WINK_ALLOW_FIRST_RELEASE=1 — generating a fresh feed."
else
    echo "Error: restored live feed not found at $RESTORED_APPCAST." >&2
    echo "Run scripts/verify-release-feed.sh first, or set WINK_ALLOW_FIRST_RELEASE=1 for a genuine first release." >&2
    exit 1
fi
```

In the `APPCAST_CMD` array, add `--maximum-versions 0` right after `--maximum-deltas 0` (the tool defaults to keeping only the newest 3 entries):

```bash
APPCAST_CMD=(
    "$GENERATE_APPCAST_BIN"
    --maximum-deltas 0
    --maximum-versions 0
    --download-url-prefix "$SPARKLE_PUBLIC_BASE_URL"
    --release-notes-url-prefix "$SPARKLE_PUBLIC_BASE_URL"
    -o "$APPCAST_PATH"
)
```

- [ ] **Step 3: Local merge rehearsal (the spec's §2 pin-down)**

```bash
swift build
SPARKLE_KEY_OUTPUT_DIR="$TMPDIR/wink-sparkle-keys" bash scripts/export-test-sparkle-keys.sh > /tmp/wink-keys.env
set -a; source /tmp/wink-keys.env; set +a
export SPARKLE_PUBLIC_BASE_URL="https://example.invalid/wink/"
export SPARKLE_FEED_URL="https://example.invalid/wink/appcast.xml"
export MACOS_MINIMUM_SYSTEM_VERSION=15.0
bash scripts/package-app.sh
bash scripts/package-update-zip.sh
rm -f build/appcast.xml
SPARKLE_RESTORED_APPCAST=scripts/fixtures/ci-old-appcast.xml bash scripts/generate-appcast.sh

# Assertions — all must succeed:
grep -q "https://old.example.invalid/Wink-0.0.1.zip" build/appcast.xml   # old URL untouched by --download-url-prefix
grep -q "fixturesignature==" build/appcast.xml                            # old signature untouched
grep -q "<sparkle:version>1</sparkle:version>" build/appcast.xml          # old entry survives
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Wink/Resources/Info.plist)"
grep -q "Wink-${VERSION}" build/appcast.xml                               # new entry present
test "$(grep -c '<item>' build/appcast.xml)" -ge 2                        # both entries present
echo OK
```

If the old entry does NOT survive, the merge-source assumption is wrong — investigate `generate_appcast --help` for this pinned Sparkle version and adjust where the restored feed is copied, then re-run until the assertions pass. Do not proceed with a failing rehearsal.

Also verify the hard-fail path:

```bash
rm -f build/appcast.xml build/live-appcast.xml
if bash scripts/generate-appcast.sh; then echo "BUG: should have failed"; else echo "OK: hard-fails without restored feed"; fi
WINK_ALLOW_FIRST_RELEASE=1 bash scripts/generate-appcast.sh && echo "OK: fresh-feed opt-in works"
```

- [ ] **Step 4: Commit**

```bash
git add scripts/generate-appcast.sh scripts/fixtures/ci-old-appcast.xml
git commit -m "feat: preserve appcast history when generating the Sparkle feed (Issue #277)"
```

### Task A3: wire the gate into `release.yml`

**Files:**
- Modify: `.github/workflows/release.yml` (concurrency block lines 17–19; new step after "Resolve release metadata" ~line 193; "Verify appcast" step lines 282–283)

- [ ] **Step 1: Fix the concurrency group**

Replace:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false
```

with:

```yaml
# Serialize ALL release runs: two tags racing on the R2 appcast upload must never interleave
# (spec §3). GitHub holds 1 running + 1 pending; a 3rd run cancels the pending one — re-run it.
concurrency:
  group: ${{ github.workflow }}
  cancel-in-progress: false
```

- [ ] **Step 2: Add the gate step**

Insert immediately after the "Resolve release metadata" step (which exports `R2_PUBLIC_BASE_URL` to `$GITHUB_ENV`):

```yaml
      - name: Verify release feed gate
        env:
          WINK_ALLOW_FIRST_RELEASE: ${{ vars.WINK_ALLOW_FIRST_RELEASE }}
        run: |
          SPARKLE_PUBLIC_BASE_URL="$R2_PUBLIC_BASE_URL" bash scripts/verify-release-feed.sh --mode release
```

- [ ] **Step 3: Strengthen the "Verify appcast" step**

Replace `run: test -f "$APPCAST_PATH"` with:

```yaml
        run: |
          test -f "$APPCAST_PATH"
          grep -q "Wink-${VERSION}" "$APPCAST_PATH"
          grep -q 'edSignature' "$APPCAST_PATH"
          if [ -f build/live-appcast.xml ]; then
            OLD_COUNT="$(grep -c '<item>' build/live-appcast.xml || true)"
            NEW_COUNT="$(grep -c '<item>' "$APPCAST_PATH" || true)"
            if [ "$NEW_COUNT" -lt "$OLD_COUNT" ]; then
              echo "Error: generated appcast has $NEW_COUNT items but the live feed had $OLD_COUNT — history lost" >&2
              exit 1
            fi
          fi
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: gate releases on the live feed and serialize release runs (Issue #277)"
```

### Task A4: wire bats + merge rehearsal into `ci.yml`

**Files:**
- Modify: `.github/workflows/ci.yml` (new step after "Swift version" ~line 29; "Generate Sparkle appcast" step line 69–70; "Verify Sparkle appcast" step lines 72–76)

- [ ] **Step 1: Add a bats step** (after "Swift version", before "Build (debug)" — fail fast on script regressions):

```yaml
      - name: Release script unit tests
        run: |
          brew install bats-core
          bats scripts/verify-release-feed.bats
```

- [ ] **Step 2: Make the CI appcast step exercise the merge path**

Replace the "Generate Sparkle appcast" step's run line with:

```yaml
        run: SPARKLE_RESTORED_APPCAST=scripts/fixtures/ci-old-appcast.xml bash scripts/generate-appcast.sh
```

- [ ] **Step 3: Strengthen "Verify Sparkle appcast"** — replace its run block with:

```yaml
        run: |
          test -f build/appcast.xml
          grep -q "Wink-" build/appcast.xml
          grep -q "https://example.invalid/wink/" build/appcast.xml
          # Merge-semantics rehearsal assertions (spec §2): the fixture entry must survive
          # untouched next to the freshly generated entry.
          grep -q "https://old.example.invalid/Wink-0.0.1.zip" build/appcast.xml
          grep -q "fixturesignature==" build/appcast.xml
          grep -q "<sparkle:version>1</sparkle:version>" build/appcast.xml
          test "$(grep -c '<item>' build/appcast.xml)" -ge 2
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run release-script bats tests and assert appcast merge semantics (Issue #277)"
```

### Task A5: docs + PR

**Files:**
- Modify: `docs/signing-and-release.md`

- [ ] **Step 1: Update the docs**

In `docs/signing-and-release.md`:
- In the workflow-steps list (~lines 158–163), add the feed gate step after the tag↔version check: "Run `scripts/verify-release-feed.sh --mode release`: restores the live appcast to `build/live-appcast.xml` and fails unless `CFBundleVersion` is strictly greater than the live feed's maximum `sparkle:version`."
- Replace any guidance about re-running an already-published tag (~line 193) with: "Re-running a tag after its feed entry is live is blocked by the feed gate. To repair a published release, bump to a new version instead."
- Add a "First release" note: "If the live feed legitimately does not exist yet, set the repository variable `WINK_ALLOW_FIRST_RELEASE` to `1` for the first run and delete the variable afterwards."

- [ ] **Step 2: Full local check, push, PR**

```bash
swift test
bats scripts/verify-release-feed.bats
git add docs/signing-and-release.md
git commit -m "docs: document the release feed gate and first-release procedure (Issue #277)"
git push -u origin release/feed-safety-gate
gh pr create --title "Release feed safety gate, appcast history preservation, serial concurrency (Issue #277)" --body "Implements Issue #277 per docs/superpowers/specs/2026-06-11-release-pipeline-hardening-design.md §1–3. Closes #277."
```

Then watch CI (`gh pr checks --watch`), fix failures, and merge per repo flow.

---

## PR B — Version & notes management (closes #278)

Branch: `release/changelog-and-bump` (from updated `main` after PR A merges)

### Task B1: `CHANGELOG.md`

**Files:**
- Create: `CHANGELOG.md`

- [ ] **Step 1: Create it**

```markdown
# Changelog

Newest first. One `## X.Y.Z` section per release, written by hand **before** running
`scripts/bump-version.sh X.Y.Z`. `scripts/release-notes.sh X.Y.Z` extracts a section as the
GitHub Release body; the release workflow fails if the tagged version has no section here.

## 0.4.1

- Baseline entry: current version at the time the changelog was introduced. No `v*` release
  has been published yet; the first published release gets a full section.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: introduce hand-written CHANGELOG gating releases (Issue #278)"
```

### Task B2: `scripts/release-notes.sh` with bats (TDD)

**Files:**
- Create: `scripts/release-notes.bats`
- Create: `scripts/release-notes.sh`

- [ ] **Step 1: Write the failing tests**

Create `scripts/release-notes.bats`:

```bash
#!/usr/bin/env bats
# Unit tests for scripts/release-notes.sh (spec §5).

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/release-notes.sh"
  CL="$BATS_TEST_TMPDIR/CHANGELOG.md"
  cat >"$CL" <<'MD'
# Changelog

## 0.5.0

- New thing
- Fixed thing

## 0.4.1

- Older note
MD
}

@test "prints exactly the requested section body" {
  run env CHANGELOG="$CL" bash "$SCRIPT" 0.5.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"- New thing"* ]]
  [[ "$output" == *"- Fixed thing"* ]]
  [[ "$output" != *"Older note"* ]]
}

@test "version match is exact, not a regex-dot match" {
  # "0.5.0" must not match a hypothetical "0x5x0" heading; conversely "0.4.1" only matches itself
  run env CHANGELOG="$CL" bash "$SCRIPT" 0.4.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Older note"* ]]
  [[ "$output" != *"New thing"* ]]
}

@test "fails when the section is missing" {
  run env CHANGELOG="$CL" bash "$SCRIPT" 9.9.9
  [ "$status" -ne 0 ]
}

@test "fails when the section is empty" {
  cat >"$CL" <<'MD'
## 0.6.0

## 0.5.0

- Real content
MD
  run env CHANGELOG="$CL" bash "$SCRIPT" 0.6.0
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats scripts/release-notes.bats` — expected: FAIL (no script).

- [ ] **Step 3: Implement**

Create `scripts/release-notes.sh` (mode 755):

```bash
#!/usr/bin/env bash
# Print the CHANGELOG.md body for one version (spec §5). release.yml calls this both as an
# early gate and to produce the GitHub Release body (--notes-file).
#   ./scripts/release-notes.sh X.Y.Z
set -euo pipefail

VER="${1:?usage: release-notes.sh X.Y.Z}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHANGELOG="${CHANGELOG:-$PROJECT_DIR/CHANGELOG.md}"

if [ ! -f "$CHANGELOG" ]; then
    echo "Error: $CHANGELOG not found" >&2
    exit 1
fi

# Exact heading match ("## X.Y.Z"), body runs until the next "## " heading or EOF.
NOTES="$(awk -v ver="$VER" '
    $1 == "##" && $2 == ver { found = 1; next }
    $1 == "##" { if (found) exit }
    found { print }
' "$CHANGELOG")"

if ! printf '%s' "$NOTES" | grep -q '[^[:space:]]'; then
    echo "Error: CHANGELOG.md has no non-empty '## $VER' section — write the release notes first" >&2
    exit 1
fi
printf '%s\n' "$NOTES"
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bats scripts/release-notes.bats` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/release-notes.sh scripts/release-notes.bats
git commit -m "feat: extract curated release notes from CHANGELOG (Issue #278)"
```

### Task B3: `scripts/bump-version.sh` with bats (TDD)

**Files:**
- Create: `scripts/bump-version.bats`
- Create: `scripts/bump-version.sh`

- [ ] **Step 1: Write the failing tests**

Create `scripts/bump-version.bats`:

```bash
#!/usr/bin/env bats
# Unit tests for scripts/bump-version.sh (spec §4).

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/bump-version.sh"
  PLIST="$BATS_TEST_TMPDIR/Info.plist"
  cat >"$PLIST" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>0.4.1</string>
  <key>CFBundleVersion</key><string>5</string>
</dict></plist>
XML
  CL="$BATS_TEST_TMPDIR/CHANGELOG.md"
  printf '# Changelog\n\n## 0.5.0\n\n- Something new\n' >"$CL"
}

run_bump() {
  run env INFO_PLIST="$PLIST" CHANGELOG="$CL" bash "$SCRIPT" "$@"
}

@test "successful bump writes version and increments build" {
  run_bump 0.5.0
  [ "$status" -eq 0 ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "0.5.0" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" = "6" ]
}

@test "rejects non-semver argument" {
  run_bump 1.2
  [ "$status" -ne 0 ]
  run_bump v1.2.3
  [ "$status" -ne 0 ]
}

@test "rejects bumping to the current version" {
  run_bump 0.4.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"already"* ]]
}

@test "rejects bump without a CHANGELOG section" {
  run_bump 0.6.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHANGELOG"* ]]
}

@test "rejects non-integer CFBundleVersion" {
  /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 5.1' "$PLIST"
  run_bump 0.5.0
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats scripts/bump-version.bats` — expected: FAIL (no script).

- [ ] **Step 3: Implement**

Create `scripts/bump-version.sh` (mode 755):

```bash
#!/usr/bin/env bash
# Release step one: sync version numbers (spec docs/superpowers/specs/2026-06-11-release-pipeline-hardening-design.md §4).
#   ./scripts/bump-version.sh X.Y.Z
# Writes Info.plist: CFBundleShortVersionString = X.Y.Z and CFBundleVersion += 1 (monotonic
# integer — Sparkle compares it as sparkle:version). Precondition: CHANGELOG.md already has a
# "## X.Y.Z" section; notes are creative content written by a human first, this script only gates.
set -euo pipefail

VER="${1:?usage: bump-version.sh X.Y.Z}"
if [[ ! "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: version must be three-part semver (X.Y.Z), got '$VER'" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="${INFO_PLIST:-$PROJECT_DIR/Sources/Wink/Resources/Info.plist}"
CHANGELOG="${CHANGELOG:-$PROJECT_DIR/CHANGELOG.md}"

CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
if [ "$VER" = "$CURRENT" ]; then
    echo "Error: version is already $CURRENT — nothing to bump" >&2
    exit 1
fi
if ! awk -v ver="$VER" '$1 == "##" && $2 == ver { found = 1 } END { exit !found }' "$CHANGELOG"; then
    echo "Error: CHANGELOG.md has no '## $VER' section — write the release notes first" >&2
    exit 1
fi
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "Error: CFBundleVersion '$BUILD' is not a non-negative integer — fix $INFO_PLIST first" >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((BUILD + 1))" "$INFO_PLIST"
echo "Bumped $CURRENT -> $VER (CFBundleVersion $BUILD -> $((BUILD + 1)))"
echo "Next: swift test -> commit -> git tag v$VER -> git push origin main --tags"
```

- [ ] **Step 4: Run tests, verify pass**

Run: `bats scripts/bump-version.bats` — expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/bump-version.sh scripts/bump-version.bats
git commit -m "feat: add gated version bump script (Issue #278)"
```

### Task B4: wire notes into `release.yml` and bats into `ci.yml`

**Files:**
- Modify: `.github/workflows/release.yml` (notes gate after the feed gate step; "Generate appcast" step; "Publish GitHub Release" step lines ~325–335)
- Modify: `.github/workflows/ci.yml` ("Release script unit tests" step)

- [ ] **Step 1: Notes gate + notes file**

Insert after the "Verify release feed gate" step:

```yaml
      - name: Extract release notes
        run: |
          bash scripts/release-notes.sh "$VERSION" > "$RUNNER_TEMP/release-notes.md"
          echo "RELEASE_NOTES_PATH=$RUNNER_TEMP/release-notes.md" >> "$GITHUB_ENV"
```

- [ ] **Step 2: Per-tag Sparkle notes URL**

In the "Generate appcast" step, before `bash scripts/generate-appcast.sh`, add:

```yaml
          export SPARKLE_FULL_RELEASE_NOTES_URL="https://github.com/${GITHUB_REPOSITORY}/releases/tag/${RELEASE_TAG}"
```

- [ ] **Step 3: Replace `--generate-notes` and refresh notes on re-run**

Replace the "Publish GitHub Release" run block with:

```yaml
        run: |
          if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
            gh release upload "$RELEASE_TAG" "$DMG_PATH" --clobber
            gh release edit "$RELEASE_TAG" --notes-file "$RELEASE_NOTES_PATH"
          else
            gh release create "$RELEASE_TAG" "$DMG_PATH" \
              --title "$RELEASE_TAG" \
              --notes-file "$RELEASE_NOTES_PATH"
          fi
```

- [ ] **Step 4: Extend the CI bats step**

```yaml
      - name: Release script unit tests
        run: |
          brew install bats-core
          bats scripts/verify-release-feed.bats scripts/release-notes.bats scripts/bump-version.bats
```

- [ ] **Step 5: Update docs, commit, PR**

In `docs/signing-and-release.md`, replace the manual "Update `CFBundleShortVersionString` and `CFBundleVersion` in Info.plist" instruction (~line 187) with: "Write the `## X.Y.Z` section in `CHANGELOG.md`, then run `./scripts/bump-version.sh X.Y.Z`."

```bash
swift test
bats scripts/verify-release-feed.bats scripts/release-notes.bats scripts/bump-version.bats
git add .github/workflows/release.yml .github/workflows/ci.yml docs/signing-and-release.md
git commit -m "ci: gate releases on CHANGELOG notes and publish curated release bodies (Issue #278)"
git push -u origin release/changelog-and-bump
gh pr create --title "CHANGELOG, bump-version script, curated release notes (Issue #278)" --body "Implements Issue #278 per the spec §4–5, §7. Closes #278."
```

---

## PR C — Dry-run rehearsal & SwiftPM cache (closes #279)

Branch: `release/dry-run-and-cache` (from updated `main` after PR B merges)

### Task C1: dry-run mode in `release.yml`

**Files:**
- Modify: `.github/workflows/release.yml` (workflow_dispatch inputs lines 7–12; readiness resolve step lines 30–41; "Checkout manual release tag" condition line 142; "Resolve release metadata" lines 158–193; gate step; publish-side steps)

- [ ] **Step 1: Inputs**

```yaml
  workflow_dispatch:
    inputs:
      release_tag:
        description: Existing v* tag to operate on; leave empty to rehearse the dispatched ref (forces dry run)
        required: false
        default: ""
        type: string
      dry_run:
        description: Build and validate everything, publish nothing
        required: false
        default: true
        type: boolean
```

- [ ] **Step 2: Readiness `release_ref` fallback**

In the "Resolve requested release ref" step, replace the assignment with:

```bash
          if [ "${GITHUB_EVENT_NAME}" = "workflow_dispatch" ] && [ -n "${MANUAL_RELEASE_TAG}" ]; then
            RELEASE_REF="${MANUAL_RELEASE_TAG}"
          else
            RELEASE_REF="${GITHUB_REF_NAME}"
          fi
```

- [ ] **Step 3: Skip tag checkout in ref-rehearsal mode**

Change the "Checkout manual release tag" condition to:

```yaml
        if: ${{ github.event_name == 'workflow_dispatch' && inputs.release_tag != '' }}
```

- [ ] **Step 4: Resolve `DRY_RUN` and make the tag checks conditional**

In "Resolve release metadata", replace the `RELEASE_TAG` resolution and validation with:

```bash
          if [ "${GITHUB_EVENT_NAME}" = "workflow_dispatch" ]; then
            if [ -z "${MANUAL_RELEASE_TAG}" ]; then
              RELEASE_TAG=""           # ref rehearsal: no tag, forced dry run
              DRY_RUN=true
            else
              RELEASE_TAG="${MANUAL_RELEASE_TAG}"
              DRY_RUN="${DRY_RUN_INPUT:-true}"
            fi
          else
            RELEASE_TAG="${GITHUB_REF_NAME}"
            DRY_RUN=false
          fi

          if [ -n "$RELEASE_TAG" ]; then
            case "$RELEASE_TAG" in
              v*) ;;
              *)
                echo "Error: release workflow requires a v* tag, got '$RELEASE_TAG'" >&2
                exit 1
                ;;
            esac
            if [ "v${VERSION}" != "$RELEASE_TAG" ]; then
              echo "Error: tag '$RELEASE_TAG' does not match Info.plist version 'v${VERSION}'" >&2
              exit 1
            fi
          fi

          echo "DRY_RUN=$DRY_RUN" >> "$GITHUB_ENV"
```

Add to the step's `env:` block: `DRY_RUN_INPUT: ${{ inputs.dry_run }}`. Where `RELEASE_TAG` is consumed for URLs (the Sparkle full-release-notes URL), fall back: `RELEASE_TAG_OR_PLANNED="${RELEASE_TAG:-v${VERSION}}"` and use that variable.

- [ ] **Step 5: Gate mode + publish-step conditions + artifact upload**

Gate step run block becomes:

```yaml
        run: |
          MODE=release
          if [ "$DRY_RUN" = "true" ]; then MODE=rehearse; fi
          SPARKLE_PUBLIC_BASE_URL="$R2_PUBLIC_BASE_URL" bash scripts/verify-release-feed.sh --mode "$MODE"
```

Add `if: env.DRY_RUN != 'true'` to these steps: "Install boto3 in a virtual environment", "Upload DMG and Sparkle ZIP to R2", "Publish GitHub Release", "Publish live Sparkle appcast to R2".

Add before "Cleanup temporary credentials":

```yaml
      - name: Upload dry-run artifacts
        if: ${{ env.DRY_RUN == 'true' }}
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: release-dry-run-${{ env.VERSION }}
          path: |
            build/*.dmg
            build/*.zip
            build/appcast.xml
```

(Verify the pinned SHA matches the upstream `v7.0.1` tag via `gh api repos/actions/upload-artifact/git/ref/tags/v7.0.1` before committing; same for the cache action below.)

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add full-chain dry-run rehearsal mode to the release workflow (Issue #279)"
```

### Task C2: SwiftPM cache in both workflows

**Files:**
- Modify: `.github/workflows/release.yml`, `.github/workflows/ci.yml` (after each Checkout step)

- [ ] **Step 1: Add to both workflows** (release.yml: after "Set temporary paths"; ci.yml: after "Checkout"):

```yaml
      - name: Capture toolchain cache key
        run: echo "TOOLCHAIN_KEY=$(swift --version 2>/dev/null | head -1 | shasum -a 256 | cut -c1-12)" >> "$GITHUB_ENV"

      - name: Cache SwiftPM build
        uses: actions/cache@27d5ce7f107fe9357f9df03efb73ab90386fccae # v5.0.5
        with:
          path: .build
          key: spm-${{ runner.os }}-${{ env.TOOLCHAIN_KEY }}-${{ hashFiles('Package.resolved') }}
          restore-keys: spm-${{ runner.os }}-${{ env.TOOLCHAIN_KEY }}-
```

- [ ] **Step 2: Docs + commit + PR**

Add a "Dry run" section to `docs/signing-and-release.md`: how to dispatch (empty `release_tag` = rehearse the dispatched ref; tag + `dry_run=true` = rehearse a tag), what it produces (workflow artifact `release-dry-run-<version>`), and that it never touches R2 or GitHub Releases.

```bash
git add .github/workflows/ci.yml .github/workflows/release.yml docs/signing-and-release.md
git commit -m "ci: cache SwiftPM build products keyed by toolchain and Package.resolved (Issue #279)"
git push -u origin release/dry-run-and-cache
gh pr create --title "Release dry-run rehearsal mode and SwiftPM caching (Issue #279)" --body "Implements Issue #279 per the spec §6, §8. Closes #279."
```

### Task C3: acceptance — run a real dry run

- [ ] After PR C merges, dispatch: `gh workflow run Release --field dry_run=true` (empty `release_tag`), watch with `gh run watch`, and confirm: rehearse-mode gate output, all build/sign/notarize steps green, `release-dry-run-0.4.1` artifact present, no R2/GitHub Release steps executed. Note: with no live feed yet, the rehearse gate hits the 404 path — it still hard-fails without `WINK_ALLOW_FIRST_RELEASE`; set the repo variable for the rehearsal window if the feed is still absent, or accept the documented failure as proof the gate works and validate the rest via a re-run with the variable set.

---

## Self-review notes

- Spec §1–§8 each map to a task: §1→A1+A3, §2→A2+A4, §3→A3, §4→B3, §5→B1+B2+B4, §6→C1, §7→B4, §8→C2. Error-table rows are covered by A1's bats matrix plus A2's hard-fail rehearsal.
- The forward reference from A1's error message to `scripts/bump-version.sh` (ships in PR B) is deliberate and harmless.
- `RELEASE_TAG_OR_PLANNED` (C1) only matters for the Sparkle notes URL introduced in B4; when implementing C1, update that one usage.
