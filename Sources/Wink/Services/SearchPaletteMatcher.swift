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
/// cleaner corpus than the window titles AltTab's scorer handles). Four
/// tiers, highest first: exact name match, prefix match, a later word's
/// prefix match (e.g. "code" hitting "Visual Studio Code"), and general
/// in-order subsequence match. A contiguous substring is a special case of
/// "in order" — so `localizedName` containment (the IME note in the issue:
/// v1 matches a fully-composed CJK app name via containment) falls out of
/// the subsequence tier for free, with no separate containment check
/// needed.
enum SearchPaletteMatch {
    private static let exactScore = 1_000
    private static let prefixBaseScore = 900
    private static let wordPrefixScore = 700
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
        if let spread = subsequenceSpread(query: normalizedQuery, candidate: normalizedName) {
            // Tighter, earlier matches score higher within the tier — a
            // contiguous substring match (spread == matchedLength - 1) sits
            // at the top of this tier.
            return subsequenceBaseScore - min(spread, 400)
        }
        return nil
    }

    /// Whether every character of `query` appears in `candidate` in order
    /// (not necessarily contiguous). Returns the index distance between the
    /// first and last matched character — 0 means every matched character
    /// was adjacent (a contiguous substring, the exact "localizedName
    /// containment" case the issue's IME note calls out) — or `nil` when
    /// `query` isn't a subsequence of `candidate` at all.
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
}
