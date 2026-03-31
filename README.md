# Quickey

Quickey is a macOS menu bar app that binds global shortcuts to target apps, with Thor-like toggle behavior, fast activation, and lightweight usage insights.

## Highlights
- Global shortcuts that launch or toggle target apps with a single keystroke
- Thor-like semantics that restore, activate, or hide apps depending on state
- Accurate shortcut readiness that reflects both permissions and live event-tap health
- Supports letters, modifiers, Hyper Key, F-keys, arrows, and space
- Launch at login support with system approval surfaced in the app
- Insights view for recent usage trends and app ranking
- Swift 6, AppKit-first, and SPM-first by design

## Requirements and Constraints
- macOS 15+
- Swift 6 / SPM-first
- macOS runtime behavior must be validated on macOS
- SkyLight is a private API dependency for activation reliability

## Build and Run
```bash
swift build
swift test
./scripts/package-app.sh        # release build + .app bundle
./scripts/e2e-full-test.sh      # end-to-end test suite (requires Accessibility + Input Monitoring)
```

## Loop Job

Run automated Claude Code sessions to process issues and PRs:

```
/loop 30m Follow the instructions in docs/loop-prompt.md
```

Each iteration uses `/code-review` ([code-review plugin](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/code-review)), `/codex:review` ([Codex Plugin CC](https://github.com/openai/codex-plugin-cc)), and bot reviews for code quality gates. See [`docs/loop-job-guide.md`](./docs/loop-job-guide.md) for details.

## Documentation
- [`docs/README.md`](./docs/README.md)
- [`docs/architecture.md`](./docs/architecture.md)
- [`docs/signing-and-release.md`](./docs/signing-and-release.md)

## Project Status
Quickey is feature-complete. Broad macOS validation has landed, targeted revalidation for the 2026-03-21 remediation set is still pending, and a signed and notarized release is still pending.
