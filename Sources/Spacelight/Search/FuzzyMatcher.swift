import Foundation

/// A self-contained subsequence fuzzy matcher in the spirit of fzf's v1 algorithm: every character
/// of the query must appear in the haystack in order (not necessarily contiguously), and the score
/// rewards matches that are contiguous, that land at a word/camelCase boundary, or that start at
/// the very beginning of the haystack.
///
/// Pure and allocation-light by design: `SwitcherItem.searchHaystack` is already lowercased once
/// at snapshot time, so `score` never lowercases or copies the haystack itself.
enum FuzzyMatcher {
    private enum Score {
        static let matchedChar = 16
        static let consecutiveBonus = 15
        static let boundaryBonus = 12
        static let startOfStringBonus = 20
        static let gapPenaltyPerChar = 2
    }

    /// Returns nil if `query`'s characters don't all appear in `haystack` in order.
    ///
    /// `query` must already be lowercased by the caller (callers hold one lowercased copy of the
    /// live text field value per keystroke rather than paying for it per item). `haystack` must
    /// stay in its **original** case: matching is done per-character case-insensitively below, so
    /// that the boundary bonus can still see real case transitions (e.g. "aeroSpace") to detect
    /// camelCase boundaries. A haystack that arrived pre-lowercased would silently disable that
    /// bonus, since `current.isUppercase` could never be true.
    static func score(query: String, haystack: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        guard !haystack.isEmpty else { return nil }

        let queryChars = Array(query)
        let hayChars = Array(haystack)

        var queryIndex = 0
        var total = 0
        var lastMatchIndex = -1
        var firstMatchIndex = -1

        var hayIndex = 0
        while hayIndex < hayChars.count && queryIndex < queryChars.count {
            if caseInsensitiveEquals(hayChars[hayIndex], queryChars[queryIndex]) {
                if firstMatchIndex == -1 { firstMatchIndex = hayIndex }

                var charScore = Score.matchedChar
                if lastMatchIndex == hayIndex - 1 {
                    charScore += Score.consecutiveBonus
                } else if lastMatchIndex >= 0 {
                    let gap = hayIndex - lastMatchIndex - 1
                    charScore -= min(gap * Score.gapPenaltyPerChar, Score.matchedChar - 1)
                }
                if isBoundary(hayChars, at: hayIndex) {
                    charScore += Score.boundaryBonus
                }

                total += charScore
                lastMatchIndex = hayIndex
                queryIndex += 1
            }
            hayIndex += 1
        }

        guard queryIndex == queryChars.count else { return nil }

        if firstMatchIndex == 0 {
            total += Score.startOfStringBonus
        }

        return total
    }

    /// True if `index` starts a "word": the very start of the string, right after whitespace or
    /// punctuation, or a lowercase-to-uppercase transition (camelCase).
    private static func isBoundary(_ chars: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = chars[index - 1]
        if previous.isWhitespace || previous.isPunctuation {
            return true
        }
        let current = chars[index]
        if previous.isLowercase && current.isUppercase {
            return true
        }
        return false
    }

    /// Single-character case folding, cheap enough to do per comparison during the scan rather
    /// than precomputing a second lowercased copy of every haystack (which would destroy the case
    /// information `isBoundary` needs). `Character.lowercased()` returns a `String` because a few
    /// Unicode characters case-fold to more than one character; comparing those Strings is still
    /// far cheaper than the full-string allocation a precomputed lowercase haystack would cost.
    private static func caseInsensitiveEquals(_ a: Character, _ b: Character) -> Bool {
        a == b || a.lowercased() == b.lowercased()
    }
}
