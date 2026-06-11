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

@test "rejects non-integer CFBundleVersion without modifying the plist" {
  /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 5.1' "$PLIST"
  run_bump 0.5.0
  [ "$status" -ne 0 ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "0.4.1" ]
}
