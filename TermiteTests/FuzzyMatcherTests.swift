import XCTest
@testable import Termite

final class FuzzyMatcherTests: XCTestCase {

    func testExactBeatsPrefix() {
        let exact = FuzzyMatcher.score(query: "tab", candidate: "tab")!
        let prefix = FuzzyMatcher.score(query: "tab", candidate: "table")!
        XCTAssertGreaterThan(exact, prefix)
    }

    func testPrefixBeatsContains() {
        let prefix = FuzzyMatcher.score(query: "spl", candidate: "split")!
        let contains = FuzzyMatcher.score(query: "spl", candidate: "resplit")!
        XCTAssertGreaterThan(prefix, contains)
    }

    func testContainsBeatsSubsequence() {
        let contains = FuzzyMatcher.score(query: "term", candidate: "quickterm")!
        let subsequence = FuzzyMatcher.score(query: "term", candidate: "the extra mile")!
        XCTAssertGreaterThan(contains, subsequence)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(FuzzyMatcher.score(query: "xyz", candidate: "terminal"))
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatcher.score(query: "SPLIT", candidate: "split"))
    }

    func testBestScoreAcrossFields() {
        let best = FuzzyMatcher.bestScore(query: "theme", fields: [nil, "主题", "theme picker"])
        XCTAssertNotNil(best)
    }
}
