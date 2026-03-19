# Next Phase Plan

## Goal
Move HotApp Clone from a credible implementation scaffold to a macOS-validated, daily-usable utility.

## Phase A — macOS compile and runtime validation
1. Build with `swift build`
2. Run tests with `swift test`
3. Build release binary
4. Create `.app` with `scripts/package-app.sh`
5. Validate LSUIElement behavior, menu bar presence, and Accessibility flow
6. Verify one real shortcut end-to-end

## Phase B — shortcut recorder polish
1. Replace the basic recorder field with a more polished capture control
2. Handle unsupported keys and modifier-only presses more gracefully
3. Improve display formatting for symbols and special keys
4. Add inline guidance for permission state and recording state

## Phase C — HotApp/Thor parity improvements
1. Better previous-app restoration heuristics
2. Per-shortcut history instead of a single global previous app
3. Improve handling for minimized/full-screen/multi-window apps
4. Add stale-app detection and clearer invalid-target handling
5. Explore optional private SkyLight activation path behind an explicit feature flag

## Phase D — packaging and release hardening
1. Stable bundle metadata and app icon
2. Signing and notarization plan
3. Release packaging script that copies the executable automatically
4. Versioning and changelog baseline

## Phase E — developer ergonomics
1. Add more tests for key matching and conflict detection
2. Add sample data / preview states for settings UI
3. Improve README with screenshots after macOS validation
4. Consider CI from a macOS runner
