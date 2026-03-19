# Clone Scope

## Product target
Recreate the core behavior described in the recovered HotApp article:
- menu bar utility
- no Dock icon baseline
- app-to-shortcut bindings
- activate target app on shortcut
- toggle away when target app is already frontmost
- persistent local shortcut store

## MVP scope
1. App shell and entry point
2. Menu bar item and settings window shell
3. Shortcut model and persistence layer
4. App binding CRUD surface
5. Activation/toggle service with public APIs
6. Placeholder event handling layer for later CGEvent integration

## Deferred after MVP
- Hyper Key reliability work
- private SkyLight activation path
- advanced conflict detection
- running-app indicators
- deep UX polish

## Current implementation strategy
Build the public-API baseline first so the repo is coherent and pushable. Then iterate toward fuller HotApp parity.
