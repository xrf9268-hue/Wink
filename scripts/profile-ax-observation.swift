// Measures the exact synchronous AX sequence ApplicationObservation performs
// per window observation (issue #321): one kAXWindows read, one kAXMinimized
// read per window, plus kAXFocusedWindow and kAXMainWindow.
//
// Build and run (requires Accessibility permission for the invoking process):
//   swiftc -O scripts/profile-ax-observation.swift -o /tmp/profile-ax-observation \
//       -framework ApplicationServices -framework AppKit
//   /tmp/profile-ax-observation <bundle-id> [iterations] [ax-timeout-seconds]
//
// Prints per-iteration duration plus p50/p95/max so results can be compared
// against ApplicationObservation.observationLatencyBudget.

import AppKit
import ApplicationServices
import Foundation

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("error: this process is not Accessibility-trusted\n".utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: profile-ax-observation <bundle-id> [iterations] [ax-timeout-seconds]\n".utf8))
    exit(2)
}

let bundleID = arguments[1]
let iterations = arguments.count >= 3 ? max(Int(arguments[2]) ?? 30, 1) : 30
let axTimeout: Float = arguments.count >= 4 ? Float(arguments[3]) ?? 0 : 0

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    FileHandle.standardError.write(Data("error: no running application for \(bundleID)\n".utf8))
    exit(2)
}

struct ObservationSample {
    let duration: TimeInterval
    let windowCount: Int
    let visibleWindowCount: Int
    let windowsReadSucceeded: Bool
}

func captureObservation(pid: pid_t) -> ObservationSample {
    let start = CFAbsoluteTimeGetCurrent()
    let axApp = AXUIElementCreateApplication(pid)
    if axTimeout > 0 {
        AXUIElementSetMessagingTimeout(axApp, axTimeout)
    }

    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
    let windows = result == .success ? windowsRef as? [AXUIElement] : nil
    var visibleWindowCount = 0
    for window in windows ?? [] {
        var minimizedRef: CFTypeRef?
        let minimizedResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
        let isMinimized = minimizedResult == .success && (minimizedRef as? Bool ?? false)
        if !isMinimized {
            visibleWindowCount += 1
        }
    }

    var focusedRef: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef)
    var mainRef: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainRef)

    return ObservationSample(
        duration: CFAbsoluteTimeGetCurrent() - start,
        windowCount: windows?.count ?? 0,
        visibleWindowCount: visibleWindowCount,
        windowsReadSucceeded: result == .success
    )
}

// Warm-up pass excluded from statistics.
_ = captureObservation(pid: app.processIdentifier)

var samples: [ObservationSample] = []
for _ in 0..<iterations {
    samples.append(captureObservation(pid: app.processIdentifier))
}

let durationsMs = samples.map { $0.duration * 1_000 }.sorted()
func percentile(_ p: Double) -> Double {
    let rank = Int((Double(durationsMs.count - 1) * p).rounded())
    return durationsMs[rank]
}

let last = samples[samples.count - 1]
print("target=\(bundleID) pid=\(app.processIdentifier) iterations=\(iterations)")
print("windows=\(last.windowCount) visible=\(last.visibleWindowCount) windowsReadSucceeded=\(last.windowsReadSucceeded)")
print(String(
    format: "p50=%.3fms p95=%.3fms max=%.3fms min=%.3fms",
    percentile(0.5), percentile(0.95), durationsMs.last ?? 0, durationsMs.first ?? 0
))
