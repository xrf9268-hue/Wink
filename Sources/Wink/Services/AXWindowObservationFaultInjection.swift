#if WINK_AX_WINDOW_OBSERVATION_FAULT_INJECTION
import AppKit

/// Compile-time-only validation profile for deactivation confirmation when an
/// AX windows read is unknown. Production builds contain neither this parser,
/// driver, nor its diagnostic markers.
struct AXWindowObservationFaultInjectionConfiguration: Equatable, Sendable {
    enum Mode: String, Sendable {
        case deactivationOnce = "deactivation-once"
    }

    private static let argumentPrefix = "--validation-ax-window-observation-fault="

    let mode: Mode
    let targetBundleIdentifier: String

    init?(arguments: [String]) {
        let values = arguments.compactMap { argument -> String? in
            guard argument.hasPrefix(Self.argumentPrefix) else { return nil }
            return String(argument.dropFirst(Self.argumentPrefix.count))
        }
        guard values.count == 1 else { return nil }

        let components = values[0].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              let mode = Mode(rawValue: String(components[0])),
              !components[1].isEmpty else {
            return nil
        }

        self.mode = mode
        self.targetBundleIdentifier = String(components[1])
    }
}

@MainActor
final class AXWindowObservationFaultInjectionDriver {
    typealias WindowObservation = ApplicationObservation.WindowObservation

    private let configuration: AXWindowObservationFaultInjectionConfiguration
    private let currentFrontmostBundleIdentifier: () -> String?
    private let diagnosticLog: (String) -> Void
    private var matchingHideWasSuppressed = false
    private var failedObservationWasInjected = false

    init(
        configuration: AXWindowObservationFaultInjectionConfiguration,
        currentFrontmostBundleIdentifier: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        diagnosticLog: @escaping (String) -> Void = DiagnosticLog.log
    ) {
        self.configuration = configuration
        self.currentFrontmostBundleIdentifier = currentFrontmostBundleIdentifier
        self.diagnosticLog = diagnosticLog
        log(event: "configured")
    }

    func hideApplication(
        _ app: NSRunningApplication,
        base: (NSRunningApplication) -> Bool
    ) -> Bool {
        guard app.bundleIdentifier == configuration.targetBundleIdentifier else {
            return base(app)
        }

        guard !matchingHideWasSuppressed else {
            let result = base(app)
            log(event: "hide_forwarded", details: "apiReturn=\(result)")
            return result
        }

        matchingHideWasSuppressed = true
        log(event: "hide_suppressed", details: "armed=true")
        return true
    }

    func windowObservation(
        for app: NSRunningApplication,
        base: (NSRunningApplication) -> WindowObservation
    ) -> WindowObservation {
        guard app.bundleIdentifier == configuration.targetBundleIdentifier,
              matchingHideWasSuppressed,
              !failedObservationWasInjected,
              !app.isHidden,
              let frontmostBundleIdentifier = currentFrontmostBundleIdentifier(),
              frontmostBundleIdentifier != configuration.targetBundleIdentifier else {
            return base(app)
        }

        failedObservationWasInjected = true
        log(
            event: "window_read_failed",
            details: "frontmost=\(frontmostBundleIdentifier) targetHidden=false windowsReadSucceeded=false"
        )
        return WindowObservation(
            windows: nil,
            visibleWindowCount: 0,
            hasFocusedWindow: false,
            hasMainWindow: false,
            windowsReadSucceeded: false,
            failureReason: "validationInjectedAXWindowsReadFailure"
        )
    }

    private func log(event: String, details: String? = nil) {
        var message = "AX_WINDOW_OBSERVATION_FAULT_INJECTION mode=\(configuration.mode.rawValue) event=\(event) target=\(configuration.targetBundleIdentifier)"
        if let details {
            message += " \(details)"
        }
        diagnosticLog(message)
    }
}

@MainActor
enum AXWindowObservationFaultInjectionRuntime {
    static let driver: AXWindowObservationFaultInjectionDriver? = {
        guard let configuration = AXWindowObservationFaultInjectionConfiguration(
            arguments: ProcessInfo.processInfo.arguments
        ) else {
            return nil
        }
        return AXWindowObservationFaultInjectionDriver(configuration: configuration)
    }()
}
#endif
