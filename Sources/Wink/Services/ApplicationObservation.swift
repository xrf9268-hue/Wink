import AppKit
import ApplicationServices
import os.signpost

/// Where in the toggle pipeline a synchronous AX window observation runs.
/// Labels the signpost intervals and slow-observation diagnostics so
/// pre-action cost can be separated from confirmation/recovery cost
/// (issue #321).
enum WindowObservationPhase: String, Sendable {
    case preAction
    case activationConfirmation
    case deactivationConfirmation
    case launchContinuation
    case launchConfirmation
    case snapshotFallback
}

/// Emitted when one AX window observation exceeds the main-actor latency
/// budget. The default sink writes an `AX_OBSERVATION_SLOW` line to the
/// diagnostic log.
struct SlowObservationReport: Sendable, Equatable {
    let phase: WindowObservationPhase
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let visibleWindowCount: Int
    let windowsReadSucceeded: Bool
    let duration: TimeInterval

    var logLine: String {
        let durationMs = String(format: "%.1f", duration * 1_000)
        let budgetMs = String(format: "%.0f", ApplicationObservation.observationLatencyBudget * 1_000)
        return "AX_OBSERVATION_SLOW phase=\(phase.rawValue) " +
            ActivationObservationSnapshot.quotedField("target", bundleIdentifier) +
            " pid=\(processIdentifier) visibleWindowCount=\(visibleWindowCount)" +
            " windowObservationSucceeded=\(windowsReadSucceeded)" +
            " durationMs=\(durationMs) budgetMs=\(budgetMs)"
    }
}

enum ApplicationClassification: String, Sendable {
    case regularWindowed
    case nonStandardWindowed
    case windowlessOrAccessory
    case systemUtility
}

struct ActivationObservationSnapshot: Sendable, Equatable {
    let targetBundleIdentifier: String?
    let observedFrontmostBundleIdentifier: String?
    let targetIsActive: Bool
    let targetIsHidden: Bool
    let visibleWindowCount: Int
    let hasFocusedWindow: Bool
    let hasMainWindow: Bool
    let windowObservationSucceeded: Bool
    let windowObservationFailureReason: String?
    let classification: ApplicationClassification
    let classificationReason: String
    let allowsWindowlessStableActivation: Bool

    init(
        targetBundleIdentifier: String?,
        observedFrontmostBundleIdentifier: String?,
        targetIsActive: Bool,
        targetIsHidden: Bool,
        visibleWindowCount: Int,
        hasFocusedWindow: Bool,
        hasMainWindow: Bool,
        windowObservationSucceeded: Bool,
        windowObservationFailureReason: String?,
        classification: ApplicationClassification,
        classificationReason: String,
        allowsWindowlessStableActivation: Bool = false
    ) {
        self.targetBundleIdentifier = targetBundleIdentifier
        self.observedFrontmostBundleIdentifier = observedFrontmostBundleIdentifier
        self.targetIsActive = targetIsActive
        self.targetIsHidden = targetIsHidden
        self.visibleWindowCount = visibleWindowCount
        self.hasFocusedWindow = hasFocusedWindow
        self.hasMainWindow = hasMainWindow
        self.windowObservationSucceeded = windowObservationSucceeded
        self.windowObservationFailureReason = windowObservationFailureReason
        self.classification = classification
        self.classificationReason = classificationReason
        self.allowsWindowlessStableActivation = allowsWindowlessStableActivation
    }

    var targetHasVisibleWindows: Bool {
        visibleWindowCount > 0
    }

    var targetIsObservedFrontmost: Bool {
        guard let targetBundleIdentifier else { return false }
        return targetBundleIdentifier == observedFrontmostBundleIdentifier
    }

    var isStableActivation: Bool {
        guard targetIsObservedFrontmost, targetIsActive, !targetIsHidden else {
            return false
        }

        if allowsWindowlessStableActivation {
            return true
        }

        return targetHasVisibleWindows || hasFocusedWindow || hasMainWindow
    }

    var structuredLogFields: String {
        structuredLogFields(stableOverride: nil)
    }

    func structuredLogFields(stableOverride: Bool?) -> String {
        [
            Self.quotedField("frontmost", observedFrontmostBundleIdentifier),
            Self.quotedField("target", targetBundleIdentifier),
            "targetActive=\(targetIsActive)",
            "targetHidden=\(targetIsHidden)",
            "visibleWindowCount=\(visibleWindowCount)",
            "hasFocusedWindow=\(hasFocusedWindow)",
            "hasMainWindow=\(hasMainWindow)",
            "windowObservationSucceeded=\(windowObservationSucceeded)",
            Self.quotedField("windowObservationFailureReason", windowObservationFailureReason),
            Self.quotedField("classification", classification.rawValue),
            Self.quotedField("classificationReason", classificationReason),
            "allowsWindowlessStableActivation=\(allowsWindowlessStableActivation)",
            "stable=\(stableOverride ?? isStableActivation)"
        ].joined(separator: " ")
    }

