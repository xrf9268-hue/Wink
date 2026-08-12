import Foundation
import Testing
@testable import Wink

@Suite("Diagnostics redaction")
struct DiagnosticsRedactorTests {
    private func redactor(
        home: String = "/Users/alice",
        user: String = "alice"
    ) -> DiagnosticsRedactor {
        DiagnosticsRedactor(homeDirectoryPath: home, userName: user)
    }

    // MARK: - Home and user identity

    @Test
    func homePathsCollapseToTilde() {
        let line = redactor().redact(
            line: "Failed to load shortcuts: path=/Users/alice/Library/Application Support/Wink/shortcuts.json"
        )
        #expect(!line.contains("/Users/alice"))
        #expect(line.contains("~/Library/Application Support/Wink/shortcuts.json"))
    }

    @Test
    func aRelocatedHomeOutsideUsersIsStillCaught() {
        let redactor = DiagnosticsRedactor(homeDirectoryPath: "/Volumes/Home/alice", userName: "alice")
        let line = redactor.redact(line: "log at /Volumes/Home/alice/.config/Wink/debug.log")
        #expect(!line.contains("/Volumes/Home/alice"))
        #expect(line.contains("~/.config/Wink/debug.log"))
    }

    @Test
    func anotherAccountsHomePathIsAlsoCollapsed() {
        // A log can name a path that is not this user's home — a shared
        // volume, a copied file. It is still someone's identity.
        let line = redactor().redact(line: "read /Users/bob/Desktop/config.json")
        #expect(!line.contains("bob"))
        #expect(line.contains("~/Desktop/config.json"))
    }

    @Test
    func theUserNameIsRemovedOutsidePathsToo() {
        let line = redactor().redact(line: "activation requested by alice for com.apple.Safari")
        #expect(!line.lowercased().contains("alice"))
        #expect(line.contains("com.apple.Safari"))
    }

    @Test
    func aVeryShortUserNameIsNotMatchedInsideOrdinaryWords() {
        // "al" would otherwise redact "normal", "final", "signal"…
        let redactor = DiagnosticsRedactor(homeDirectoryPath: "/Users/al", userName: "al")
        let line = redactor.redact(line: "standard shortcuts ready, signal normal")
        #expect(line == "standard shortcuts ready, signal normal")
    }

    @Test
    func aVeryShortUserNameIsStillRedactedWhenItStandsAloneAsAToken() {
        // The length guard used to skip 1-2 character names entirely, which
        // let them straight through whenever they appeared as their own path
        // component, URL segment, or word rather than glued inside a longer
        // one.
        let redactor = DiagnosticsRedactor(homeDirectoryPath: "/Users/al", userName: "al")

        let path = redactor.redact(line: "reading /exports/al/report.json")
        #expect(!path.contains("/al/"))
        #expect(path.contains(DiagnosticsRedactor.marker))

        let word = redactor.redact(line: "shared by al in #general")
        #expect(!word.lowercased().contains(" al "))
        #expect(word.contains(DiagnosticsRedactor.marker))

        let query = redactor.redact(line: "invited user=al&role=admin")
        #expect(!query.contains("user=al&"))
        #expect(query.contains(DiagnosticsRedactor.marker))

        // But it still must not eat the letters out of an unrelated longer
        // word sitting right next to a boundary character.
        let embedded = redactor.redact(line: "/exports/normal/report.json")
        #expect(embedded == "/exports/normal/report.json")
    }

    @Test
    func anOrdinaryUserNameInsideACompoundTokenIsStillRedacted() {
        // The macOS default hostname is the user's own name plus a possessive
        // — `yvans-MacBook-Pro.local` — and tokens like `alice123` are the
        // name too. A boundary rule would skip both because a letter or digit
        // follows, so names of three or more characters keep the plain
        // substring match: for a redactor, a missed disclosure is worse than
        // eating a word that happened to contain one.
        let hostname = redactor().redact(line: "resolved host alices-MacBook-Pro.local")
        #expect(!hostname.lowercased().contains("alice"))
        #expect(hostname.contains(DiagnosticsRedactor.marker))

        let compound = redactor().redact(line: "backup volume alice123 mounted")
        #expect(!compound.lowercased().contains("alice"))
        #expect(compound.contains(DiagnosticsRedactor.marker))
    }

