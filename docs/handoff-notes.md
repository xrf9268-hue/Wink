# Handoff Notes

## Current state
Quickey has progressed from a prototype scaffold to a feature-complete application. All originally planned Tier 0–5 issues have been resolved. Additional features shipped beyond the original scope include UsageTracker and the Insights tab.

### What is in place
- SPM-only Swift 6 project structure
- Menu bar app (AppKit-first, selective SwiftUI — architecture decision documented in `docs/plans/app-structure-direction.md`)
- Tabbed settings window: Shortcuts, General, Insights
- Persistent shortcut storage + SQLite usage tracking
- Global key capture via CGEvent tap (Input Monitoring permission)
- O(1) precompiled trigger index for hot-path matching
- EventTap lifecycle hardened: auto-recovery on disable/timeout
- Permission flow: recovers monitoring after permission changes without relaunch
- Hyper Key support with symbol display
- Toggle semantics: activate → restore previous app → hide fallback
- Launch-at-login via SMAppService
- Automated `.app` packaging script
- GitHub Actions CI for macOS build validation
- Signing and release workflow documented in `docs/signing-and-release.md`
- Product renamed from HotAppClone to Quickey throughout

### What remains unresolved
- **Real macOS device validation**: CI compiles cleanly, but end-to-end shortcut capture, toggle behavior, and permission UX still require hands-on macOS verification
- **Signed/notarized distributable**: workflow is documented in `docs/signing-and-release.md`; a Developer ID certificate is required to execute it
- **Private SkyLight activation path**: intentionally deferred, out of scope for now
- **Toggle edge cases**: fullscreen / multi-window / multi-display behavior needs real device confirmation

## Immediate next actions
1. Run `docs/macos-validation-checklist.md` on a real macOS 14+ machine
2. Fix any compile or runtime issues discovered on the device
3. Produce a signed/notarized `.app` once a Developer ID cert is available

## If continuing implementation
Prefer work in this order:
1. Real macOS device validation
2. Signed distributable build
3. New feature work or UX improvements
4. Additional test coverage for toggle edge cases
