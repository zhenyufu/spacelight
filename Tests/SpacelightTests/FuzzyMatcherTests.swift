import Testing
@testable import Spacelight

@Suite struct FuzzyMatcherTests {
    @Test func emptyQueryMatchesEverythingWithZeroScore() throws {
        #expect(FuzzyMatcher.score(query: "", haystack: "anything") == 0)
    }

    @Test func emptyHaystackNeverMatchesNonEmptyQuery() throws {
        #expect(FuzzyMatcher.score(query: "x", haystack: "") == nil)
    }

    @Test func requiresAllQueryCharactersInOrder() throws {
        #expect(FuzzyMatcher.score(query: "dev", haystack: "dev") != nil)
        #expect(FuzzyMatcher.score(query: "dev", haystack: "developer") != nil)
        // "d", "e", "v" appear, but not in order (v comes before e in "vader").
        #expect(FuzzyMatcher.score(query: "dev", haystack: "vader") == nil)
        #expect(FuzzyMatcher.score(query: "xyz", haystack: "dev") == nil)
    }

    @Test func isCaseInsensitiveButHaystackStaysUsableForBoundaryDetection() throws {
        // Query is lowercased by convention (as StateStore will do); haystack keeps mixed case.
        let lower = FuzzyMatcher.score(query: "chrome", haystack: "Google Chrome")
        #expect(lower != nil)
    }

    @Test func contiguousMatchScoresHigherThanScattered() throws {
        // "chr" is contiguous in "Chrome" but scattered across "Configure Hardware Report".
        let contiguous = try #require(FuzzyMatcher.score(query: "chr", haystack: "Chrome"))
        let scattered = try #require(FuzzyMatcher.score(query: "chr", haystack: "Configure Hardware Report"))
        #expect(contiguous > scattered)
    }

    @Test func wordBoundaryMatchScoresHigherThanMidWordMatch() throws {
        // "de" starts "Developer Tools" (boundary) vs. sitting mid-word in "Wide Menu".
        let atBoundary = try #require(FuzzyMatcher.score(query: "de", haystack: "Developer Tools"))
        let midWord = try #require(FuzzyMatcher.score(query: "de", haystack: "Wide Menu"))
        #expect(atBoundary > midWord)
    }

    @Test func camelCaseBoundaryIsDetectedOnOriginalCaseHaystack() throws {
        // "sp" hits the camelCase boundary in "aeroSpace"; scores higher than an equivalent
        // mid-word, non-boundary occurrence of the same two letters in "grasping".
        let camelBoundary = try #require(FuzzyMatcher.score(query: "sp", haystack: "aeroSpace"))
        let midWord = try #require(FuzzyMatcher.score(query: "sp", haystack: "grasping"))
        #expect(camelBoundary > midWord)
    }

    @Test func matchAtStartOfHaystackScoresHigherThanMatchFurtherIn() throws {
        let atStart = try #require(FuzzyMatcher.score(query: "term", haystack: "Terminal"))
        let furtherIn = try #require(FuzzyMatcher.score(query: "term", haystack: "Long Terminal Title"))
        #expect(atStart > furtherIn)
    }

    @Test func rankingMatchesExpectedOrderForRealQueries() throws {
        // Mirrors PLAN.md's verification scenario: "dev" should rank the "dev" workspace itself
        // above an unrelated window that merely happens to contain the letters d, e, v in order.
        let items: [(name: String, haystack: String)] = [
            ("dev workspace", "dev"),
            ("unrelated window", "Google Doc Viewer"), // d...e...v in order, but scattered
        ]
        let scored = items.compactMap { item -> (String, Int)? in
            guard let s = FuzzyMatcher.score(query: "dev", haystack: item.haystack) else { return nil }
            return (item.name, s)
        }.sorted { $0.1 > $1.1 }

        #expect(scored.first?.0 == "dev workspace")
    }
}