    @Test
    func aSingleCharacterUserNameIsRedactedOnlyAtTokenBoundaries() {
        let redactor = DiagnosticsRedactor(homeDirectoryPath: "/Users/a", userName: "a")

        let standalone = redactor.redact(line: "path=/tmp/a status=ok")
        #expect(!standalone.contains("/tmp/a "))
        #expect(standalone.contains(DiagnosticsRedactor.marker))

        let embedded = redactor.redact(line: "status=ready mode=auto")
        #expect(embedded == "status=ready mode=auto")
    }

    @Test
    func urlAuthorityCredentialsAreRedacted() {
        // handleURLs logs unrecognized URLs verbatim, and user-info is legal
        // authority syntax — the password must not survive into an export
        // whose preview promises passwords are removed.
        let both = redactor().redact(line: "unrecognized url: wink://bob:hunter2@focus/extra")
        #expect(!both.contains("hunter2"))
        #expect(!both.contains("bob"))
        #expect(both.contains("wink://\(DiagnosticsRedactor.marker)@focus/extra"))

        let userOnly = redactor().redact(line: "GET https://bob@example.com/path ok")
        #expect(userOnly.contains("https://\(DiagnosticsRedactor.marker)@example.com/path"))

        // A URL with no user-info is untouched, and a bare email address is
        // not an authority — no `://` precedes it.
        let plain = redactor().redact(line: "GET https://example.com/path from bob@example.com")
        #expect(plain == "GET https://example.com/path from bob@example.com")
    }

    @Test
    func opaqueURLQueriesAreRedactedToo() {
        // handleURLs logs rejected URLs verbatim, and `wink:unknown?…` is a
        // legal opaque form — no authority, no `//` — whose query carries the
        // same kind of payload the authority form's does.
        let opaque = redactor().redact(line: "unrecognized url: wink:unknown?email=bob@example.com")
        #expect(!opaque.contains("bob@example.com"))
        #expect(opaque.contains("wink:unknown?\(DiagnosticsRedactor.marker)"))

        // A prose colon never reaches the query rule: whatever sits between
        // `:` and `?` must be free of spaces.
        let prose = redactor().redact(line: "note: did the tap restart?")
        #expect(prose == "note: did the tap restart?")

        // The pre-query component can be EMPTY — `wink:?token=…` is a legal
        // hostless form, and its query is exactly as secret as any other's.
        let hostless = redactor().redact(line: "unrecognized url: wink:?token=secret123")
        #expect(!hostless.contains("secret123"))
        #expect(hostless.contains("wink:?\(DiagnosticsRedactor.marker)"))
    }

