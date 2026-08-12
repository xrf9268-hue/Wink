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
    /// case-insensitively against `key=value`, `key: value`, and `"key": "…"`
    /// — and against COMPOUND labels: real logs carry `AWS_SECRET_ACCESS_KEY`
    /// and `x-api-key`, not the bare core word. Affixes attach only through
    /// `_ - .` separators, so `design=` cannot smuggle `sig` and `author=`
    /// cannot smuggle `auth`.
    private static let sensitiveKeyCores = [
        "password", "passwd", "secret", "token", "api[_-]?key",
        "auth", "credential", "private[_-]?key",
        "session", "signature", "sig",
    ]

    /// One alternation with attached suffixes only. There is no prefix
    /// group, deliberately twice over: the boundary assertions already admit
    /// a core mid-compound (`AWS_SECRET_…` matches AT `SECRET`, preceded by
    /// `_`; `clientSecret=` matches AT `Secret`, on the camel boundary),
    /// with the unmatched affix simply staying put in the output while the
    /// value is what gets replaced — and a prefix group was the measured
    /// quadratic hot spot (~130ms per 2,000-char `a.a.a.…signatureX=` line,
    /// re-scanned greedily from every start position).
    ///
    /// Boundaries: a non-alphanumeric neighbor, a lowercase→uppercase camel
    /// seam (`clientSecret`), an acronym seam — uppercase followed by an
    /// uppercase-then-lowercase word start (`clientIDToken`, `JWTToken`,
    /// `APIToken`) — or a digit→uppercase seam (`oauth2Token`, `s3Secret`),
    /// since versioned prefixes put a numeral right before the camel word. The seam assertions live in `(?-i:…)` because the
    /// pattern is applied case-insensitively, and under `(?i)` the classes
    /// `[a-z]`/`[A-Z]` both match every letter — the seams would degenerate
    /// to "any two letters" and `usersession=` would fire from `session`.
    /// Suffixes attach through `_ - .` separators or camel words, all
    /// possessive — an iteration that matched never needs giving back, since
    /// the `[:=]` tail cannot overlap either arm's first character.
    private static let sensitiveKeyPattern =
        #"(?:(?<![A-Za-z0-9])|(?-i:(?<=[a-z])(?=[A-Z]))|(?-i:(?<=[A-Z])(?=[A-Z][a-z]))|(?-i:(?<=[0-9])(?=[A-Z][a-z])))(?:"#
        + sensitiveKeyCores.joined(separator: "|")
        + #")(?:[_.-][A-Za-z0-9]++|(?-i:[A-Z][a-z0-9]*+))*+"#

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
        // The log writer flattens embedded separators before composing a
        // record, but `debug.log` and its rotated backup can still hold
        // records written by builds that predate that rule. An embedded
        // carriage return (or U+2028-class separator) survives the `\n`
        // split above this call yet stops `.` and `$`, which would silently
        // disable the to-end-of-line URL rules on exactly the lines that
        // need them — so legacy separators are flattened here rather than
        // trusting the writer's contract. One-for-one replacement (`\r\n`
        // is a single `Character`), so the output never grows.
        var value = line.contains(where: { $0.isNewline || $0 == "\0" })
            ? String(line.map { $0.isNewline || $0 == "\0" ? " " : $0 })
            : line
        // Percent-encoding is a disclosure vector here, not fidelity to
        // protect: `handleURLs` logs rejected URLs verbatim, and
        // `%2FUsers%2Falice` hides the home path from every rule below. One
        // decode pass covers the accidental case (a legitimately encoded URL
        // in the log); decode LOOPS are out of scope — an adversary crafting
        // log content to survive one decode already writes to the log and
        // owns the machine. Decoded per RUN of escapes, not per line:
        // `removingPercentEncoding` is all-or-nothing, so one bare `%`
        // elsewhere in the line — `?progress=50%` — would keep every valid
        // escape encoded and defeat the pass. Decoded newlines and NULs
        // flatten to spaces so an embedded %0A cannot fake extra lines.
        // Decoding never grows the string.
        // URL rules run on the RAW line first. The decode pass below turns
        // %20 into literal spaces, and the query rule stops at whitespace —
        // so a percent-encoded query (`?email=Bob%20Smith%20…`) redacted
        // only after decoding would leak everything past the first decoded
        // space. On the encoded form the query is one whitespace-free token
        // and is consumed whole. Both rules run again post-decode for URLs
        // that were themselves entirely percent-encoded.
        value = redactingURLQueries(value)
        value = redactingURLUserInfo(value)
        if value.contains("%") {
            if let regex = try? NSRegularExpression(pattern: #"(?:%[0-9A-Fa-f]{2})+"#) {
                let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed()
                for match in matches {
                    guard let range = Range(match.range, in: value) else { continue }
                    guard let decoded = String(value[range]).removingPercentEncoding else { continue }
                    let flattened = String(decoded.map { $0.isNewline || $0 == "\0" ? " " : $0 })
                    value.replaceSubrange(range, with: flattened)
                }
            }
        }
        value = redactingHomePaths(value)
        value = redactingLabelledSecrets(value)
        value = redactingBearerTokens(value)
        value = redactingJSONWebTokens(value)
        value = redactingURLQueries(value)
        value = redactingURLUserInfo(value)
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
    /// Two strategies by length, because the failure directions differ. A
    /// name of three or more characters is redacted as a plain substring,
    /// maximum recall: the name buried inside a compound token is still the
    /// user's name — `yvans-MacBook-Pro.local`, `yvan123` — and for a
    /// redactor a missed disclosure is worse than redacting a word that
    /// happened to contain one. A 1–2 character name cannot use that rule
    /// ("al" is inside "signal", "normal", "already" — the output would be
    /// noise), so it is matched at token boundaries instead: caught when it
    /// stands alone as a path component, URL segment, or log token (`/al/`,
    /// `by al `, `user=al&`), never when it is merely part of a longer word.
    /// Skipping short names entirely — the previous rule — left them
    /// disclosed even standing alone, despite the preview's unconditional
    /// claim that the username is removed.
    private func redactingUserName(_ value: String) -> String {
        guard !userName.isEmpty else { return value }
        let escaped = NSRegularExpression.escapedPattern(for: userName)
        let pattern = userName.count >= 3
            ? escaped
            : #"(?<![A-Za-z0-9])\#(escaped)(?![A-Za-z0-9])"#
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
        // key=value / key: value / "key": "value". A PROPERLY quoted value
        // takes the quoted arms — which are escape-aware: `"abc\"def"` must
        // close at the final quote, not at the escaped one, or the tail of
        // the credential walks out of the match. A value that merely BEGINS
        // with an
        // unterminated quote or another delimiter — `password="hunter2` —
        // matches none of them without the leading delimiter run on the
        // unquoted arm (greedy, deliberately not possessive: it must be able
        // to give characters back so the first real chunk can match).
        // The unquoted arm then consumes the first token, and each further
        // chunk — across
        // spaces, commas, semicolons, closing brackets, and quotes alike —
        // only when it does not itself look like a `key=`/`key:` label.
        // Every fixed-boundary choice had a counterexample: stopping at the
        // first space exported most of `password: correct horse battery
        // staple`, stopping at punctuation exported `,def` and `)def`, and
        // consuming everything ate the `status=200 route=hyper` fields that
        // make a log line worth reading. A secret is chunks; a sibling
        // field is a label; the lookahead tells them apart — and a closer
        // that genuinely delimits (`(password=abc) status=ok`) survives
        // because the lookahead stops the match before consuming it. All
        // possessive — the match ends at the value, so nothing ever needs
        // giving back.
        let pattern = #"(?i)("?\#(Self.sensitiveKeyPattern)"?\s*[:=]\s*)("(?:\\.|[^"\\])*+"(?!["'])|'(?:\\.|[^'\\])*+'(?!["'])|[,;)}\]"']*[^\s,;)}\]"']++(?:[\s,;)}\]"']++(?![\w.-]+\s*[:=])[^\s,;)}\]"']++)*+|[,;)}\]"']++)"#
        value = value.replacingOccurrences(
            of: pattern,
            with: "$1\(Self.marker)",
            options: .regularExpression
        )
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
    /// header — unambiguous enough to match without a label. `ey[JA]`, not
    /// just `eyJ`: base64("{\"") is "eyJ", but a header serialized with a
    /// space — `{ "alg"…` — encodes to "eyA" and is exactly as valid a JWT.
    private func redactingJSONWebTokens(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"\bey[JA][A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*"#,
            with: Self.marker,
            options: .regularExpression
        )
    }

    /// `scheme://user:password@host` — the authority's user-info component.
    /// Query strings are not the only URL component that carries credentials:
    /// an unrecognized `wink://` URL is logged verbatim by `handleURLs`, and
    /// user-info is structurally unambiguous (between `://` and a pre-path
    /// `@`), so it is redacted wholesale — the password and the user name
    /// with it, since a name in an authority is identifying even when it is
    /// not this account's. The host stays: it is what makes the line useful.
    private func redactingURLUserInfo(_ value: String) -> String {
        // The scheme quantifier is BOUNDED and possessive: an unbounded
        // `[a-zA-Z0-9+.-]*` consumes a whole separator-heavy line at every
        // scan position before failing on `:`, which is quadratic in line
        // length (measured on `a.a.a.…` probe lines). Real schemes are a
        // handful of characters; 64 is generous headroom.
        // Everything from `://` to the LINE's last `@`. Structural
        // precision lost this fight in stages: a DECODED value can put
        // `@`s, `/`s, literal SPACES, and QUOTES inside what was user-info
        // (`user:p@ss@host`, `user:p/secret@host`, `user:p secret@host`,
        // `user:p"secret@host`), and any boundary short of the final `@`
        // exported part of a password. No character class bounds the region
        // anymore — every exclusion so far has become a bypass, so the rule
        // consumes unconditionally. The over-redaction cost is contained by
        // ordering and domain: the query rule runs FIRST (a legitimate
        // `?next=a@b.com` is already inside the query marker before this
        // rule looks), and the URL in this log's lines is the final element
        // — so the remaining price, prose after a query-less URL being
        // folded into the marker when an `@` follows, lands on rare lines
        // and in the cheap direction.
        value.replacingOccurrences(
            of: #"([a-zA-Z][a-zA-Z0-9+.-]{0,64}+://).*@"#,
            with: "$1\(Self.marker)@",
            options: .regularExpression
        )
    }

    /// Everything after `?` in a URL. Query strings routinely carry tokens and
    /// identifiers, and no diagnostic needs them — the path and host are what
    /// make a log line useful. The authority (`//`) is optional and so is the
    /// pre-query component itself: `wink:unknown?email=…` and the fully
    /// hostless `wink:?token=…` are both legal URLs, `handleURLs` logs
    /// rejected ones verbatim, and their queries carry the same kind of
    /// payload. A prose colon still does not slip in — whatever sits between
    /// `:` and `?` must be free of spaces — and over-redacting the rare
    /// `ratio:3?x` token is the cheap direction for a redactor to be wrong in.
    private func redactingURLQueries(_ value: String) -> String {
        // Scheme bounded and possessive for the same quadratic-scan reason
        // as the user-info rule above. The query consumes TO END OF LINE:
        // the primary vector is handleURLs logging a DECODED URL as the
        // line's final element, where the query legally contains spaces
        // (`?email=Bob Smith <bob@…>`) and any whitespace boundary exports
        // its tail. A URL mid-prose over-redacts what follows — the cheap
        // direction — and a second URL on the same line is simply consumed
        // into the same marker. The pre-query region crosses QUOTES: a
        // decoded path can legally hold one (`/a"b?email=…`), and a quote
        // boundary here disabled the rule on exactly those lines. Only
        // whitespace still bounds it — that is what keeps a prose colon
        // (`note: done? yes`) from arming the rule mid-sentence.
        value.replacingOccurrences(
            of: #"([a-zA-Z][a-zA-Z0-9+.-]{0,64}+:(?://)?[^\s?]*)\?.*$"#,
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
