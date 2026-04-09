import Foundation

struct ToggleDiagnosticEvent: Sendable {
    enum Family: String, Sendable {
        case decision = "TOGGLE_TRACE_DECISION"
        case session = "TOGGLE_TRACE_SESSION"
        case reset = "TOGGLE_TRACE_RESET"
        case confirmation = "TOGGLE_TRACE_CONFIRMATION"
    }

    let family: Family
    let attemptID: UUID?
    let bundleIdentifier: String
    let pid: pid_t?
    let phase: ToggleSessionCoordinator.Session.Phase?
    let event: String
    let activationPath: AppSwitcher.ActivationPath?
    let reason: String?
    let previousBundleIdentifier: String?

    var logMessage: String {
        [
            family.rawValue,
            Self.stringField("attemptId", attemptID?.uuidString ?? "nil"),
            Self.stringField("bundle", bundleIdentifier),
            "pid=\(pid.map(String.init) ?? "nil")",
            Self.stringField("phase", phase?.rawValue ?? "nil"),
            Self.stringField("event", event),
            Self.stringField("activationPath", activationPath?.rawValue ?? "nil"),
            Self.quotedField("reason", reason),
            Self.quotedField("previousBundle", previousBundleIdentifier)
        ].joined(separator: " ")
    }

    private static func stringField(_ key: String, _ value: String) -> String {
        "\(key)=\(value)"
    }

    private static func quotedField(_ key: String, _ value: String?) -> String {
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