    static func quotedField(_ key: String, _ value: String?) -> String {
        "\(key)=\(encode(value ?? "nil"))"
    }

    private static func encode(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                escaped.append("\\\"")
            case "\\":
                escaped.append("\\\\")
            case "\n":
                escaped.append("\\n")
            case "\r":
                escaped.append("\\r")
            case "\t":
                escaped.append("\\t")
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        escaped.append("\"")
        return escaped
    }
}

struct ApplicationObservation {
    struct WindowObservation {
        let windows: [AXUIElement]?
        /// Windows whose `kAXMinimized` read true during this observation
        /// pass. Captured here so consumers (unminimize) never re-issue the
        /// per-window AX roundtrips the observation already paid for.
        var minimizedWindows: [AXUIElement] = []
        let visibleWindowCount: Int
        let hasFocusedWindow: Bool
        let hasMainWindow: Bool
        let windowsReadSucceeded: Bool
        let failureReason: String?

        var hasVisibleWindows: Bool {
            visibleWindowCount > 0
        }
    }

    struct Client: Sendable {
        let currentFrontmostBundleIdentifier: @MainActor () -> String?
        let windowObservation: @MainActor (NSRunningApplication) -> WindowObservation
        let activationPolicy: @MainActor (NSRunningApplication) -> NSApplication.ActivationPolicy
        let now: @Sendable () -> CFAbsoluteTime
        let onSlowObservation: @MainActor (SlowObservationReport) -> Void

        init(
            currentFrontmostBundleIdentifier: @escaping @MainActor () -> String?,
            windowObservation: @escaping @MainActor (NSRunningApplication) -> WindowObservation,
            activationPolicy: @escaping @MainActor (NSRunningApplication) -> NSApplication.ActivationPolicy,
            now: @escaping @Sendable () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent,
            onSlowObservation: @escaping @MainActor (SlowObservationReport) -> Void = { report in
                DiagnosticLog.log(report.logLine)
            }
        ) {
            self.currentFrontmostBundleIdentifier = currentFrontmostBundleIdentifier
            self.windowObservation = windowObservation
            self.activationPolicy = activationPolicy
            self.now = now
            self.onSlowObservation = onSlowObservation
        }
    }

    /// Latency budget for one synchronous window observation on the main
    /// actor. Chosen well under the 75ms activation-confirmation delay and
    /// the 50ms deactivation poll interval so a within-budget observation
    /// can never dominate the shortcut path; observations above it emit a
    /// signposted `AX_OBSERVATION_SLOW` diagnostic. Measured baselines are
    /// recorded in docs/architecture.md (issue #321).
    static let observationLatencyBudget: TimeInterval = 0.050

    /// Bounded observation adapter (issue #321): caps the app-element AX
    /// roundtrips (kAXWindows/kAXFocusedWindow/kAXMainWindow) in the live
    /// capture so a hung target cannot stall the main actor for the ~6s
    /// global AX messaging timeout per call (~18s per observation; measured
    /// 3.0s with this bound against a SIGSTOP'd target). A timed-out windows
    /// read surfaces as a failed read, which the #335 fail-closed handling
    /// already treats correctly. Deliberately NOT applied to window
    /// elements: a timed-out per-window kAXMinimized read would count the
    /// window as visible and drop it from minimizedWindows (fabricated
    /// evidence + lost unminimize), and the stamp is sticky on the stored
    /// refs that unminimize later writes through — so per-window reads keep
    /// their pre-existing global-timeout semantics. Healthy targets measured
    /// at 1–100 windows stay far below this bound.
    static let axMessagingTimeoutSeconds: Float = 1.0

    private static let signposter = OSSignposter(
        subsystem: DiagnosticLog.subsystem,
        category: "AXObservation"
    )

    private let client: Client

    init(client: Client) {
        self.client = client
    }

    @MainActor
    func windowObservation(
        for app: NSRunningApplication,
        phase: WindowObservationPhase
    ) -> WindowObservation {
        let signpostID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval(
            "windowObservation",
            id: signpostID,
            "phase=\(phase.rawValue, privacy: .public) pid=\(app.processIdentifier)"
        )
        let start = client.now()
        let observation = client.windowObservation(app)
        let duration = client.now() - start
        Self.signposter.endInterval(
            "windowObservation",
            interval,
            "visibleWindowCount=\(observation.visibleWindowCount) succeeded=\(observation.windowsReadSucceeded)"
        )

        if duration > Self.observationLatencyBudget {
            client.onSlowObservation(
                SlowObservationReport(
                    phase: phase,
                    bundleIdentifier: app.bundleIdentifier,
                    processIdentifier: app.processIdentifier,
                    visibleWindowCount: observation.visibleWindowCount,
                    windowsReadSucceeded: observation.windowsReadSucceeded,
                    duration: duration
                )
            )
        }

        return observation
    }

