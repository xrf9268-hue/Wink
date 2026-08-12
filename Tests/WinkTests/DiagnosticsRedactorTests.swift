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
