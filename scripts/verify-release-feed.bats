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

run_gate() { # args: env VAR=value pairs, then optional script args after --
  local env_pairs=()
  local script_args=()
  local seen_sep=""
  for arg in "$@"; do
    if [ "$arg" = "--" ]; then seen_sep=1; continue; fi
    if [ -n "$seen_sep" ]; then script_args+=("$arg"); else env_pairs+=("$arg"); fi
  done
  run env PATH="$SHIM_DIR:$PATH" \
    INFO_PLIST="$PLIST" \
    SPARKLE_PUBLIC_BASE_URL="https://example.invalid/wink" \
    SPARKLE_RESTORED_APPCAST="$RESTORED" \
    "${env_pairs[@]}" bash "$SCRIPT" "${script_args[@]}"
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
  run_gate FAKE_HTTP_CODE=200 FAKE_BODY_FILE="$(make_feed 5)" -- --mode rehearse
  [ "$status" -eq 0 ]
}

@test "rehearse mode still fails on fetch error" {
  run_gate FAKE_HTTP_CODE=500 -- --mode rehearse
  [ "$status" -ne 0 ]
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
  run_gate FAKE_HTTP_CODE=200 FAKE_BODY_FILE="$(make_feed 4)" -- --bogus
  [ "$status" -ne 0 ]
}

@test "rejects invalid mode value" {
  run_gate FAKE_HTTP_CODE=200 FAKE_BODY_FILE="$(make_feed 4)" -- --mode chaos
  [ "$status" -ne 0 ]
}
