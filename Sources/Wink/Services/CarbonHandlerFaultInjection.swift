#if WINK_CARBON_HANDLER_FAULT_INJECTION
import Carbon.HIToolbox
import Foundation

/// Compile-time-only validation profile for Carbon handler installation
/// readiness. Production builds contain neither this parser nor its markers.
struct CarbonHandlerFaultInjectionConfiguration: Equatable, Sendable {
    enum Mode: String, Sendable {
        case failOnce = "fail-once"
    }

    private static let argumentPrefix = "--validation-carbon-handler-fault="

    let mode: Mode

    init?(arguments: [String]) {
        let values = arguments.compactMap { argument -> String? in
            guard argument.hasPrefix(Self.argumentPrefix) else { return nil }
            return String(argument.dropFirst(Self.argumentPrefix.count))
        }
        guard values.count == 1, let mode = Mode(rawValue: values[0]) else {
            return nil
        }
        self.mode = mode
    }
}

@MainActor
final class CarbonHandlerFaultInjectionDriver {
    private let configuration: CarbonHandlerFaultInjectionConfiguration
    private let baseFactory: CarbonHotKeyHandlerFactory
    private let diagnosticLog: (String) -> Void
    private var installAttempt = 0

    init(
        configuration: CarbonHandlerFaultInjectionConfiguration,
        baseFactory: CarbonHotKeyHandlerFactory,
        diagnosticLog: @escaping (String) -> Void = DiagnosticLog.log
    ) {
        self.configuration = configuration
        self.baseFactory = baseFactory
        self.diagnosticLog = diagnosticLog
        log(event: "configured", attempt: 0)
    }

    var factory: CarbonHotKeyHandlerFactory {
        CarbonHotKeyHandlerFactory { [self] delivery in
            installAttempt += 1
            if configuration.mode == .failOnce, installAttempt == 1 {
                log(
                    event: "handler_install_failed",
                    attempt: installAttempt,
                    details: "status=\(eventInternalErr)"
                )
                return .failed(Int32(eventInternalErr))
            }

            let result = baseFactory.install(delivery)
            switch result {
            case .installed:
                log(
                    event: "handler_install_forwarded",
                    attempt: installAttempt,
                    details: "result=installed"
                )
            case .failed(let status):
                log(
                    event: "handler_install_forwarded",
                    attempt: installAttempt,
                    details: "result=failed status=\(status)"
                )
            }
            return result
        }
    }

    private func log(event: String, attempt: Int, details: String? = nil) {
        var message = "CARBON_HANDLER_FAULT_INJECTION mode=\(configuration.mode.rawValue) event=\(event) attempt=\(attempt)"
        if let details {
            message += " \(details)"
        }
        diagnosticLog(message)
    }
}
#endif
