#if WINK_CARBON_BINDING_FAULT_INJECTION
import Carbon.HIToolbox
import Foundation

/// Compile-time-only validation profile for a permanent single-binding Carbon
/// registration conflict. Production builds contain neither its parser nor its
/// diagnostic marker.
struct CarbonBindingFaultInjectionConfiguration: Equatable, Sendable {
    enum Mode: String, Sendable {
        case permanentConflict = "permanent-conflict"
    }

    private static let argumentPrefix = "--validation-carbon-binding-fault="

    let mode: Mode
    let keyCode: UInt32
    let modifiers: UInt32

    init?(arguments: [String]) {
        let values = arguments.compactMap { argument -> String? in
            guard argument.hasPrefix(Self.argumentPrefix) else { return nil }
            return String(argument.dropFirst(Self.argumentPrefix.count))
        }
        guard values.count == 1 else { return nil }

        let components = values[0].split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              let mode = Mode(rawValue: String(components[0])),
              let keyCode = UInt32(components[1]),
              let modifiers = UInt32(components[2]) else {
            return nil
        }
        self.mode = mode
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

@MainActor
final class CarbonBindingFaultInjectionDriver {
    private let configuration: CarbonBindingFaultInjectionConfiguration
    private let baseClient: CarbonHotKeyRegistrationClient
    private let diagnosticLog: (String) -> Void
    private var registerCalls = 0
    private var forwardedRegisterCalls = 0
    private var injectedFailures = 0
    private var unregisterCalls = 0

    init(
        configuration: CarbonBindingFaultInjectionConfiguration,
        baseClient: CarbonHotKeyRegistrationClient,
        diagnosticLog: @escaping (String) -> Void = DiagnosticLog.log
    ) {
        self.configuration = configuration
        self.baseClient = baseClient
        self.diagnosticLog = diagnosticLog
        log(event: "configured")
    }

    var client: CarbonHotKeyRegistrationClient {
        CarbonHotKeyRegistrationClient(
            register: { [self] keyCode, modifiers, hotKeyID in
                registerCalls += 1
                if configuration.mode == .permanentConflict,
                   keyCode == configuration.keyCode,
                   modifiers == configuration.modifiers {
                    injectedFailures += 1
                    log(
                        event: "register_injected",
                        details: "keyCode=\(keyCode) modifiers=\(modifiers) status=\(eventHotKeyExistsErr)"
                    )
                    return (Int32(eventHotKeyExistsErr), nil)
                }

                forwardedRegisterCalls += 1
                let result = baseClient.register(keyCode, modifiers, hotKeyID)
                log(
                    event: "register_forwarded",
                    details: "keyCode=\(keyCode) modifiers=\(modifiers) status=\(result.status)"
                )
                return result
            },
            unregister: { [self] hotKeyRef in
                unregisterCalls += 1
                baseClient.unregister(hotKeyRef)
                log(event: "unregister_forwarded")
            }
        )
    }

    private func log(event: String, details: String? = nil) {
        var message = "CARBON_BINDING_FAULT_INJECTION mode=\(configuration.mode.rawValue) targetKeyCode=\(configuration.keyCode) targetModifiers=\(configuration.modifiers) event=\(event) registerCalls=\(registerCalls) forwardedRegisterCalls=\(forwardedRegisterCalls) injectedFailures=\(injectedFailures) unregisterCalls=\(unregisterCalls)"
        if let details {
            message += " \(details)"
        }
        diagnosticLog(message)
    }
}
#endif
