import AppKit
import ApplicationServices

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
    }

    private let client: Client

    init(client: Client) {
        self.client = client
    }

    @MainActor
    func windowObservation(for app: NSRunningApplication) -> WindowObservation {
        client.windowObservation(app)
    }

    @MainActor
    func snapshot(
        for app: NSRunningApplication,
        windowObservation: WindowObservation? = nil
    ) -> ActivationObservationSnapshot {
        let windowObservation = windowObservation ?? client.windowObservation(app)
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
            captureWindowObservation(for: app)
        },
        activationPolicy: { app in
            app.activationPolicy
        }
    )

    @MainActor
    private static func captureWindowObservation(for app: NSRunningApplication) -> ApplicationObservation.WindowObservation {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        let windows = result == .success ? windowsRef as? [AXUIElement] : nil
        let visibleWindowCount = (windows ?? []).reduce(into: 0) { count, window in
            var minimizedRef: CFTypeRef?
            let minimizedResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef)
            let isMinimized = minimizedResult == .success && (minimizedRef as? Bool ?? false)
            if !isMinimized {
                count += 1
            }
        }

        return ApplicationObservation.WindowObservation(
            windows: windows,
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
