import Foundation
import Testing
@testable import Wink

private func entry(_ name: String, _ bundleIdentifier: String? = nil) -> AppEntry {
    AppEntry(
        id: bundleIdentifier ?? "com.example.\(name.lowercased())",
        name: name,
        url: URL(fileURLWithPath: "/Applications/\(name).app")
    )
}

private func candidate(
    _ name: String,
    bundleIdentifier: String? = nil,
    keycap: String? = nil,
    isRunning: Bool = false
) -> SearchPaletteCandidate {
    let appEntry = entry(name, bundleIdentifier)
    return SearchPaletteCandidate(
        entry: appEntry,
        normalizedName: appEntry.name.lowercased(),
        keycap: keycap,
        isRunning: isRunning
    )
}

// MARK: - Tiered scoring

@Test func exactMatchOutranksEveryOtherTier() throws {
    let exact = try #require(SearchPaletteMatch.score(query: "Safari", normalizedName: "safari"))
    let prefix = try #require(SearchPaletteMatch.score(query: "Saf", normalizedName: "safari"))
    #expect(exact > prefix)
}

@Test func prefixMatchOutranksWordPrefixMatch() throws {
    let prefix = try #require(SearchPaletteMatch.score(query: "vis", normalizedName: "visual studio code"))
    let wordPrefix = try #require(SearchPaletteMatch.score(query: "code", normalizedName: "visual studio code"))
    #expect(prefix > wordPrefix)
}

@Test func wordPrefixMatchOutranksGeneralSubsequenceMatch() throws {
    let wordPrefix = try #require(SearchPaletteMatch.score(query: "code", normalizedName: "visual studio code"))
    // "vsc" is a subsequence of "visual studio code" but matches no whole
    // word's start, so it can only land in the lowest tier.
    let subsequence = try #require(SearchPaletteMatch.score(query: "vsc", normalizedName: "visual studio code"))
    #expect(wordPrefix > subsequence)
}

@Test func nonMatchingQueryReturnsNil() {
    #expect(SearchPaletteMatch.score(query: "xyz123", normalizedName: "safari") == nil)
}

@Test func outOfOrderCharactersDoNotMatchAsASubsequence() {
    // "fri" reversed against "safari" ("i","r","f") is not in-order.
    #expect(SearchPaletteMatch.score(query: "irf", normalizedName: "safari") == nil)
}

@Test func scoringIsCaseInsensitive() throws {
    let lower = try #require(SearchPaletteMatch.score(query: "saf", normalizedName: "safari"))
    let upper = try #require(SearchPaletteMatch.score(query: "SAF", normalizedName: "safari"))
    #expect(lower == upper)
}

@Test func emptyQueryNeverMatches() {
    #expect(SearchPaletteMatch.score(query: "", normalizedName: "safari") == nil)
}

/// #356's IME note: v1 matches a fully-composed CJK app name via
/// `localizedName` containment. A contiguous substring is a special case of
/// "in order", so this needs no separate containment branch in the scorer.
@Test func containedSubstringMatchesIncludingCJKNames() throws {
    #expect(SearchPaletteMatch.score(query: "信", normalizedName: "微信") != nil)
    #expect(SearchPaletteMatch.score(query: "微信", normalizedName: "微信") == 1_000)
}

@Test func tighterSubsequenceMatchScoresHigherThanASpreadOutOne() throws {
    // Both are non-prefix, non-word-prefix, non-contiguous-substring
    // matches of "acd" — "abcd" has the matched characters close together
    // (one letter between them) while "a b c d" spreads them across the
    // whole string. Neither candidate contains "acd" as a literal
    // substring, so both land in the subsequence tier and this isolates its
    // tightness-based sub-ordering from the contains tier.
    let tight = try #require(SearchPaletteMatch.score(query: "acd", normalizedName: "abcd"))
    let spread = try #require(SearchPaletteMatch.score(query: "acd", normalizedName: "a b c d"))
    #expect(tight > spread)
}

