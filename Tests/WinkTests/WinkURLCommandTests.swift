import Foundation
import Testing
@testable import Wink

@Suite("Strict wink URL grammar")
struct WinkURLCommandTests {
    @Test
    func acceptedCommandTable() {
        let accepted: [(String, WinkURLCommand)] = [
            ("wink://toggle?bundle=com.google.Chrome", .toggle(bundleIdentifier: "com.google.Chrome")),
            ("wink://toggle?bundle=%20com.apple.Safari%20", .toggle(bundleIdentifier: "com.apple.Safari")),
            ("WINK://TOGGLE?bundle=COM.Google.Chrome", .toggle(bundleIdentifier: "COM.Google.Chrome")),
            ("wink://toggle/?bundle=com.apple.Safari", .toggle(bundleIdentifier: "com.apple.Safari")),
            ("wink://toggle?bundle=com.apple%2ESafari", .toggle(bundleIdentifier: "com.apple.Safari")),
            ("wink://toggle?bundle=com.apple.Image_Capture", .toggle(bundleIdentifier: "com.apple.Image_Capture")),
            ("wink://pause", .pause),
            ("WINK://Resume", .resume),
            ("wink://SEARCH", .search),
            ("wink://open-settings", .openSettings(tab: nil)),
            ("wink://open-settings?tab=shortcuts", .openSettings(tab: .shortcuts)),
            ("wink://open-settings?tab=general", .openSettings(tab: .general)),
            ("wink://open-settings?tab=insights", .openSettings(tab: .insights)),
            ("wink://focus?bundle=com.apple.Safari", .focus(bundleIdentifier: "com.apple.Safari")),
            ("wink://focus?bundle=com.apple.Image_Capture", .focus(bundleIdentifier: "com.apple.Image_Capture")),
        ]

        for (rawValue, expected) in accepted {
            #expect(WinkURLCommand.parse(rawValue) == expected, "expected acceptance for \(rawValue)")
            if let url = URL(string: rawValue) {
                #expect(WinkURLCommand.parse(url) == expected, "URL overload diverged for \(rawValue)")
            }
        }
    }

    @Test
    func rejectedCommandTable() {
        let overlongBundle = String(repeating: "a", count: WinkURLCommand.maximumBundleIdentifierByteCount + 1)
        let overlongURL = "wink://focus?bundle="
            + String(repeating: "a", count: WinkURLCommand.maximumURLByteCount)
        let rejected = [
            "wink://toggle",
            "wink://toggle?bundle=",
            "wink://toggle?bundle",
            "wink://toggle?bundle=%20%20",
            "wink://toggle?bundle=com.apple.Safari&bundle=com.google.Chrome",
            "wink://toggle?bundle=com.apple.Safari&extra=1",
            "wink://toggle?Bundle=com.apple.Safari",
            "wink://pause?",
            "wink://pause?extra=1",
            "wink://resume#fragment",
            "wink://search?query=Safari",
            "wink://open-settings?tab",
            "wink://open-settings?tab=",
            "wink://open-settings?tab=Insights",
            "wink://open-settings?tab=advanced",
            "wink://open-settings?tab=general&tab=insights",
            "wink://open-settings?Tab=general",
            "wink://focus",
            "wink://focus?bundle=测试",
            "wink://focus?bundle=%E6%B5%8B%E8%AF%95",
            "wink://focus?bundle=com.apple%2FSafari",
            "wink://focus?bundle=com.apple+Safari",
            "wink://focus?bundle=%FF",
            "wink://%FF@focus?bundle=com.apple.Safari",
            "wink://focus/%FF?bundle=com.apple.Safari",
            "wink://pause#%FF",
            "wink://focus/%C0%AF?bundle=com.apple.Safari",
            "wink://focus?bundle=%ZZ",
            "wink://%66ocus?bundle=com.apple.Safari",
            "wink://focus?b%75ndle=com.apple.Safari",
            "wink://open-settings?%74ab=insights",
            "wink://user@focus?bundle=com.apple.Safari",
            "wink://user:secret@focus?bundle=com.apple.Safari",
            "wink://focus:?bundle=com.apple.Safari",
            "wink://focus:42?bundle=com.apple.Safari",
            "wink://focus:999999999999999999999?bundle=com.apple.Safari",
            "wink://pause:",
            "wink://focus/extra?bundle=com.apple.Safari",
            "wink://focus/%2E%2E?bundle=com.apple.Safari",
            "wink://unknown",
            "wink:pause",
            "https://focus?bundle=com.apple.Safari",
            "wink://focus?bundle=\(overlongBundle)",
            overlongURL,
        ]

        for rawValue in rejected {
            #expect(WinkURLCommand.parse(rawValue) == nil, "expected rejection for \(rawValue.prefix(120))")
            if let url = URL(string: rawValue) {
                #expect(WinkURLCommand.parse(url) == nil, "URL overload accepted \(rawValue.prefix(120))")
            }
        }
    }

    @Test
    func malformedPercentEscapesHaveABoundedReason() {
        #expect(
            WinkURLCommand.parseResult("wink://focus?bundle=%ZZ")
                == .failure(.invalidPercentEncoding)
        )
        #expect(
            WinkURLCommand.parseResult("wink://focus?bundle=%")
                == .failure(.invalidPercentEncoding)
        )
    }

    @Test
    func unicodeNormalizedCommandHostsAreRejectedBeforeFoundationParsing() {
        let rejected = [
            "wink://ＰＡＵＳＥ",
            "wink://reſume",
            "wink://ｓｅａｒｃｈ",
            "wink://ｆｏｃｕｓ?bundle=com.apple.Safari",
            "wink://open－settings?tab=insights",
        ]

        for rawValue in rejected {
            #expect(
                WinkURLCommand.parseResult(rawValue) == .failure(.nonASCIIAuthority),
                "expected raw Unicode authority rejection for \(rawValue)"
            )
            let rawPreservingURL = NSURL(
                dataRepresentation: Data(rawValue.utf8),
                relativeTo: nil
            ) as URL
            #expect(
                WinkURLCommand.parseResult(rawPreservingURL) == .failure(.nonASCIIAuthority),
                "expected URL data-representation rejection for \(rawValue)"
            )
        }
    }

    @Test
    func acceptedDiagnosticsAreNormalizedAndBounded() {
        let command = WinkURLCommand.focus(bundleIdentifier: String(repeating: "a", count: 255))
        #expect(command.diagnosticDescription == "focus bundle=\(String(repeating: "a", count: 255))")
        #expect(command.diagnosticDescription.utf8.count < 300)
        #expect(WinkURLParseRejection.allDiagnosticReasonsAreBounded)
    }
}

private extension WinkURLParseRejection {
    static var allDiagnosticReasonsAreBounded: Bool {
        let reasons: [Self] = [
            .urlTooLong, .invalidPercentEncoding, .encodedStructure, .invalidComponents, .unsupportedScheme,
            .missingHost, .nonASCIIAuthority, .userInfoNotAllowed, .portNotAllowed, .fragmentNotAllowed,
            .unsupportedPath, .unsupportedCommand, .unexpectedQuery, .missingParameter,
            .unknownParameter, .duplicateParameter, .missingParameterValue,
            .invalidBundleIdentifier, .unsupportedSettingsTab,
        ]
        return reasons.allSatisfy { $0.rawValue.utf8.count <= 32 }
    }
}
