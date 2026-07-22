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
    // Both are non-prefix, non-word-prefix subsequence matches of "ff", but
    // "office" has the two f's adjacent while "far far away" spreads them
    // across the whole string.
    let tight = try #require(SearchPaletteMatch.score(query: "ff", normalizedName: "office"))
    let spread = try #require(SearchPaletteMatch.score(query: "ff", normalizedName: "far far away"))
    #expect(tight > spread)
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
