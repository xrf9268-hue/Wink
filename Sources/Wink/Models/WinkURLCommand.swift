import Foundation

enum WinkURLSettingsTab: String, Equatable, Hashable, Sendable {
    case shortcuts
    case general
    case insights
}

enum WinkURLParseRejection: String, Error, Equatable, Sendable {
    case urlTooLong = "url_too_long"
    case invalidPercentEncoding = "invalid_percent_encoding"
    case encodedStructure = "encoded_structure"
    case invalidComponents = "invalid_components"
    case unsupportedScheme = "unsupported_scheme"
    case missingHost = "missing_host"
    case nonASCIIAuthority = "non_ascii_authority"
    case userInfoNotAllowed = "user_info_not_allowed"
    case portNotAllowed = "port_not_allowed"
    case fragmentNotAllowed = "fragment_not_allowed"
    case unsupportedPath = "unsupported_path"
    case unsupportedCommand = "unsupported_command"
    case unexpectedQuery = "unexpected_query"
    case missingParameter = "missing_parameter"
    case unknownParameter = "unknown_parameter"
    case duplicateParameter = "duplicate_parameter"
    case missingParameterValue = "missing_parameter_value"
    case invalidBundleIdentifier = "invalid_bundle_identifier"
    case unsupportedSettingsTab = "unsupported_settings_tab"
}

/// Pure, fail-closed grammar for untrusted `wink://` input.
///
/// Scheme and command-host matching remain case-insensitive for compatibility
/// with the original toggle/pause/resume surface. Query names and enum values
/// are exact. Every accepted command owns its complete query allowlist; a
/// duplicate or unknown item rejects the whole URL before any side effect.
enum WinkURLCommand: Equatable, Hashable, Sendable {
    static let maximumURLByteCount = 2_048
    static let maximumBundleIdentifierByteCount = 255

    case toggle(bundleIdentifier: String)
    case pause
    case resume
    case search
    case openSettings(tab: WinkURLSettingsTab?)
    case focus(bundleIdentifier: String)

    var diagnosticDescription: String {
        switch self {
        case .toggle(let bundleIdentifier):
            "toggle bundle=\(bundleIdentifier)"
        case .pause:
            "pause"
        case .resume:
            "resume"
        case .search:
            "search"
        case .openSettings(let tab):
            tab.map { "open-settings tab=\($0.rawValue)" } ?? "open-settings"
        case .focus(let bundleIdentifier):
            "focus bundle=\(bundleIdentifier)"
        }
    }

    static func parse(_ url: URL) -> WinkURLCommand? {
        try? parseResult(url).get()
    }

    static func parse(_ rawValue: String) -> WinkURLCommand? {
        try? parseResult(rawValue).get()
    }

    static func parseResult(_ url: URL) -> Result<WinkURLCommand, WinkURLParseRejection> {
        guard let rawValue = String(data: url.dataRepresentation, encoding: .utf8) else {
            return .failure(.invalidComponents)
        }
        return parseResult(rawValue)
    }

    static func parseResult(_ rawValue: String) -> Result<WinkURLCommand, WinkURLParseRejection> {
        do {
            return .success(try parseStrict(rawValue))
        } catch let rejection as WinkURLParseRejection {
            return .failure(rejection)
        } catch {
            return .failure(.invalidComponents)
        }
    }