/// #356 regression: a greedy leftmost subsequence scan can anchor an early,
/// spread-out match instead of recognizing a genuine contiguous substring
/// elsewhere in the name — query "ab" against "a fab" would otherwise
/// anchor the standalone "a" (position 0) and miss the tighter "ab" at the
/// end, scoring below a candidate where "ab" is merely a spread-out
/// subsequence. The explicit contains tier must outrank that regardless.
@Test func containsTierAlwaysOutranksANonContiguousSubsequenceMatch() throws {
    let containsMatch = try #require(SearchPaletteMatch.score(query: "ab", normalizedName: "a fab"))
    let subsequenceOnlyMatch = try #require(SearchPaletteMatch.score(query: "ab", normalizedName: "axb"))
    #expect(containsMatch > subsequenceOnlyMatch)
}

@Test func containsTierOutranksSubsequenceButNotWordPrefix() throws {
    let wordPrefix = try #require(SearchPaletteMatch.score(query: "code", normalizedName: "visual studio code"))
    // "tudio" is a substring of "studio" but not a prefix of any word (the
    // word itself starts with "s"), so it isolates the contains tier from
    // the word-prefix tier above it.
    let contains = try #require(SearchPaletteMatch.score(query: "tudio", normalizedName: "visual studio code"))
    #expect(wordPrefix > contains)
}

// MARK: - Ranking

@Test func rankingExcludesNonMatchesAndOrdersByScoreDescending() {
    let candidates = [
        candidate("Terminal"),
        candidate("Safari"),
        candidate("Xcode"),
    ]
    let results = SearchPaletteRanking.rank(query: "Safari", candidates: candidates)
    #expect(results.map(\.entry.name) == ["Safari"])
}

@Test func rankingBreaksScoreTiesAlphabetically() {
    // Both are pure prefix matches of "s" at the same extra-length tier
    // boundary handling — use two names of equal length so the score
    // formula ties exactly, then confirm the alphabetical tie-break.
    let candidates = [
        candidate("Sun"),
        candidate("Sky"),
    ]
    let results = SearchPaletteRanking.rank(query: "s", candidates: candidates)
    #expect(results.map(\.entry.name) == ["Sky", "Sun"])
}

@Test func rankingRespectsTheResultLimit() {
    let candidates = (0..<20).map { candidate("App\($0)") }
    let results = SearchPaletteRanking.rank(query: "App", candidates: candidates, limit: 5)
    #expect(results.count == 5)
}

@Test func emptyQueryRanksToNoResults() {
    let candidates = [candidate("Safari")]
    #expect(SearchPaletteRanking.rank(query: "   ", candidates: candidates).isEmpty)
}

// MARK: - Candidate building

@Test func candidateBuilderAttachesKeycapOnlyForEnabledRealAppShortcuts() {
    let apps = [entry("Safari", "com.apple.Safari"), entry("Terminal", "com.apple.Terminal")]
    let shortcuts = [
        AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command", "shift"]
        ),
        AppShortcut(
            appName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            keyEquivalent: "t",
            modifierFlags: ["command"],
            isEnabled: false
        ),
    ]

    let candidates = SearchPaletteCandidateBuilder.build(
        apps: apps,
        shortcuts: shortcuts,
        runningBundleIdentifiers: []
    )

    let safari = candidates.first { $0.entry.bundleIdentifier == "com.apple.Safari" }
    let terminal = candidates.first { $0.entry.bundleIdentifier == "com.apple.Terminal" }
    #expect(safari?.keycap == "⌘⇧S")
    // Disabled shortcuts never surface a keycap — they aren't live bindings.
    #expect(terminal?.keycap == nil)
}

@Test func candidateBuilderNeverAttachesAKeycapFromAPseudoTargetShortcut() {
    let apps = [entry("Safari", "com.apple.Safari")]
    // A pseudo-target shortcut is excluded by its `target`, not by which
    // bundle it happens to carry — bind it to Safari's real bundle id to
    // prove that.
    let shortcuts = [
        AppShortcut(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            keyEquivalent: "s",
            modifierFlags: ["command"],
            target: .frontmostApp
        ),
    ]

    let candidates = SearchPaletteCandidateBuilder.build(
        apps: apps,
        shortcuts: shortcuts,
        runningBundleIdentifiers: []
    )

    #expect(candidates.first?.keycap == nil)
}

