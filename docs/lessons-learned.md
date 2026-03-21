# Quickey Troubleshooting Guidance

## CGEvent Tap Permissions

**Issue**
`AXIsProcessTrusted()` can return true while `CGEvent.tapCreate()` still fails.

**Cause**
On macOS 15, a working event tap requires both Accessibility and Input Monitoring. Either permission alone is not enough.

**Practical guidance**
Check both `AXIsProcessTrusted()` and `CGPreflightListenEventAccess()` as prerequisites, but treat shortcut capture as ready only after the active event tap starts successfully. When validating on a clean machine, request and confirm both permissions, then verify the tap startup path.

## Ad-hoc Signing and TCC

**Issue**
Permissions appear enabled in System Settings, but Quickey is still not trusted after a rebuild.

**Cause**
TCC binds permissions to the app's code signature. Ad-hoc signatures change between builds, so a new binary no longer matches the old TCC record.

**Practical guidance**
After rebuilding locally, reset and regrant permissions if the app stops matching its previous TCC state:

```bash
tccutil reset Accessibility com.quickey.app
tccutil reset ListenEvent com.quickey.app
```

For long-lived releases, use a stable Developer ID signature.

## Launch Via `open`

**Issue**
Launching the app binary directly can produce different permission behavior than launching the app bundle.

**Cause**
TCC and app identity matching are tied to the bundle launch path. Directly running `./Quickey.app/Contents/MacOS/Quickey` can bypass the launch context used during permission registration.

**Practical guidance**
Validate permission-sensitive behavior by starting the app with `open Quickey.app`, not by executing the binary directly.

## File-Based Diagnostics

**Issue**
`log stream` and `log show` may not expose the diagnostics needed during local debugging.

**Cause**
Unified logging is filtered and can hide the messages you expect to see.

**Practical guidance**
Use a file-backed log for troubleshooting, such as `~/.config/Quickey/debug.log`. Create the parent directory first, then append short diagnostic lines there.

## `@Sendable` Completion Handlers

**Issue**
`NSWorkspace.openApplication` can crash or assert when its completion handler touches main-actor state.

**Cause**
The completion callback may arrive on a background queue, while captured values from `@MainActor` context remain isolated unless they are extracted safely.

**Practical guidance**
Copy any needed values before the call, and mark the completion handler `@Sendable`. Keep the closure free of implicit main-actor assumptions.

## SkyLight Activation

**Issue**
`NSRunningApplication.activate()` is unreliable for bringing an LSUIElement app to the foreground on macOS 14+.

**Cause**
The cooperative activation path can report success without actually activating the app.

**Practical guidance**
Use the SkyLight-based activation path when Quickey must reliably front the target app. Treat it as the validated route for LSUIElement activation behavior.
