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
