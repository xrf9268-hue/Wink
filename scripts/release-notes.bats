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

@test "last section runs to EOF" {
  run env CHANGELOG="$CL" bash "$SCRIPT" 0.4.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Older note"* ]]
  [[ "$output" != *"New thing"* ]]
}

@test "heading match is exact, not a regex-dot match" {
  cat >"$CL" <<'MD'
## 0x5x0

- Wrong section
MD
  run env CHANGELOG="$CL" bash "$SCRIPT" 0.5.0
  [ "$status" -ne 0 ]
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

@test "fails when CHANGELOG.md does not exist" {
  run env CHANGELOG="$BATS_TEST_TMPDIR/missing.md" bash "$SCRIPT" 0.5.0
  [ "$status" -ne 0 ]
}
