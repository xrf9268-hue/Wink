import Foundation

/// Removes personally identifying and secret material from diagnostic text
/// before it can leave the machine.
///
/// Two rules shape everything here:
///
/// 1. **Redact by evidence, not by shape.** Blanket-redacting anything that
///    "looks opaque" would eat the UUIDs, key codes, and bundle identifiers
///    that make a diagnostic bundle worth reading, and it would still miss a
///    secret that happens to look like a word. Every rule below keys off a
///    *label* (`token=`, `Authorization:`) or a structurally unambiguous form
///    (a home-directory prefix, a JWT's three base64 segments).
/// 2. **Never grow the input.** A redactor that can be made to expand its
///    input is a denial-of-service on the export path, so every rule replaces
///    with a fixed-length marker and the whole line is length-bounded.
///
/// What is deliberately *not* redacted: bundle identifiers and application
/// names. They are the single most useful field for diagnosing a shortcut
/// problem, and removing them would make most reports unactionable. The export
/// preview discloses that they are present so the choice stays the user's.
struct DiagnosticsRedactor: Sendable {
    static let marker = "<redacted>"

    /// Longest line kept intact. Beyond this a line is truncated with a
    /// visible marker rather than dropped, so a corrupted or hostile log
    /// cannot silently remove evidence around it — and cannot blow up the
    /// export either.
    static let maximumLineLength = 2_000

    /// Keys whose value is secret whatever it looks like. Matched
    /// case-insensitively against `key=value`, `key: value`, and `"key": "…"`.
    private static let sensitiveKeys = [
        "password", "passwd", "secret", "token", "apikey", "api_key",
        "auth", "credential", "private_key", "privatekey",
        "session", "signature", "sig", "ed_signature",
    ]

    /// Header-shaped keys whose value runs to the end of the line and can
    /// contain spaces (`Authorization: Bearer …`). Stopping at the first
    /// whitespace, as the token-scoped rule does, would redact the scheme and
    /// leave the credential itself in the log.
    private static let lineTailSensitiveKeys = [
        "authorization", "proxy-authorization", "cookie", "set-cookie",
    ]

    private let homeDirectoryPath: String
    private let userName: String

    init(
        homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        userName: String = NSUserName()
    ) {
        self.homeDirectoryPath = homeDirectoryPath
        self.userName = userName
    }

    // MARK: - Entry points

    /// Redacts one line and bounds its length. Never returns a longer string
    /// than it received.
    func redact(line: String) -> String {
        var value = line
        value = redactingHomePaths(value)
        value = redactingLabelledSecrets(value)
        value = redactingBearerTokens(value)
        value = redactingJSONWebTokens(value)
        value = redactingURLQueries(value)
        value = redactingUserName(value)
        return truncating(value)
    }

    /// Redacts a whole document line by line. Line endings are normalized to
    /// `\n` so the output is byte-stable regardless of what produced the log.
    func redact(text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { redact(line: String($0)) }.joined(separator: "\n")
    }

    // MARK: - Rules

    /// `/Users/alice/...` and the real home path both become `~/...`. The
    /// literal home path is replaced first so a home directory that is not
    /// under `/Users` (a network account, a relocated home) is still caught.
    private func redactingHomePaths(_ value: String) -> String {
        var value = value
        if !homeDirectoryPath.isEmpty, homeDirectoryPath != "/" {
            value = value.replacingOccurrences(of: homeDirectoryPath, with: "~")
        }
        return value.replacingOccurrences(
            of: #"/Users/[^/\s"']+"#,
            with: "~",
            options: .regularExpression
        )
    }

    /// The account name can appear outside a path — in a log message, a
    /// display name, a URL. Applied after path rules so it does not fight
    /// them.
    ///
    /// Boundary-aware rather than a plain substring match: a bare
    /// `\#(escaped)` would either have to skip short names entirely (a
    /// 1-2 character name matches inside all sorts of ordinary words — "al"
    /// is "sign-al", "norm-al") or, if applied unconditionally, redact those
    /// same ordinary words into noise. Requiring that neither side of the
    /// match be a letter or digit gets both right: a short name is still
    /// caught when it stands alone as a path component, URL segment, or log
    /// token (`/al/`, `by al `, `user=al&`), but never when it is merely
    /// part of a longer word.
    private func redactingUserName(_ value: String) -> String {
        guard !userName.isEmpty else { return value }
        let escaped = NSRegularExpression.escapedPattern(for: userName)
        let pattern = #"(?<![A-Za-z0-9])\#(escaped)(?![A-Za-z0-9])"#
        return value.replacingOccurrences(
            of: pattern,
            with: Self.marker,
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func redactingLabelledSecrets(_ value: String) -> String {
        var value = value
        for key in Self.lineTailSensitiveKeys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            value = value.replacingOccurrences(
                of: #"(?i)("?\#(escaped)"?\s*[:=]\s*).*$"#,
                with: "$1\(Self.marker)",
                options: .regularExpression
            )
        }
        for key in Self.sensitiveKeys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            // key=value / key: value / "key": "value", stopping at the first
            // separator so the rest of the line survives.
            let pattern = #"(?i)("?\#(escaped)"?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;)}\]]+)"#
            value = value.replacingOccurrences(
                of: pattern,
                with: "$1\(Self.marker)",
                options: .regularExpression
            )
        }
        return value
    }

    /// `Authorization: Bearer …` and bare `Bearer …`.
    private func redactingBearerTokens(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            with: "Bearer \(Self.marker)",
            options: .regularExpression
        )
    }

    /// Three base64url segments separated by dots, starting with a JSON
    /// header — unambiguous enough to match without a label.
    private func redactingJSONWebTokens(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*"#,
            with: Self.marker,
            options: .regularExpression
        )
    }

    /// Everything after `?` in a URL. Query strings routinely carry tokens and
    /// identifiers, and no diagnostic needs them — the path and host are what
    /// make a log line useful.
    private func redactingURLQueries(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"([a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'?]+)\?[^\s"']*"#,
            with: "$1?\(Self.marker)",
            options: .regularExpression
        )
    }

    /// Truncates by **character**, never by byte or UTF-16 unit, so a
    /// multi-scalar grapheme (an emoji with a skin-tone modifier, a combining
    /// accent) can never be split into invalid output.
    private func truncating(_ value: String) -> String {
        guard value.count > Self.maximumLineLength else { return value }
        let suffix = "… <truncated>"
        let keep = max(0, Self.maximumLineLength - suffix.count)
        return String(value.prefix(keep)) + suffix
    }
}
