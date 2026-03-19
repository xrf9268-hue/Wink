# Handoff Notes

## What is already implemented
- SPM-only Swift project structure
- Menu bar app baseline
- Settings window with app selection
- Recorder-style shortcut capture UI
- Persistent shortcut storage
- Event tap baseline
- Accessibility permission flow
- Shortcut conflict detection
- Best-effort Thor-like toggle behavior
- Packaging scaffold and validation docs

## What has NOT been validated yet
- Compilation on a real macOS Swift toolchain
- End-to-end global shortcut capture in a running app bundle
- Previous-app restore edge cases
- Hyper-style modifier combinations in practice
- App bundle signing/notarization

## Important context
- This project was scaffolded from Linux, so structure and code paths were designed for macOS but not compiled in place here.
- The recovered HotApp article was only partially available, so some behavior is inferred from Thor and the visible excerpt.
- The safest current activation path uses public APIs; private SkyLight acceleration is intentionally deferred.

## Recommended immediate next action
Use a macOS machine to run the checklist in `docs/macos-validation-checklist.md` and fix compile/runtime gaps before adding more features.
