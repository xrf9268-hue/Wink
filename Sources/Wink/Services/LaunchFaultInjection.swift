#if WINK_LAUNCH_FAULT_INJECTION
import AppKit
import Foundation

/// Compile-time-only launch fault injection used to validate launch completion
/// ownership in a packaged app. Production builds do not compile this file's
/// declarations, argument parser, errors, or diagnostic markers.
struct LaunchFaultInjectionConfiguration: Equatable, Sendable {
    enum Mode: String, Sendable {
        case staleError = "stale-error"
        case currentErrorOnce = "current-error-once"
    }

    private static let argumentPrefix = "--validation-launch-fault="

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

final class LaunchFaultInjector: @unchecked Sendable {
    typealias Completion = @Sendable (NSRunningApplication?, Error?) -> Void
    typealias WorkspaceOpen = (
        URL,
        NSWorkspace.OpenConfiguration,
        @escaping Completion
    ) -> Void

    private enum Action {
        case holdFirst
        case deliverStale(Completion)
        case deliverCurrent
        case passthrough(requestOrdinal: Int, afterInjection: Bool)
    }

    private let configuration: LaunchFaultInjectionConfiguration
    private let workspaceOpen: WorkspaceOpen
    private let diagnosticLog: @Sendable (String) -> Void
    private let lock = NSLock()
    private var matchingRequestCount = 0
    private var heldFirstCompletion: Completion?

    init(
        configuration: LaunchFaultInjectionConfiguration,
        workspaceOpen: @escaping WorkspaceOpen,
        diagnosticLog: @escaping @Sendable (String) -> Void = DiagnosticLog.log
    ) {
        self.configuration = configuration
        self.workspaceOpen = workspaceOpen
        self.diagnosticLog = diagnosticLog
        log(event: "configured", requestOrdinal: 0)
    }

    @MainActor
    var client: AppSwitcher.FallbackActivationClient {
        AppSwitcher.FallbackActivationClient { [self] url, openConfiguration, completion in
            openApplication(url, configuration: openConfiguration, completion: completion)
        }
    }

    private func openApplication(
        _ url: URL,
        configuration openConfiguration: NSWorkspace.OpenConfiguration,
        completion: @escaping Completion
    ) {
        guard Bundle(url: url)?.bundleIdentifier == configuration.targetBundleIdentifier else {
            workspaceOpen(url, openConfiguration, completion)
            return
        }

        let action: Action
        lock.lock()
        matchingRequestCount += 1
        let requestOrdinal = matchingRequestCount
        switch configuration.mode {
        case .staleError:
            if requestOrdinal == 1 {
                heldFirstCompletion = completion
                action = .holdFirst
            } else if requestOrdinal == 2, let heldFirstCompletion {
                self.heldFirstCompletion = nil
                action = .deliverStale(heldFirstCompletion)
            } else {
                action = .passthrough(requestOrdinal: requestOrdinal, afterInjection: true)
            }
        case .currentErrorOnce:
            if requestOrdinal == 1 {
                action = .deliverCurrent
            } else {
                action = .passthrough(requestOrdinal: requestOrdinal, afterInjection: true)
            }
        }
        lock.unlock()

        switch action {
        case .holdFirst:
            log(event: "first_request_held", requestOrdinal: requestOrdinal)
        case .deliverStale(let firstCompletion):
            // The second AppSwitcher request already owns a newer generation
            // before this client is called, so the held first completion is
            // stale at the instant it is delivered.
            log(event: "stale_error_delivered", requestOrdinal: 1)
            firstCompletion(nil, LaunchFaultInjectionError.staleFirstRequest)
            log(event: "second_request_forwarded", requestOrdinal: requestOrdinal)
            forward(
                url,
                configuration: openConfiguration,
                completion: completion,
                requestOrdinal: requestOrdinal,
                successEvent: "second_success_delivered"
            )
        case .deliverCurrent:
            log(event: "current_error_delivered", requestOrdinal: requestOrdinal)
            completion(nil, LaunchFaultInjectionError.currentRequest)
        case .passthrough(let passthroughOrdinal, let afterInjection):
            if afterInjection {
                log(event: "passthrough_after_injection", requestOrdinal: passthroughOrdinal)
            }
            forward(
                url,
                configuration: openConfiguration,
                completion: completion,
                requestOrdinal: passthroughOrdinal,
                successEvent: "passthrough_success_delivered"
            )
        }
    }

    private func forward(
        _ url: URL,
        configuration openConfiguration: NSWorkspace.OpenConfiguration,
        completion: @escaping Completion,
        requestOrdinal: Int,
        successEvent: String
    ) {
        workspaceOpen(url, openConfiguration) { [self] app, error in
            if let error {
                log(
                    event: "workspace_error_delivered",
                    requestOrdinal: requestOrdinal,
                    details: "error=\(Self.sanitized(error.localizedDescription))"
                )
            } else {
                let processIdentifier = app.map { String($0.processIdentifier) } ?? "nil"
                log(
                    event: successEvent,
                    requestOrdinal: requestOrdinal,
                    details: "pid=\(processIdentifier)"
                )
            }
            completion(app, error)
        }
    }

    private func log(event: String, requestOrdinal: Int, details: String? = nil) {
        var message = "LAUNCH_FAULT_INJECTION mode=\(configuration.mode.rawValue) event=\(event) target=\(configuration.targetBundleIdentifier) requestOrdinal=\(requestOrdinal)"
        if let details {
            message += " \(details)"
        }
        diagnosticLog(message)
    }

    private static func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "_")
    }
}

private enum LaunchFaultInjectionError: LocalizedError, Sendable {
    case staleFirstRequest
    case currentRequest

    var errorDescription: String? {
        switch self {
        case .staleFirstRequest:
            "injected stale launch error from the first request"
        case .currentRequest:
            "injected current launch error"
        }
    }
}
#endif