    private static func parseStrict(_ rawValue: String) throws -> WinkURLCommand {
        guard rawValue.utf8.count <= maximumURLByteCount else {
            throw WinkURLParseRejection.urlTooLong
        }
        guard hasValidPercentEscapes(rawValue), rawValue.removingPercentEncoding != nil else {
            throw WinkURLParseRejection.invalidPercentEncoding
        }
        guard let components = URLComponents(string: rawValue) else {
            throw WinkURLParseRejection.invalidComponents
        }
        guard components.scheme?.lowercased() == "wink" else {
            throw WinkURLParseRejection.unsupportedScheme
        }
        guard rawAuthority(in: rawValue)?.utf8.allSatisfy({ $0 < 0x80 }) == true else {
            // URLComponents applies IDNA/compatibility normalization to host
            // names. Inspect the raw authority first so full-width or other
            // Unicode spellings cannot turn into an allowlisted command.
            throw WinkURLParseRejection.nonASCIIAuthority
        }
        guard components.user == nil, components.password == nil else {
            throw WinkURLParseRejection.userInfoNotAllowed
        }
        guard components.port == nil, !rawAuthorityContainsPortDelimiter(rawValue) else {
            throw WinkURLParseRejection.portNotAllowed
        }
        guard components.fragment == nil else {
            throw WinkURLParseRejection.fragmentNotAllowed
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw WinkURLParseRejection.unsupportedPath
        }
        guard components.percentEncodedHost?.contains("%") == false else {
            throw WinkURLParseRejection.encodedStructure
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw WinkURLParseRejection.missingHost
        }

        switch host {
        case "toggle":
            return .toggle(bundleIdentifier: try bundleIdentifier(
                from: components,
                trimmingLegacyOuterWhitespace: true
            ))
        case "pause":
            try requireNoQuery(in: components)
            return .pause
        case "resume":
            try requireNoQuery(in: components)
            return .resume
        case "search":
            try requireNoQuery(in: components)
            return .search
        case "open-settings":
            guard components.percentEncodedQuery != nil else {
                return .openSettings(tab: nil)
            }
            let value = try singleParameter(named: "tab", in: components)
            guard let tab = WinkURLSettingsTab(rawValue: value) else {
                throw WinkURLParseRejection.unsupportedSettingsTab
            }
            return .openSettings(tab: tab)
        case "focus":
            return .focus(bundleIdentifier: try bundleIdentifier(from: components))
        default:
            throw WinkURLParseRejection.unsupportedCommand
        }
    }

    private static func requireNoQuery(in components: URLComponents) throws {
        guard components.percentEncodedQuery == nil else {
            throw WinkURLParseRejection.unexpectedQuery
        }
    }

    private static func bundleIdentifier(
        from components: URLComponents,
        trimmingLegacyOuterWhitespace: Bool = false
    ) throws -> String {
        let rawValue = try singleParameter(named: "bundle", in: components)
        let bundleIdentifier = trimmingLegacyOuterWhitespace
            ? rawValue.trimmingCharacters(in: .whitespaces)
            : rawValue
        guard bundleIdentifier.utf8.count <= maximumBundleIdentifierByteCount,
              !bundleIdentifier.isEmpty,
              bundleIdentifier.utf8.allSatisfy(isAllowedBundleIdentifierByte) else {
            throw WinkURLParseRejection.invalidBundleIdentifier
        }
        return bundleIdentifier
    }

    private static func singleParameter(named expectedName: String, in components: URLComponents) throws -> String {
        guard let percentEncodedQuery = components.percentEncodedQuery else {
            throw WinkURLParseRejection.missingParameter
        }
        guard percentEncodedQuery
            .split(separator: "&", omittingEmptySubsequences: false)
            .allSatisfy({ item in
                let encodedName = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
                return !encodedName.contains("%")
            }) else {
            throw WinkURLParseRejection.encodedStructure
        }
        guard let queryItems = components.queryItems else {
            throw WinkURLParseRejection.missingParameterValue
        }
        guard !queryItems.contains(where: { $0.name != expectedName }) else {
            throw WinkURLParseRejection.unknownParameter
        }
        guard queryItems.count == 1 else {
            if queryItems.isEmpty {
                throw WinkURLParseRejection.missingParameter
            }
            throw WinkURLParseRejection.duplicateParameter
        }
        guard let value = queryItems[0].value, !value.isEmpty else {
            throw WinkURLParseRejection.missingParameterValue
        }
        return value
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x25 else {
                index += 1
                continue
            }
            guard index + 2 < bytes.count,
                  isHexDigit(bytes[index + 1]),
                  isHexDigit(bytes[index + 2]) else {
                return false
            }
            index += 3
        }
        return true
    }

    /// Foundation reports `port == nil` for both an empty port (`host:`) and
    /// some overflowing numeric ports. Inspect only the raw authority so a
    /// colon in the query value does not become a false positive.
    private static func rawAuthorityContainsPortDelimiter(_ value: String) -> Bool {
        rawAuthority(in: value)?.contains(":") == true
    }

    private static func rawAuthority(in value: String) -> Substring? {
        guard let authorityStart = value.range(of: "://")?.upperBound else {
            return nil
        }
        return value[authorityStart...].prefix { character in
            character != "/" && character != "?" && character != "#"
        }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x46).contains(byte)
            || (0x61 ... 0x66).contains(byte)
    }

    private static func isAllowedBundleIdentifierByte(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x5A).contains(byte)
            || (0x61 ... 0x7A).contains(byte)
            || byte == 0x2D
            || byte == 0x2E
    }
}