    @Test
    func multiWordUnquotedSecretsAreRedactedWhole() {
        // A passphrase is words. Stopping the unquoted value at the first
        // space redacted one word and exported the rest of the password.
        let line = redactor().redact(line: "password: correct horse battery staple")
        #expect(!line.contains("horse"))
        #expect(line.contains("password: \(DiagnosticsRedactor.marker)"))

        // Separators bound the value only when they introduce another
        // labeled field, so siblings survive…
        let bounded = redactor().redact(line: "token=abc123, retry=3")
        #expect(bounded.contains("token=\(DiagnosticsRedactor.marker), retry=3"))

        // …while a secret that merely CONTAINS punctuation is consumed
        // whole: `password=<redacted>,def` would disclose part of the
        // credential.
        let comma = redactor().redact(line: "password=abc,def")
        #expect(!comma.contains("def"))
        #expect(comma.contains("password=\(DiagnosticsRedactor.marker)"))
        let spaced = redactor().redact(line: "opened with password=abc, def; ghi status=ok")
        #expect(!spaced.contains("abc") && !spaced.contains("def") && !spaced.contains("ghi"))
        #expect(spaced.hasSuffix("status=ok"))

        // Closing punctuation follows the same rule: consumed inside a
        // secret, surviving when it genuinely delimits.
        let closer = redactor().redact(line: "password=abc)def")
        #expect(!closer.contains("def"))
        let delimited = redactor().redact(line: "(password=abc) status=ok")
        #expect(!delimited.contains("abc"))
        #expect(delimited.hasSuffix(") status=ok"))

        // A value that BEGINS with an unterminated quote or delimiter must
        // not fall through every arm unmatched.
        let unterminated = redactor().redact(line: #"logged password="hunter2"#)
        #expect(!unterminated.contains("hunter2"))
        let leadingComma = redactor().redact(line: "token=,abc,def")
        #expect(!leadingComma.contains("abc") && !leadingComma.contains("def"))
        // And a properly quoted value still takes the quoted arm, leaving
        // siblings outside the quotes untouched.
        let quoted = redactor().redact(line: #"password="a b" status=ok"#)
        #expect(!quoted.contains("a b"))
        #expect(quoted.hasSuffix("status=ok"))
    }

    @Test
    func compoundSecretLabelsAreRedacted() {
        // Real logs carry compound labels, not bare core words.
        let aws = redactor().redact(line: "AWS_SECRET_ACCESS_KEY=AKIA-SECRET-VALUE")
        #expect(!aws.contains("AKIA"))
        let header = redactor().redact(line: "x-api-key: sk-live-secret")
        #expect(!header.contains("sk-live"))
        let oauth = redactor().redact(line: "oauth_token=abcd1234")
        #expect(!oauth.contains("abcd1234"))

        // Affixes attach only through _ - . separators: an embedded core
        // inside an ordinary word must not fire.
        let design = redactor().redact(line: "design=modern layout")
        #expect(design == "design=modern layout")
        let author = redactor().redact(line: "author=someone else")
        #expect(author == "author=someone else")
        let session = redactor().redact(line: "usersession=42abc")
        #expect(session == "usersession=42abc")
    }

    @Test
    func camelCaseSecretLabelsAreRedacted() {
        // Real code logs camelCase credential labels; the non-alphanumeric
        // boundary alone cannot see them (the core is preceded by a letter).
        for line in [
            "accessToken=abc123",
            "refreshToken: abc123",
            "clientSecret=abc123",
            "myPassword=hunter2",
            "clientSecretKey=abc123",
        ] {
            let out = redactor().redact(line: line)
            #expect(!out.contains("abc123") && !out.contains("hunter2"), "leaked: \(line) → \(out)")
        }

        // A lowercase continuation is still not a boundary, and a camel word
        // that merely CONTAINS a core mid-word does not fire.
        #expect(redactor().redact(line: "usersession=42abc") == "usersession=42abc")
        #expect(redactor().redact(line: "reSign=on") == "reSign=on")

        // Acronym-prefixed forms: the core is preceded by an UPPERCASE
        // letter, which neither the non-alphanumeric boundary nor the
        // lowercase→uppercase seam can see.
        for line in ["clientIDToken=abc123", "JWTToken=abc123", "APIToken: abc123"] {
            let out = redactor().redact(line: line)
            #expect(!out.contains("abc123"), "leaked: \(line) → \(out)")
        }
    }

    @Test
    func spacedJWTHeadersAreStillRedacted() {
        // base64("{ \"") begins "eyA" — exactly as valid a JWT header as the
        // compact "eyJ" form.
        let line = redactor().redact(line: "jwt eyAiYWxnIjoiSFMyNTYifQ.eyJzdWIiOiIxIn0.c2ln done")
        #expect(!line.contains("eyAiYWxn"))
        #expect(line.contains(DiagnosticsRedactor.marker))
        #expect(line.hasSuffix("done"))
    }

    @Test
    func percentEncodedIdentitiesAreDecodedBeforeRedaction() {
        // handleURLs logs rejected URLs verbatim; %2FUsers%2Falice must not
        // hide the home path and account name from every rule.
        let line = redactor().redact(line: "unrecognized url: wink:open/%2FUsers%2Falice%2Fsecret.txt")
        #expect(!line.lowercased().contains("alice"))
        #expect(!line.contains("%2F"))
    }

    @Test
    func percentEncodedQuerySeparatorsDoNotSplitTheRedaction() {
        // %20 decodes to a space, and the query rule stops at whitespace —
        // so redacting only AFTER decoding would keep "?<redacted>" and leak
        // everything past the first decoded space. The URL rules run on the
        // raw line first, where the encoded query is one token.
        let line = redactor().redact(
            line: "unrecognized url: wink:unknown?email=Bob%20Smith%20%3Cbob@example.com%3E"
        )
        #expect(!line.contains("Smith"))
        #expect(!line.contains("bob@example.com"))
        #expect(line.contains("wink:unknown?\(DiagnosticsRedactor.marker)"))
    }

    @Test
    func aBarePercentElsewhereDoesNotDefeatTheDecode() {
        // removingPercentEncoding is all-or-nothing per string: one bare `%`
        // ("50%") used to keep every valid escape on the line encoded and
        // invisible to the rules. Escapes are decoded per RUN instead.
        let line = redactor().redact(line: "wink:open/%2FUsers%2Falice done: 50% complete")
        #expect(!line.lowercased().contains("alice"))
        #expect(line.contains("50% complete"))
    }

    @Test
    func separatorHeavyLinesRedactInLinearTime() {
        // The measured pathological shape: separator-heavy near-miss labels
        // made the old prefix group re-scan from every start position
        // (~130ms per 2,000-char line, near-quadratic). Asserted as a
        // SCALING RATIO rather than a wall-clock ceiling — absolute timings
        // flake under parallel test load, but 8× the input costing far more
        // than 8× the time is machine-independent evidence of superlinear
        // rescanning. Linear ≈ 8×, the old quadratic ≈ 64×; the bound leaves
        // room for noise on both sides.
        func measure(_ repeats: Int) -> TimeInterval {
            let line = String(repeating: "a.", count: repeats) + "signatureX zz"
            let redactor = redactor()
            _ = redactor.redact(line: line) // warm-up: regex compile
            let started = Date()
            for _ in 0..<3 { _ = redactor.redact(line: line) }
            return Date().timeIntervalSince(started)
        }
        let small = max(measure(500), 0.000_1)
        let large = measure(4_000)
        #expect(large / small < 24)
    }

    // MARK: - Secrets

    @Test
    func labelledSecretsAreRemovedButTheirKeysSurvive() {
        let cases = [
            "token=abc123def",
            "password: hunter2",
            #""apiKey": "sk-live-0000""#,
            "SECRET=shhh",
            "ed_signature=MEUCIQD",
        ]
        for input in cases {
            let output = redactor().redact(line: input)
            #expect(output.contains(DiagnosticsRedactor.marker), "not redacted: \(input)")
        }
        #expect(redactor().redact(line: "token=abc123def").hasPrefix("token="))
    }

    @Test
    func onlyTheValueIsRemovedAndTheRestOfTheLineSurvives() {
        let line = redactor().redact(line: "GET /feed token=abc123 status=200 route=hyper")
        #expect(!line.contains("abc123"))
        #expect(line.contains("status=200"))
        #expect(line.contains("route=hyper"))
    }

    @Test
    func bearerTokensAndJWTsAreRemoved() {
        let bearer = redactor().redact(line: "Authorization: Bearer abc.def-ghi_jkl")
        #expect(!bearer.contains("abc.def-ghi_jkl"))

        let jwt = redactor().redact(
            line: "sent eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        )
        #expect(!jwt.contains("eyJhbGciOiJIUzI1NiJ9"))
        #expect(jwt.contains(DiagnosticsRedactor.marker))
    }

    @Test
    func urlQueryStringsAreRemovedWhileTheEndpointSurvives() {
        let line = redactor().redact(line: "fetching https://updates.example.com/appcast.xml?token=abc&user=alice")
        #expect(!line.contains("token=abc"))
        #expect(!line.contains("user=alice"))
        #expect(line.contains("https://updates.example.com/appcast.xml"))
    }

    @Test
    func aURLWithoutAQueryIsUntouched() {
        let url = "https://updates.example.com/appcast.xml"
        #expect(redactor().redact(line: "fetching \(url)") == "fetching \(url)")
    }

    // MARK: - Deliberately kept

    @Test
    func bundleIdentifiersAndAppNamesSurvive() {
        // These are what make a report actionable. The export preview
        // discloses them instead of the redactor removing them.
        let line = redactor().redact(line: "MATCHED: Safari - com.apple.Safari route=standard")
        #expect(line.contains("com.apple.Safari"))
        #expect(line.contains("Safari"))
    }

    @Test
    func shortcutUUIDsSurvive() {
        let id = "11111111-2222-3333-4444-555555555555"
        #expect(redactor().redact(line: "deleted shortcut \(id)").contains(id))
    }

    // MARK: - Malformed and hostile input

    @Test
    func anOverlongLineIsTruncatedRatherThanDropped() {
        let long = String(repeating: "A", count: 10_000)
        let output = redactor().redact(line: "prefix \(long)")

        #expect(output.count <= DiagnosticsRedactor.maximumLineLength)
        #expect(output.hasPrefix("prefix "))
        #expect(output.hasSuffix("<truncated>"))
    }

    @Test
    func redactionNeverGrowsItsInput() {
        // A redactor that can be made to expand its input is a denial of
        // service on the export path.
        let inputs = [
            "token=" + String(repeating: "x", count: 500),
            String(repeating: "https://a/b?c ", count: 200),
            String(repeating: "password: p ", count: 300),
        ]
        for input in inputs {
            #expect(redactor().redact(line: input).count <= max(input.count, DiagnosticsRedactor.maximumLineLength))
        }
    }

    @Test
    func unicodeSurvivesAndGraphemesAreNeverSplit() {
        let line = "启动完成 ✅ 快捷键就绪 👨‍👩‍👧‍👦 café"
        #expect(redactor().redact(line: line) == line)

        // Truncation must land on a grapheme boundary: rebuilding the string
        // from the output must round-trip through UTF-8 unchanged.
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 1_000)
        let truncated = redactor().redact(line: family)
        let roundTripped = String(decoding: Array(truncated.utf8), as: UTF8.self)
        #expect(roundTripped == truncated)
        #expect(!truncated.unicodeScalars.contains { $0 == "\u{FFFD}" })
    }

    @Test
    func emptyAndWhitespaceOnlyInputIsHandled() {
        #expect(redactor().redact(line: "") == "")
        #expect(redactor().redact(line: "   ") == "   ")
        #expect(redactor().redact(text: "") == "")
    }

    @Test
    func documentRedactionPreservesLineCountIncludingBlankLines() {
        let text = "a\n\nb\n"
        let output = redactor().redact(text: text)
        #expect(output.split(separator: "\n", omittingEmptySubsequences: false).count
            == text.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    @Test
    func redactionIsDeterministic() {
        // The export claims to be deterministic; that is only true if this is.
        let line = "path=/Users/alice/x token=abc https://h/p?q=1 by alice"
        let first = redactor().redact(line: line)
        for _ in 0..<50 {
            #expect(redactor().redact(line: line) == first)
        }
    }

    @Test
    func redactingAlreadyRedactedTextIsStable() {
        // Export previews render the redacted text; re-running the redactor on
        // its own output must not cascade.
        let once = redactor().redact(line: "path=/Users/alice/x token=abc")
        #expect(redactor().redact(line: once) == once)
    }
}
