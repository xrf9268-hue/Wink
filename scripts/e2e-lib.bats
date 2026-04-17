#!/usr/bin/env bats

@test "detect_capture_requirement returns standard for standard-only shortcuts" {
  local shortcuts="$BATS_TEST_TMPDIR/shortcuts.json"
  cat >"$shortcuts" <<'JSON'
[
  {
    "appName": "Safari",
    "bundleIdentifier": "com.apple.Safari",
    "id": "11111111-1111-1111-1111-111111111111",
    "isEnabled": true,
    "keyEquivalent": "s",
    "modifierFlags": ["command", "shift"]
  }
]
JSON

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; detect_capture_requirement '$shortcuts' 1"

  local result="${output##*$'\n'}"
  [ "$status" -eq 0 ]
  [ "$result" = "standard" ]
}

@test "detect_capture_requirement returns mixed when hyper and standard shortcuts are both enabled" {
  local shortcuts="$BATS_TEST_TMPDIR/shortcuts.json"
  cat >"$shortcuts" <<'JSON'
[
  {
    "appName": "Safari",
    "bundleIdentifier": "com.apple.Safari",
    "id": "11111111-1111-1111-1111-111111111111",
    "isEnabled": true,
    "keyEquivalent": "s",
    "modifierFlags": ["command", "shift"]
  },
  {
    "appName": "IINA",
    "bundleIdentifier": "com.colliderli.iina",
    "id": "22222222-2222-2222-2222-222222222222",
    "isEnabled": true,
    "keyEquivalent": "a",
    "modifierFlags": ["command", "option", "control", "shift"]
  }
]
JSON

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; detect_capture_requirement '$shortcuts' 1"

  local result="${output##*$'\n'}"
  [ "$status" -eq 0 ]
  [ "$result" = "mixed" ]
}

@test "detect_capture_requirement treats Hyper modifier supersets as hyper" {
  local shortcuts="$BATS_TEST_TMPDIR/shortcuts.json"
  cat >"$shortcuts" <<'JSON'
[
  {
    "appName": "Preview",
    "bundleIdentifier": "com.apple.Preview",
    "id": "33333333-3333-3333-3333-333333333333",
    "isEnabled": true,
    "keyEquivalent": "f1",
    "modifierFlags": ["command", "option", "control", "shift", "function"]
  }
]
JSON

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; detect_capture_requirement '$shortcuts' 1"

  local result="${output##*$'\n'}"
  [ "$status" -eq 0 ]
  [ "$result" = "hyper" ]
}

@test "capture_requirement_satisfied accepts standard readiness without event tap" {
  local log_file="$BATS_TEST_TMPDIR/debug.log"
  cat >"$log_file" <<'LOG'
2026-04-09T04:24:42Z Quickey starting, version 0.2.0
2026-04-09T04:24:42Z attemptStart: shortcuts=1 triggerIndex=1 carbon=true eventTap=false
2026-04-09T04:24:45Z checkPermission: ax=true im=true carbon=true eventTap=false
LOG

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; capture_requirement_satisfied standard '$log_file'"

  [ "$status" -eq 0 ]
}

@test "capture_requirement_satisfied requires both transports for mixed mode" {
  local log_file="$BATS_TEST_TMPDIR/debug.log"
  cat >"$log_file" <<'LOG'
2026-04-09T04:24:42Z Quickey starting, version 0.2.0
2026-04-09T04:24:42Z attemptStart: shortcuts=2 triggerIndex=2 carbon=true eventTap=false
2026-04-09T04:24:45Z checkPermission: ax=true im=true carbon=true eventTap=false
LOG

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; capture_requirement_satisfied mixed '$log_file'"

  [ "$status" -eq 1 ]
}

@test "bundle_has_configured_shortcut matches a configured standard shortcut" {
  local shortcuts="$BATS_TEST_TMPDIR/shortcuts.json"
  cat >"$shortcuts" <<'JSON'
[
  {
    "appName": "Safari",
    "bundleIdentifier": "com.apple.Safari",
    "id": "11111111-1111-1111-1111-111111111111",
    "isEnabled": true,
    "keyEquivalent": "s",
    "modifierFlags": ["command", "shift"]
  }
]
JSON

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; bundle_has_configured_shortcut 'com.apple.Safari' standard '$shortcuts' 1"

  [ "$status" -eq 0 ]
}

@test "bundle_has_configured_shortcut rejects a missing hyper shortcut" {
  local shortcuts="$BATS_TEST_TMPDIR/shortcuts.json"
  cat >"$shortcuts" <<'JSON'
[
  {
    "appName": "Safari",
    "bundleIdentifier": "com.apple.Safari",
    "id": "11111111-1111-1111-1111-111111111111",
    "isEnabled": true,
    "keyEquivalent": "s",
    "modifierFlags": ["command", "shift"]
  }
]
JSON

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; bundle_has_configured_shortcut 'com.colliderli.iina' hyper '$shortcuts' 1"

  [ "$status" -eq 1 ]
}

