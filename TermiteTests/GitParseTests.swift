import XCTest
@testable import Termite

final class GitParseTests: XCTestCase {

    func testPorcelainV2Basic() {
        let text = """
        # branch.oid abc
        # branch.head main
        1 .M N... 100644 100644 100644 h1 h2 Sources/App.swift
        1 M. N... 100644 100644 100644 h1 h2 README.md
        1 MM N... 100644 100644 100644 h1 h2 Both.swift
        ? Untracked File.txt
        """
        let snapshot = GitParse.porcelainV2(text)
        XCTAssertEqual(snapshot.unstaged.map(\.path).sorted(), ["Both.swift", "Sources/App.swift"])
        XCTAssertEqual(snapshot.staged.map(\.path).sorted(), ["Both.swift", "README.md"])
        XCTAssertEqual(snapshot.untracked.map(\.path), ["Untracked File.txt"])
        XCTAssertEqual(snapshot.totalCount, 5)
    }

    func testPorcelainV2Rename() {
        let text = "2 R. N... 100644 100644 100644 h1 h2 R100 new/name.swift\told/name.swift"
        let snapshot = GitParse.porcelainV2(text)
        XCTAssertEqual(snapshot.staged.first?.path, "new/name.swift")
        XCTAssertEqual(snapshot.staged.first?.statusCode, "R")
    }

    func testNumstat() {
        let counts = GitParse.numstat("12\t3\tSources/App.swift\n-\t-\tImage.png\n")
        XCTAssertEqual(counts["Sources/App.swift"]?.added, 12)
        XCTAssertEqual(counts["Sources/App.swift"]?.removed, 3)
        XCTAssertEqual(counts["Image.png"]?.added, 0)
    }

    func testLog() {
        let commits = GitParse.log("abc123\tzc\t2 hours ago\tfix: something\tweird\n")
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].hash, "abc123")
        XCTAssertEqual(commits[0].subject, "fix: something\tweird")
    }

    func testNameStatusRename() {
        let entries = GitParse.nameStatus("M\ta.swift\nR100\told.swift\tnew.swift\n")
        XCTAssertEqual(entries[0].code, "M")
        XCTAssertEqual(entries[0].path, "a.swift")
        XCTAssertEqual(entries[1].code, "R")
        XCTAssertEqual(entries[1].path, "new.swift")
    }
}

final class UnifiedDiffTests: XCTestCase {

    private let sample = """
    diff --git a/file.swift b/file.swift
    index abc..def 100644
    --- a/file.swift
    +++ b/file.swift
    @@ -10,4 +10,5 @@ func demo() {
     context1
    -removed line
    +added line 1
    +added line 2
     context2
    """

    func testParseHunk() {
        let hunks = UnifiedDiff.parse(sample)
        XCTAssertEqual(hunks.count, 1)
        let hunk = hunks[0]
        XCTAssertEqual(hunk.oldStart, 10)
        XCTAssertEqual(hunk.newStart, 10)
        XCTAssertEqual(hunk.header, "func demo() {")
        XCTAssertEqual(hunk.lines.count, 5)
    }

    func testLineNumbers() {
        let lines = UnifiedDiff.parse(sample)[0].lines
        // context1: old 10 / new 10
        XCTAssertEqual(lines[0].oldNumber, 10)
        XCTAssertEqual(lines[0].newNumber, 10)
        // removed: old 11, new nil
        XCTAssertEqual(lines[1].kind, .removed)
        XCTAssertEqual(lines[1].oldNumber, 11)
        XCTAssertNil(lines[1].newNumber)
        // added 1: new 11
        XCTAssertEqual(lines[2].kind, .added)
        XCTAssertEqual(lines[2].newNumber, 11)
        // context2: old 12 / new 13
        XCTAssertEqual(lines[4].oldNumber, 12)
        XCTAssertEqual(lines[4].newNumber, 13)
    }

    func testStats() {
        let stats = UnifiedDiff.stats(UnifiedDiff.parse(sample))
        XCTAssertEqual(stats.added, 2)
        XCTAssertEqual(stats.removed, 1)
    }

    func testMultipleHunksAndNoNewlineMarker() {
        let text = """
        @@ -1,2 +1,2 @@
        -a
        +b
         c
        @@ -9,1 +9,1 @@
        -x
        +y
        \\ No newline at end of file
        """
        let hunks = UnifiedDiff.parse(text)
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[1].oldStart, 9)
        XCTAssertEqual(UnifiedDiff.stats(hunks).added, 2)
    }
}

final class GitGraphTests: XCTestCase {

    private func commit(_ hash: String, parents: [String], refs: [String] = []) -> GraphCommitInfo {
        GraphCommitInfo(hash: hash, shortHash: hash, parents: parents, author: "a", relativeDate: "now", refs: refs, subject: "s")
    }

    func testLinearHistorySingleLane() {
        let rows = GitGraph.computeRows([
            commit("c", parents: ["b"]),
            commit("b", parents: ["a"]),
            commit("a", parents: []),
        ])
        XCTAssertEqual(rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(rows.map(\.laneCount), [1, 1, 1])
        XCTAssertFalse(rows[0].hasTopLine)
        XCTAssertTrue(rows[1].hasTopLine)
        XCTAssertTrue(rows[0].continuesDown)
        XCTAssertFalse(rows[2].continuesDown)
    }

    func testMergeCommitOpensSecondLane() {
        // m 是 merge(父 a、b);a、b 各自是根
        let rows = GitGraph.computeRows([
            commit("m", parents: ["a", "b"]),
            commit("b", parents: []),
            commit("a", parents: []),
        ])
        // m 在 0 道,第二父 b 分出到 1 道
        XCTAssertEqual(rows[0].lane, 0)
        XCTAssertEqual(rows[0].branchesOut, [1])
        XCTAssertEqual(rows[0].laneCount, 2)
        // b 落在 1 道且上方有来线
        let rowB = rows.first { $0.commit.hash == "b" }!
        XCTAssertEqual(rowB.lane, 1)
        XCTAssertTrue(rowB.hasTopLine)
        // a 在 0 道
        let rowA = rows.first { $0.commit.hash == "a" }!
        XCTAssertEqual(rowA.lane, 0)
    }

    func testBranchTipJoinsExistingLane() {
        // 两个分支顶端(t1、t2)都指向同一父 p:t2 的首父已被 0 道跟踪 → 并入
        let rows = GitGraph.computeRows([
            commit("t1", parents: ["p"]),
            commit("t2", parents: ["p"]),
            commit("p", parents: []),
        ])
        let rowT2 = rows[1]
        XCTAssertEqual(rowT2.lane, 1)
        XCTAssertEqual(rowT2.branchesOut, [0])
        XCTAssertFalse(rowT2.continuesDown)
        // p 收到两条线,单泳道
        let rowP = rows[2]
        XCTAssertEqual(rowP.lane, 0)
        XCTAssertTrue(rowP.hasTopLine)
    }

    func testParseLogRefs() {
        let line = "abc\u{1f}abc\u{1f}p1 p2\u{1f}zc\u{1f}2 天前\u{1f}HEAD -> main, origin/main, tag: v1.0\u{1f}subject here"
        let commits = GitGraph.parseLog(line)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].parents, ["p1", "p2"])
        XCTAssertEqual(commits[0].refs, ["HEAD -> main", "origin/main", "tag: v1.0"])
        XCTAssertEqual(commits[0].subject, "subject here")
    }
}
