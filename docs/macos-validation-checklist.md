# macOS Validation Checklist

## Build validation
- [ ] `swift build`
- [ ] `swift test`
- [ ] `swift build -c release`

## App bundle validation
- [ ] Run `./scripts/package-app.sh`
- [ ] Copy release binary into `build/HotAppClone.app/Contents/MacOS/HotAppClone`
- [ ] Confirm `Info.plist` contains `LSUIElement=1`
- [ ] Launch the app bundle successfully
- [ ] Confirm no Dock icon appears
- [ ] Confirm menu bar item appears

## Permissions validation
- [ ] Accessibility prompt appears or can be granted manually
- [ ] Settings view reflects granted permission after refresh

## Core behavior validation
- [ ] Add one shortcut for a target app
- [ ] Trigger shortcut and bring app frontmost
- [ ] Trigger the same shortcut again and restore the previous app when possible
- [ ] Validate hide fallback when no previous app is restorable
- [ ] Validate at least one Hyper-style modifier combination
- [ ] Validate duplicate shortcut conflict warning

## Packaging follow-up
- [ ] Stable bundle identifier preserved across rebuilds
- [ ] Repeated rebuilds do not create confusing permission churn
- [ ] Optional signing/notarization plan documented