@Test func candidateBuilderPropagatesRunningState() {
    let apps = [entry("Safari", "com.apple.Safari"), entry("Terminal", "com.apple.Terminal")]
    let candidates = SearchPaletteCandidateBuilder.build(
        apps: apps,
        shortcuts: [],
        runningBundleIdentifiers: ["com.apple.Safari"]
    )

    #expect(candidates.first { $0.entry.bundleIdentifier == "com.apple.Safari" }?.isRunning == true)
    #expect(candidates.first { $0.entry.bundleIdentifier == "com.apple.Terminal" }?.isRunning == false)
}

// MARK: - Empty-query recency ordering (#356 P3-11)

@Test func recentRunningOrdersByRecencyMostRecentFirst() {
    let candidates = [
        candidate("Safari", bundleIdentifier: "com.apple.Safari", isRunning: true),
        candidate("Terminal", bundleIdentifier: "com.apple.Terminal", isRunning: true),
        candidate("Xcode", bundleIdentifier: "com.apple.Xcode", isRunning: true),
    ]

    let results = SearchPaletteRanking.recentRunning(
        candidates: candidates,
        recentBundleIdentifiers: ["com.apple.Xcode", "com.apple.Safari", "com.apple.Terminal"]
    )

    #expect(results.map(\.entry.bundleIdentifier) == ["com.apple.Xcode", "com.apple.Safari", "com.apple.Terminal"])
}

@Test func recentRunningFallsBackToAlphabeticalForRunningAppsWithNoRecencySignal() {
    let candidates = [
        candidate("Zephyr", bundleIdentifier: "com.example.Zephyr", isRunning: true),
        candidate("Anchor", bundleIdentifier: "com.example.Anchor", isRunning: true),
        candidate("Safari", bundleIdentifier: "com.apple.Safari", isRunning: true),
    ]

    // Only Safari has a recency signal; the other two running apps (never
    // activated through Wink) fall back to alphabetical order at the tail.
    let results = SearchPaletteRanking.recentRunning(
        candidates: candidates,
        recentBundleIdentifiers: ["com.apple.Safari"]
    )

    #expect(results.map(\.entry.name) == ["Safari", "Anchor", "Zephyr"])
}

@Test func recentRunningExcludesNonRunningApps() {
    let candidates = [
        candidate("Safari", bundleIdentifier: "com.apple.Safari", isRunning: true),
        candidate("Terminal", bundleIdentifier: "com.apple.Terminal", isRunning: false),
    ]

    let results = SearchPaletteRanking.recentRunning(
        candidates: candidates,
        recentBundleIdentifiers: ["com.apple.Terminal", "com.apple.Safari"]
    )

    #expect(results.map(\.entry.bundleIdentifier) == ["com.apple.Safari"])
}

@Test func recentRunningIgnoresStaleRecentEntriesNotCurrentlyRunning() {
    // A bundle can be "recent" (previously activated) without being running
    // right now — a stale recent id that isn't in the running set must not
    // produce a missing/duplicate row.
    let candidates = [
        candidate("Safari", bundleIdentifier: "com.apple.Safari", isRunning: true),
    ]

    let results = SearchPaletteRanking.recentRunning(
        candidates: candidates,
        recentBundleIdentifiers: ["com.apple.QuitApp", "com.apple.Safari"]
    )

    #expect(results.map(\.entry.bundleIdentifier) == ["com.apple.Safari"])
}

@Test func recentRunningRespectsTheLimit() {
    let candidates = (0..<20).map { candidate("App\($0)", bundleIdentifier: "com.example.app\($0)", isRunning: true) }
    let results = SearchPaletteRanking.recentRunning(
        candidates: candidates,
        recentBundleIdentifiers: [],
        limit: 5
    )
    #expect(results.count == 5)
}

// MARK: - Structural latency guard

/// Not a strict SLA (wall-clock assertions in CI are inherently noisy) —
/// this is a coarse regression canary confirming the per-keystroke ranking
/// cost stays a cheap in-memory scan even against a candidate list far
/// larger than any real Mac's installed-app count, with a bound generous
/// enough to absorb slow CI hosts without flaking.
@Test func rankingStaysCheapAgainstALargeCandidateList() {
    let candidates = (0..<2_000).map { candidate("Application Number \($0)") }
    let start = Date()
    _ = SearchPaletteRanking.rank(query: "Application Number 1234", candidates: candidates)
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 0.5)
}