    @MainActor
    func snapshot(
        for app: NSRunningApplication,
        windowObservation: WindowObservation? = nil
    ) -> ActivationObservationSnapshot {
        let windowObservation = windowObservation
            ?? self.windowObservation(for: app, phase: .snapshotFallback)
        let classification = classify(
            bundleIdentifier: app.bundleIdentifier,
            activationPolicy: client.activationPolicy(app),
            windowObservation: windowObservation
        )

        return ActivationObservationSnapshot(
            targetBundleIdentifier: app.bundleIdentifier,
            observedFrontmostBundleIdentifier: client.currentFrontmostBundleIdentifier(),
            targetIsActive: app.isActive,
            targetIsHidden: app.isHidden,
            visibleWindowCount: windowObservation.visibleWindowCount,
            hasFocusedWindow: windowObservation.hasFocusedWindow,
            hasMainWindow: windowObservation.hasMainWindow,
            windowObservationSucceeded: windowObservation.windowsReadSucceeded,
            windowObservationFailureReason: windowObservation.failureReason,
            classification: classification.classification,
            classificationReason: classification.reason,
            allowsWindowlessStableActivation: classification.allowsWindowlessStableActivation
        )
    }

    private func classify(
        bundleIdentifier: String?,
        activationPolicy: NSApplication.ActivationPolicy,
        windowObservation: WindowObservation
    ) -> (classification: ApplicationClassification, reason: String, allowsWindowlessStableActivation: Bool) {
        if activationPolicy != .regular {
            return (.systemUtility, "activation policy is \(String(describing: activationPolicy))", true)
        }

        if !windowObservation.windowsReadSucceeded {
            return (.nonStandardWindowed, windowObservation.failureReason ?? "window observation failed", false)
        }

        if windowObservation.visibleWindowCount == 0 &&
            !windowObservation.hasFocusedWindow &&
            !windowObservation.hasMainWindow {
            return (.nonStandardWindowed, "regular app has no visible, focused, or main window evidence", false)
        }

        if windowObservation.visibleWindowCount == 0 ||
            !windowObservation.hasFocusedWindow ||
            !windowObservation.hasMainWindow {
            return (.nonStandardWindowed, "window evidence is incomplete for \(bundleIdentifier ?? "unknown bundle")", false)
        }

        return (.regularWindowed, "visible focused main window", false)
    }
}

extension ApplicationObservation {
    @MainActor
    static let live = ApplicationObservation(client: .live)
}

extension ApplicationObservation.Client {
    @MainActor
    static let live = ApplicationObservation.Client(
        currentFrontmostBundleIdentifier: {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        windowObservation: { app in
            #if WINK_AX_WINDOW_OBSERVATION_FAULT_INJECTION
            if let driver = AXWindowObservationFaultInjectionRuntime.driver {
                return driver.windowObservation(for: app, base: captureWindowObservation)
            }
            #endif
            return captureWindowObservation(for: app)
        },
        activationPolicy: { app in
            app.activationPolicy
        }
    )

    @MainActor
    private static func captureWindowObservation(for app: NSRunningApplication) -> ApplicationObservation.WindowObservation {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, ApplicationObservation.axMessagingTimeoutSeconds)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        let windows = result == .success ? windowsRef as? [AXUIElement] : nil
        var visibleWindowCount = 0
        var minimizedWindows: [AXUIElement] = []
        for window in windows ?? [] {
            var minimizedRef: CFTypeRef?
            let minimizedResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
            let isMinimized = minimizedResult == .success && (minimizedRef as? Bool ?? false)
            if isMinimized {
                minimizedWindows.append(window)
            } else {
                visibleWindowCount += 1
            }
        }

        return ApplicationObservation.WindowObservation(
            windows: windows,
            minimizedWindows: minimizedWindows,
            visibleWindowCount: visibleWindowCount,
            hasFocusedWindow: hasAppWindowAttribute(kAXFocusedWindowAttribute, on: axApp),
            hasMainWindow: hasAppWindowAttribute(kAXMainWindowAttribute, on: axApp),
            windowsReadSucceeded: result == .success,
            failureReason: result == .success ? nil : "axWindowsReadFailed=\(result.rawValue)"
        )
    }

    private static func hasAppWindowAttribute(_ attribute: String, on appElement: AXUIElement) -> Bool {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, attribute as CFString, &valueRef)
        return result == .success && valueRef != nil
    }
}
