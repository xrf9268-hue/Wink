import Foundation

/// One row candidate for the #356 search-to-switch palette. Built once per
/// palette open (`SearchPaletteCandidateBuilder.build`) from the already-warm
/// `AppListProvider` snapshot, never per keystroke — the per-keystroke cost
/// is only `SearchPaletteRanking.rank` scoring against this precomputed
/// array, which is what keeps typing latency structurally bounded (see
/// `SearchPaletteHUD.swift`).
struct SearchPaletteCandidate: Identifiable, Equatable {
    let entry: AppEntry
    /// Lowercased once at build time so every keystroke's re-scoring never
    /// repeats the same `.lowercased()` work across the whole app list.
    let normalizedName: String
    /// Display text for a bound, enabled, real-app shortcut targeting this
    /// bundle (#356 constraint: "bound apps show their keycap"). `nil` when
    /// no such shortcut exists.
    let keycap: String?
    let isRunning: Bool

    var id: String { entry.bundleIdentifier }
}

enum SearchPaletteCandidateBuilder {
    /// - Parameters:
    ///   - apps: `AppListProvider.allApps` — installed + running, already
    ///     the #356 scope (installed/running apps only, no window/file
    ///     enumeration).
    ///   - shortcuts: the full shortcut store; pseudo-targets (frontmost-app,
    ///     the palette trigger itself) never contribute a keycap since they
    ///     don't target a real app.
    ///   - runningBundleIdentifiers: a workspace snapshot taken once at open
    ///     time, not re-queried per keystroke.
    static func build(
        apps: [AppEntry],
        shortcuts: [AppShortcut],
        runningBundleIdentifiers: Set<String>
    ) -> [SearchPaletteCandidate] {
        var keycapByBundleIdentifier: [String: String] = [:]
        for shortcut in shortcuts
        where shortcut.isEnabled && !shortcut.isFrontmostAppTarget && !shortcut.isSearchPaletteTarget {
            keycapByBundleIdentifier[shortcut.bundleIdentifier] = ModifierFormatting.displayText(
                modifierFlags: shortcut.modifierFlags,
                keyEquivalent: shortcut.keyEquivalent
            )
        }

        return apps.map { entry in
            SearchPaletteCandidate(
                entry: entry,
                normalizedName: entry.name.lowercased(),
                keycap: keycapByBundleIdentifier[entry.bundleIdentifier],
                isRunning: runningBundleIdentifiers.contains(entry.bundleIdentifier)
            )
        }
    }
}

/// Tiered prefix/subsequence scoring — deliberately NOT a multi-layer
/// edit-distance waterfall (#356 hard constraint: app names are a much
/// cleaner corpus than the window titles AltTab's scorer handles). Five
/// tiers, highest first: exact name match, prefix match, a later word's
/// prefix match (e.g. "code" hitting "Visual Studio Code"), any contiguous
/// substring match anywhere in the name (the IME note in the issue: v1
/// matches a fully-composed CJK app name via `localizedName` containment),
/// and general in-order subsequence match as the fallback tier. The
/// contiguous-substring tier is explicit and separate from the subsequence
/// one on purpose: the subsequence scan below is a cheap greedy
/// leftmost-anchor match (not a tightest-window search — that would start
/// creeping toward the edit-distance waterfall the issue rules out), so it
/// can anchor an early, spread-out match instead of recognizing a genuine
/// contiguous substring elsewhere in the name (e.g. query "ab" against "a
/// fab" — greedily anchoring the standalone "a" produces a wider spread
/// than the actual contiguous "ab" at the end). Checking `contains` first
/// guarantees a real substring always outranks a non-contiguous subsequence
/// match, regardless of what the greedy scan below would have produced.
enum SearchPaletteMatch {
    private static let exactScore = 1_000
    private static let prefixBaseScore = 900
    private static let wordPrefixScore = 700
    private static let containsScore = 600
    private static let subsequenceBaseScore = 500