@test "bundle_has_configured_shortcut matches a Hyper modifier superset" {
  local shortcuts="$BATS_TEST_TMPDIR/shortcuts.json"
  cat >"$shortcuts" <<'JSON'
[
  {
    "appName": "Preview",
    "bundleIdentifier": "com.apple.Preview",
    "id": "33333333-3333-3333-3333-333333333333",
    "isEnabled": true,
    "keyEquivalent": "f1",
    "modifierFlags": ["command", "option", "control", "shift", "function"]
  }
]
JSON

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; bundle_has_configured_shortcut 'com.apple.Preview' hyper '$shortcuts' 1"

  [ "$status" -eq 0 ]
}

@test "resolve_primary_test_shortcut prefers a configured standard shortcut" {
  local shortcuts="$BATS_TEST_TMPDIR/shortcuts.json"
  cat >"$shortcuts" <<'JSON'
[
  {
    "appName": "Safari",
    "bundleIdentifier": "com.apple.Safari",
    "id": "11111111-1111-1111-1111-111111111111",
    "isEnabled": true,
    "keyEquivalent": "s",
    "modifierFlags": ["command", "shift"]
  },
  {
    "appName": "IINA",
    "bundleIdentifier": "com.colliderli.iina",
    "id": "22222222-2222-2222-2222-222222222222",
    "isEnabled": true,
    "keyEquivalent": "m",
    "modifierFlags": ["command", "option", "control", "shift"]
  }
]
JSON

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; resolve_primary_test_shortcut '$shortcuts' 1"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"bundleIdentifier":"com.apple.Safari"'* ]]
  [[ "$output" == *'"route":"standard"'* ]]
  [[ "$output" == *'"keyCode":1'* ]]
}

@test "resolve_primary_test_shortcut falls back to hyper when no standard shortcut exists" {
  local shortcuts="$BATS_TEST_TMPDIR/shortcuts.json"
  cat >"$shortcuts" <<'JSON'
[
  {
    "appName": "Antigravity",
    "bundleIdentifier": "com.google.antigravity",
    "id": "11111111-1111-1111-1111-111111111111",
    "isEnabled": true,
    "keyEquivalent": "a",
    "modifierFlags": ["command", "option", "control", "shift"]
  }
]
JSON

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; resolve_primary_test_shortcut '$shortcuts' 1"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"bundleIdentifier":"com.google.antigravity"'* ]]
  [[ "$output" == *'"route":"hyper"'* ]]
  [[ "$output" == *'"keyCode":0'* ]]
}

@test "shortcut_inventory_json marks Hyper modifier supersets as hyper" {
  local shortcuts="$BATS_TEST_TMPDIR/shortcuts.json"
  cat >"$shortcuts" <<'JSON'
[
  {
    "appName": "Preview",
    "bundleIdentifier": "com.apple.Preview",
    "id": "33333333-3333-3333-3333-333333333333",
    "isEnabled": true,
    "keyEquivalent": "f1",
    "modifierFlags": ["command", "option", "control", "shift", "function"]
  }
]
JSON

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; shortcut_inventory_json '$shortcuts' 1"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"bundleIdentifier":"com.apple.Preview"'* ]]
  [[ "$output" == *'"route":"hyper"'* ]]
  [[ "$output" == *'"keyCode":122'* ]]
}

@test "resolve_isolation_shortcuts returns two distinct shortcuts for a hyper-only fixture" {
  local shortcuts="$BATS_TEST_TMPDIR/shortcuts.json"
  cat >"$shortcuts" <<'JSON'
[
  {
    "appName": "Antigravity",
    "bundleIdentifier": "com.google.antigravity",
    "id": "11111111-1111-1111-1111-111111111111",
    "isEnabled": true,
    "keyEquivalent": "a",
    "modifierFlags": ["command", "option", "control", "shift"]
  },
  {
    "appName": "Google Chrome",
    "bundleIdentifier": "com.google.Chrome",
    "id": "22222222-2222-2222-2222-222222222222",
    "isEnabled": true,
    "keyEquivalent": "b",
    "modifierFlags": ["command", "option", "control", "shift"]
  }
]
JSON

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; resolve_isolation_shortcuts '$shortcuts' 1"

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c '"bundleIdentifier"')" -eq 2 ]
  [[ "$output" == *'"bundleIdentifier":"com.google.antigravity"'* ]]
  [[ "$output" == *'"bundleIdentifier":"com.google.Chrome"'* ]]
}
