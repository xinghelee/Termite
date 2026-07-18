import XCTest
@testable import Termite

final class LineDiffTests: XCTestCase {

    func testIdenticalIsAllSame() {
        let lines = ["a", "b", "c"]
        let ops = LineDiff.diff(old: lines, new: lines)
        XCTAssertEqual(ops, [.same("a"), .same("b"), .same("c")])
        let stats = LineDiff.stats(ops)
        XCTAssertEqual(stats.added, 0)
        XCTAssertEqual(stats.removed, 0)
    }

    func testPureAddition() {
        let ops = LineDiff.diff(old: ["a", "c"], new: ["a", "b", "c"])
        XCTAssertEqual(ops, [.same("a"), .added("b"), .same("c")])
    }

    func testPureRemoval() {
        let ops = LineDiff.diff(old: ["a", "b", "c"], new: ["a", "c"])
        XCTAssertEqual(ops, [.same("a"), .removed("b"), .same("c")])
    }

    func testChangedLine() {
        let ops = LineDiff.diff(old: ["pod-1 Running", "pod-2 Pending"], new: ["pod-1 Running", "pod-2 Running"])
        XCTAssertEqual(LineDiff.stats(ops).added, 1)
        XCTAssertEqual(LineDiff.stats(ops).removed, 1)
        XCTAssertTrue(ops.contains(.removed("pod-2 Pending")))
        XCTAssertTrue(ops.contains(.added("pod-2 Running")))
    }

    func testEmptySides() {
        XCTAssertEqual(LineDiff.diff(old: [], new: ["x"]), [.added("x")])
        XCTAssertEqual(LineDiff.diff(old: ["x"], new: []), [.removed("x")])
        XCTAssertEqual(LineDiff.diff(old: [], new: []), [])
    }

    func testPrefixSuffixStripKeepsOrder() {
        let old = ["h1", "h2", "old", "t1"]
        let new = ["h1", "h2", "new1", "new2", "t1"]
        let ops = LineDiff.diff(old: old, new: new)
        XCTAssertEqual(ops.first, .same("h1"))
        XCTAssertEqual(ops.last, .same("t1"))
        XCTAssertEqual(LineDiff.stats(ops).added, 2)
        XCTAssertEqual(LineDiff.stats(ops).removed, 1)
    }
}

final class FrecencyTests: XCTestCase {

    func testRecentBeatsFrequentButStale() {
        // 1 次但刚访问 > 10 次但一个月没去
        let fresh = DirectoryHistory.frecencyScore(visits: 1, ageSeconds: 60)
        let stale = DirectoryHistory.frecencyScore(visits: 10, ageSeconds: 40 * 86_400)
        XCTAssertGreaterThan(fresh, stale)
    }

    func testMoreVisitsWinAtSameAge() {
        let few = DirectoryHistory.frecencyScore(visits: 2, ageSeconds: 100)
        let many = DirectoryHistory.frecencyScore(visits: 8, ageSeconds: 100)
        XCTAssertGreaterThan(many, few)
    }

    func testWeightBuckets() {
        XCTAssertEqual(DirectoryHistory.frecencyScore(visits: 1, ageSeconds: 100), 4)
        XCTAssertEqual(DirectoryHistory.frecencyScore(visits: 1, ageSeconds: 7200), 2)
        XCTAssertEqual(DirectoryHistory.frecencyScore(visits: 1, ageSeconds: 2 * 86_400), 1)
        XCTAssertEqual(DirectoryHistory.frecencyScore(visits: 4, ageSeconds: 30 * 86_400), 1)
    }
}
