# Roadmap

## Phase 0 — Completed scaffold
Status: **done**

Delivered:
- repo initialized and pushed
- menu bar app baseline
- settings window
- persistent shortcut storage
- recorder-style shortcut input
- global event tap baseline
- accessibility permission flow
- conflict detection
- initial Thor-like toggle behavior
- packaging scaffold and validation docs

## Phase 1 — macOS validation and runtime reliability
Status: **done** (CI passes; real device end-to-end validation still pending)

Delivered:
- Swift 6 strict concurrency compile errors fixed (#21)
- EventTap memory leak and silent failure fixed (#22)
- Permission model aligned with Input Monitoring APIs (#23)
- EventTap lifecycle hardened with auto-recovery (#25, #26)
- O(1) precompiled trigger index replacing linear scans (#27)
- Shortcut monitoring recovery after permission changes without relaunch (#28)
- MainActor coupling reduced; Sendable conformances added (#32)
- Comprehensive tests for key mapping, conflicts, and lifecycle (#30)
- GitHub Actions CI for macOS build validation (#39)
- AppKit-first architecture decision documented (#24)

Remaining:
- End-to-end validation on a real macOS device (shortcut capture, toggle, permissions)

## Phase 2 — Recorder and settings polish
Status: **done**

Delivered:
- Shortcut recorder UX polished, unsupported-key handling improved (#37)
- Hyper Key UI support with symbol display and badge (#36)
- Hyper-style shortcut validation and edge cases (#33)
- SettingsView refactored into tabbed layout: Shortcuts / General / Insights (#45)
- Toggle semantics improved for hidden and minimized apps (#34)

## Phase 3 — Thor/HotApp parity improvements
Status: **substantially done**

Delivered:
- Toggle behavior: activate → restore previous app → hide fallback (#34)
- Hyper-style combination support validated (#33, #36)
- UsageTracker service with SQLite daily aggregation (#44)
- Insights tab with trend chart and app ranking (#47)
- Inline usage stats in Shortcuts tab (#46)

Remaining:
- Per-shortcut history stacks (single global previous-app memory is current approach)
- Stale-app detection and running-app indicators
- Private low-latency SkyLight activation path (intentionally deferred)

## Phase 4 — Packaging and release hardening
Status: **done**

Delivered:
- Automated `.app` packaging end to end (#38)
- Launch-at-login via SMAppService (#31)
- App icon and polished bundle metadata (#48)
- Signing and notarization workflow documented (#49)
- GitHub Actions CI baseline (#39)
- Product renamed to Quickey (#50, #51)

Remaining:
- Signed/notarized distributable build (requires Developer ID cert)

## Phase 5 — Quality and maintenance
Status: **in progress**

Delivered:
- Key mapping, conflict, and lifecycle tests (#30)
- Architecture and runtime state model documentation (#24, #29)

Remaining:
- Real macOS device validation and fixes
- Docs aligned with implementation (ongoing)
- Screenshots / demo material
