# Architecture Decision: App Structure Direction

**Issue**: #18 — Decide app structure direction: SwiftUI scene-based vs deliberate AppKit-first
**Decision**: AppKit-first with selective SwiftUI enhancement
**Status**: Decided
**Date**: 2026-03-19

## Context

The app currently uses a hybrid architecture: AppKit manages the lifecycle, event tapping, status bar, and window management, while SwiftUI handles the settings UI via NSHostingController. Issue #18 asks whether to formalize this as the intended direction or migrate toward a SwiftUI scene-based structure.

## Decision

**Deliberately remain AppKit-first.** The current hybrid approach is correct for this app's requirements and should be documented as intentional, not accidental.

## Rationale

### Hard constraints that prevent pure SwiftUI

| Constraint | Why |
|-----------|-----|
| `.accessory` activation policy | Required for invisible background utility (no dock icon). Incompatible with SwiftUI `App` scene lifecycle. |
| `RecorderField` (NSTextField subclass) | Overrides `keyDown(with:)` for raw key capture. No SwiftUI equivalent exists. |
| `CGEvent.tapCreate` + CFRunLoop | System-level event tapping requires AppKit/CoreFoundation lifecycle. |
| `NSWorkspace` / `NSRunningApplication` | App launching and switching APIs have no SwiftUI abstraction. |

### Scene-based migration cost vs benefit

| Option | Effort | Benefit | Verdict |
|--------|--------|---------|---------|
| Keep AppKit-first (current) | 0% | Full functionality | **Chosen** |
| MenuBarExtra + .settings() scene | 60% | Convention compliance | Rejected — adds dock icon, loses background-utility behavior |
| Pure SwiftUI | Impossible | N/A | Blocked by RecorderField |

### What works well today

- Clean separation: AppKit handles system integration, SwiftUI handles settings UX
- AppController orchestrates service lifecycle with explicit `start()`/`stop()`
- SettingsView is already pure SwiftUI (except NSViewRepresentable for key recorder)
- Services layer (ShortcutStore, PersistenceService, KeyMatcher, etc.) is framework-agnostic

## Architecture Layers (formalized)

```
┌─────────────────────────────────────────────┐
│ Entry Point (AppKit)                        │
│   main.swift → NSApplication(.accessory)    │
│   AppDelegate → AppController               │
├─────────────────────────────────────────────┤
│ System Integration (AppKit/CoreFoundation)  │
│   EventTapManager (CFMachPort, CGEvent)     │
│   MenuBarController (NSStatusItem, NSMenu)  │
│   AppSwitcher (NSWorkspace, NSRunningApp)   │
│   AccessibilityPermissionService (IOKit)    │
├─────────────────────────────────────────────┤
│ UI Layer (SwiftUI + NSViewRepresentable)    │
│   SettingsWindowController (NSWindow host)  │
│   SettingsView (SwiftUI)                    │
│   ShortcutRecorderView (NSViewRepresentable)│
│   RecorderField (NSTextField subclass)      │
├─────────────────────────────────────────────┤
│ Services (Pure Swift, framework-agnostic)   │
│   ShortcutStore, ShortcutManager            │
│   PersistenceService, ShortcutValidator     │
│   KeyMatcher, KeySymbolMapper               │
│   FrontmostApplicationTracker               │
└─────────────────────────────────────────────┘
```

## Follow-up implications

This decision affects downstream issues:

- **#14 (launch-at-login)**: Use `SMAppService.mainApp` (ServiceManagement framework), not SwiftUI `.defaultAppStorage`. Works with AppKit-first.
- **#15 (bundle polish)**: Configure via Info.plist and build settings, not SwiftUI app manifest.
- **#20 (runtime state model)**: AppController remains the orchestrator. No need for `@EnvironmentObject` or SwiftUI state management at the app level.
- **#16/#17 (tap recovery)**: EventTapManager lifecycle stays in AppKit layer, managed by ShortcutManager/AppController.

## Guidelines for future development

1. **New UI**: Build in SwiftUI, host via NSHostingController when needed
2. **System APIs**: Use AppKit/CoreFoundation directly — do not wrap in SwiftUI abstractions
3. **Services**: Keep framework-agnostic (no UIKit/AppKit/SwiftUI imports)
4. **Window management**: Continue using SettingsWindowController pattern for any new windows
5. **Menu bar**: Keep NSStatusItem + NSMenu (no MenuBarExtra migration)
