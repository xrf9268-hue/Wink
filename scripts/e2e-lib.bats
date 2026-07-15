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

@test "standard_function_modifier_observer_required distinguishes Fn F-row from Fn letter" {
  local fn_f_shortcuts="$BATS_TEST_TMPDIR/fn-f-shortcuts.json"
  local fn_letter_shortcuts="$BATS_TEST_TMPDIR/fn-letter-shortcuts.json"
  cat >"$fn_f_shortcuts" <<'JSON'
[
  {
    "appName": "Clock",
    "bundleIdentifier": "com.apple.clock",
    "isEnabled": true,
    "keyEquivalent": "f6",
    "modifierFlags": ["function"]
  }
]
JSON
  cat >"$fn_letter_shortcuts" <<'JSON'
[
  {
    "appName": "Safari",
    "bundleIdentifier": "com.apple.Safari",
    "isEnabled": true,
    "keyEquivalent": "a",
    "modifierFlags": ["function"]
  }
]
JSON

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; standard_function_modifier_observer_required '$fn_f_shortcuts' 0"
  [ "$status" -eq 0 ]

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; standard_function_modifier_observer_required '$fn_letter_shortcuts' 0"
  [ "$status" -eq 1 ]
}

@test "standard readiness requires the Fn observer for a configured Fn F-row binding" {
  local shortcuts="$BATS_TEST_TMPDIR/shortcuts.json"
  local log_file="$BATS_TEST_TMPDIR/debug.log"
  cat >"$shortcuts" <<'JSON'
[
  {
    "appName": "Clock",
    "bundleIdentifier": "com.apple.clock",
    "isEnabled": true,
    "keyEquivalent": "f6",
    "modifierFlags": ["function"]
  }
]
JSON
  cat >"$log_file" <<'LOG'
2026-04-09T04:24:42Z Wink starting, version 0.2.0
2026-04-09T04:24:42Z attemptStart: shortcuts=1 triggerIndex=1 carbon=true eventTap=false
LOG

  run bash -lc "export E2E_SHORTCUTS_FILE='$shortcuts'; source '$BATS_TEST_DIRNAME/e2e-lib.sh'; capture_requirement_satisfied standard '$log_file'"
  [ "$status" -eq 1 ]

  printf '%s\n' '2026-04-09T04:24:43Z CARBON_FUNCTION_MODIFIER_TAP_STARTED' >>"$log_file"
  run bash -lc "export E2E_SHORTCUTS_FILE='$shortcuts'; source '$BATS_TEST_DIRNAME/e2e-lib.sh'; capture_requirement_satisfied standard '$log_file'"
  [ "$status" -eq 0 ]

  printf '%s\n' '2026-04-09T04:24:44Z CARBON_FUNCTION_MODIFIER_TAP_STOPPED' >>"$log_file"
  run bash -lc "export E2E_SHORTCUTS_FILE='$shortcuts'; source '$BATS_TEST_DIRNAME/e2e-lib.sh'; capture_requirement_satisfied standard '$log_file'"
  [ "$status" -eq 1 ]

  printf '%s\n' '2026-04-09T04:24:45Z CARBON_FUNCTION_MODIFIER_TAP_STARTED' >>"$log_file"
  printf '%s\n' '2026-04-09T04:24:46Z CARBON_FUNCTION_MODIFIER_TAP_DISABLED reason=4294967295 active=false' >>"$log_file"
  run bash -lc "export E2E_SHORTCUTS_FILE='$shortcuts'; source '$BATS_TEST_DIRNAME/e2e-lib.sh'; capture_requirement_satisfied standard '$log_file'"
  [ "$status" -eq 1 ]

  printf '%s\n' '2026-04-09T04:24:47Z CARBON_FUNCTION_MODIFIER_TAP_DISABLED reason=4294967295 active=true' >>"$log_file"
  run bash -lc "export E2E_SHORTCUTS_FILE='$shortcuts'; source '$BATS_TEST_DIRNAME/e2e-lib.sh'; capture_requirement_satisfied standard '$log_file'"
  [ "$status" -eq 0 ]
}

@test "capture_requirement_satisfied accepts standard readiness without event tap" {
  local log_file="$BATS_TEST_TMPDIR/debug.log"
  cat >"$log_file" <<'LOG'
2026-04-09T04:24:42Z Wink starting, version 0.2.0
2026-04-09T04:24:42Z attemptStart: shortcuts=1 triggerIndex=1 carbon=true eventTap=false
2026-04-09T04:24:45Z checkPermission: ax=true im=true carbon=true eventTap=false
LOG

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; capture_requirement_satisfied standard '$log_file'"

  [ "$status" -eq 0 ]
}