    /// - Parameters:
    ///   - query: already trimmed; case folding happens here.
    ///   - normalizedName: `SearchPaletteCandidate.normalizedName` (already
    ///     lowercased, so this call does zero per-row lowercasing work).
    /// - Returns: a score where higher ranks better, or `nil` for no match.
    static func score(query: String, normalizedName: String) -> Int? {
        guard !query.isEmpty else { return nil }
        let normalizedQuery = query.lowercased()

        if normalizedName == normalizedQuery {
            return exactScore
        }
        if normalizedName.hasPrefix(normalizedQuery) {
            // Shorter names score a touch higher for the same prefix (a more
            // specific match), bounded so this tier can never cross into the
            // exact-match score.
            let extraLength = normalizedName.count - normalizedQuery.count
            return prefixBaseScore - min(extraLength, 100)
        }
        if normalizedName.split(separator: " ").contains(where: { $0.hasPrefix(normalizedQuery) }) {
            return wordPrefixScore
        }
        if normalizedName.contains(normalizedQuery) {
            return containsScore
        }
        if let spread = subsequenceSpread(query: normalizedQuery, candidate: normalizedName) {
            // Tighter, earlier matches score higher within the tier.
            return subsequenceBaseScore - min(spread, 400)
        }
        return nil
    }

    /// Whether every character of `query` appears in `candidate` in order
    /// (not necessarily contiguous) — the fallback tier once a contiguous
    /// substring match (checked above, and always preferred) doesn't apply.
    /// Returns the index distance between the first and last matched
    /// character, or `nil` when `query` isn't a subsequence of `candidate`
    /// at all.
    private static func subsequenceSpread(query: String, candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        var queryIndex = query.startIndex
        var firstMatchedPosition: Int?
        var lastMatchedPosition = 0

        for (position, character) in candidate.enumerated() {
            guard queryIndex < query.endIndex else { break }
            if character == query[queryIndex] {
                if firstMatchedPosition == nil {
                    firstMatchedPosition = position
                }
                lastMatchedPosition = position
                queryIndex = query.index(after: queryIndex)
            }
        }

        guard queryIndex == query.endIndex, let firstMatchedPosition else {
            return nil
        }
        return lastMatchedPosition - firstMatchedPosition
    }
}

enum SearchPaletteRanking {
    /// Bounds the palette's result list (also bounds its panel height —
    /// #352's "bounded height" pattern, structurally rather than via a
    /// scroll view since this cap makes an unbounded list impossible).
    static let defaultLimit = 8

    /// Scores every candidate, drops non-matches, and returns the top
    /// `limit` sorted by score (descending) then localized name (ascending)
    /// for a deterministic tie-break. An empty query returns no results —
    /// the palette shows a small recents list for that case instead (see
    /// `SearchPaletteHUD.swift`), not a scored ranking.
    static func rank(
        query: String,
        candidates: [SearchPaletteCandidate],
        limit: Int = defaultLimit
    ) -> [SearchPaletteCandidate] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let scored: [(candidate: SearchPaletteCandidate, score: Int)] = candidates.compactMap { candidate in
            guard let score = SearchPaletteMatch.score(query: trimmedQuery, normalizedName: candidate.normalizedName) else {
                return nil
            }
            return (candidate, score)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.candidate.entry.name.localizedCaseInsensitiveCompare(rhs.candidate.entry.name) == .orderedAscending
            }
            .prefix(limit)
            .map(\.candidate)
    }

    /// Empty-query default (Spotlight/Alfred convention: "what can I switch
    /// to right now"). Most recently activated running apps first, using
    /// `AppListProvider.recentBundleIDs`; running apps with no recency
    /// signal at all (never activated through Wink) fall back to
    /// alphabetical order at the tail. Never includes non-running apps —
    /// an empty query with nothing typed yet shouldn't suggest launching
    /// something.
    static func recentRunning(
        candidates: [SearchPaletteCandidate],
        recentBundleIdentifiers: [String],
        limit: Int = defaultLimit
    ) -> [SearchPaletteCandidate] {
        let running = candidates.filter(\.isRunning)
        guard !running.isEmpty else { return [] }

        let runningByBundleIdentifier = Dictionary(
            running.map { ($0.entry.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var ordered: [SearchPaletteCandidate] = []
        var seenBundleIdentifiers = Set<String>()
        for bundleIdentifier in recentBundleIdentifiers {
            guard let candidate = runningByBundleIdentifier[bundleIdentifier],
                  !seenBundleIdentifiers.contains(bundleIdentifier) else { continue }
            ordered.append(candidate)
            seenBundleIdentifiers.insert(bundleIdentifier)
        }

        let remaining = running
            .filter { !seenBundleIdentifiers.contains($0.entry.bundleIdentifier) }
            .sorted { $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending }
        ordered.append(contentsOf: remaining)

        return Array(ordered.prefix(limit))
    }
}
