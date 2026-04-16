# GitHub Automation

Quickey now uses repository-native GitHub Actions to keep issue closure, project state, and runtime-validation state aligned.

## What Is Automated

1. **PR metadata enforcement** (`.github/workflows/pr-metadata.yml`)
   - Every PR must include a closing keyword such as `Fixes #135`
   - Every PR must keep the `Validation Status` checklist and select exactly one option
   - If the PR touches runtime-sensitive files, `Not runtime-sensitive` is rejected automatically

2. **Project reconciliation** (`.github/workflows/project-sync.yml`)
   - Adds the event issue or linked issue into the `Quickey Backlog` Project V2 if it is missing
   - Scheduled and manual reconciliation runs backfill any repository issues that are still missing from `Quickey Backlog`
   - Syncs `Status` to `Ready`, `In Progress`, or `Done`
   - Syncs `Runtime Validation` to `None`, `macOS pending`, or `macOS complete`
   - Re-runs every 6 hours so transient event failures do not leave the project permanently stale

## Required Repository Setup

Store a repository secret named `PROJECT_AUTOMATION_TOKEN`.

Recommended scopes for the token:
- `repo`
- `project`
- `read:org`

`GITHUB_TOKEN` is enough for PR-body validation, but it is not sufficient for Quickey's Project V2 field updates. The project-sync workflow uses `PROJECT_AUTOMATION_TOKEN` for GraphQL mutations.

## Recommended Branch Protection

Mark `PR Metadata / Validate PR metadata` as a required status check on `main`.

That converts the `Fixes #...` and `Validation Status` requirements from convention into a merge gate.

## Runtime-Sensitive Detection

The current automation treats the following areas as runtime-sensitive:
- shortcut capture transport (`CarbonHotKeyProvider`, `EventTapCaptureProvider`, `ShortcutCaptureCoordinator`, `ShortcutManager`, `EventTapManager`)
- permissions and activation (`AccessibilityPermissionService`, `AppSwitcher`, `SkyLightBridge`, `ApplicationObservation`)
- launch and startup flow (`LaunchAtLoginService`, `AppController`, `AppDelegate`, `main.swift`)
- packaging/runtime scripts (`package-app.sh`, `package-dmg.sh`, `e2e-*`, `cgevent-helper.swift`)
- signing/runtime metadata (`entitlements.plist`, `Sources/Quickey/Resources/Info.plist`)

If Quickey grows new runtime-sensitive surfaces, update `.github/scripts/lib/project-automation.mjs` so the automation keeps matching reality.