@test "capture_requirement_satisfied requires both transports for mixed mode" {
  local log_file="$BATS_TEST_TMPDIR/debug.log"
  cat >"$log_file" <<'LOG'
2026-04-09T04:24:42Z Wink starting, version 0.2.0
2026-04-09T04:24:42Z attemptStart: shortcuts=2 triggerIndex=2 carbon=true eventTap=false
2026-04-09T04:24:45Z checkPermission: ax=true im=true carbon=true eventTap=false
LOG

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; capture_requirement_satisfied mixed '$log_file'"

  [ "$status" -eq 1 ]
}

@test "capture_requirement_satisfied accepts generic startup marker for none mode" {
  local log_file="$BATS_TEST_TMPDIR/debug.log"
  cat >"$log_file" <<'LOG'
2026-04-09T04:24:42Z Wink starting, version 0.2.0
LOG

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; capture_requirement_satisfied none '$log_file'"

  [ "$status" -eq 0 ]
}

@test "e2e_launch_app creates the log parent directory before truncating" {
  local app_dir="$BATS_TEST_TMPDIR/Wink.app"
  local log_file="$BATS_TEST_TMPDIR/fresh/config/Wink/debug.log"
  mkdir -p "$app_dir"

  run bash -lc "
    export E2E_APP_PATH='$app_dir'
    export E2E_LOG_FILE='$log_file'
    source '$BATS_TEST_DIRNAME/e2e-lib.sh'
    pkill() { :; }
    open() { :; }
    detect_capture_requirement() { echo none; }
    wait_for_capture_requirement() { return 0; }
    hyper_key_enabled_flag() { echo 0; }
    e2e_launch_app
    test -d \"\$(dirname \"\$LOG_FILE\")\"
    test -f \"\$LOG_FILE\"
  "

  [ "$status" -eq 0 ]
}

@test "e2e_launch_app suppresses automatic permission prompts for validation launches" {
  local app_dir="$BATS_TEST_TMPDIR/Wink.app"
  local log_file="$BATS_TEST_TMPDIR/debug.log"
  mkdir -p "$app_dir"

  run bash -lc "
    export E2E_APP_PATH='$app_dir'
    export E2E_LOG_FILE='$log_file'
    source '$BATS_TEST_DIRNAME/e2e-lib.sh'
    pkill() { :; }
    open() { printf '%s\n' \"\$*\"; }
    detect_capture_requirement() { echo none; }
    wait_for_capture_requirement() { return 0; }
    hyper_key_enabled_flag() { echo 0; }
    e2e_launch_app
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"-a $app_dir --args --suppress-automatic-permission-prompts"* ]]
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

@test "resolve_primary_test_shortcut skips Fn standard bindings that AppleScript cannot send" {
  local shortcuts="$BATS_TEST_TMPDIR/shortcuts.json"
  cat >"$shortcuts" <<'JSON'
[
  {
    "appName": "Clock",
    "bundleIdentifier": "com.apple.clock",
    "isEnabled": true,
    "keyEquivalent": "f6",
    "modifierFlags": ["function"]
  },
  {
    "appName": "Safari",
    "bundleIdentifier": "com.apple.Safari",
    "isEnabled": true,
    "keyEquivalent": "s",
    "modifierFlags": ["command", "shift"]
  }
]
JSON

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; resolve_primary_test_shortcut '$shortcuts' 0"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"bundleIdentifier":"com.apple.Safari"'* ]]
}

@test "send_standard_shortcut rejects Fn instead of emitting invalid AppleScript" {
  local shortcut='{"route":"standard","keyCode":97,"modifierFlags":["function"]}'

  run bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; send_standard_shortcut '$shortcut'"

  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot synthesize physical Fn"* ]]
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

@test "e2e defaults target Wink identity" {
  run env -u LC_ALL bash -lc "source '$BATS_TEST_DIRNAME/e2e-lib.sh'; printf '%s\n%s\n%s\n%s\n' \"\$APP_PATH\" \"\$LOG_FILE\" \"\$APP_BUNDLE_ID\" \"\$SHORTCUTS_FILE\""

  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"/build/Wink.app" ]]
  [[ "${lines[1]}" == *"/.config/Wink/debug.log" ]]
  [ "${lines[2]}" = "com.wink.app" ]
  [[ "${lines[3]}" == *"/Library/Application Support/Wink/shortcuts.json" ]]
}
