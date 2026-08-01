import XCTest
@testable import Termite

final class FileLinkDetectorTests: XCTestCase {

    // MARK: - 通用格式

    func testCompilerErrorWithLineAndColumn() {
        let text = "/Users/x/app/src/main.swift:42:7: error: cannot find 'foo'"
        let match = FileLinkDetector.match(in: text, column: 5)
        XCTAssertEqual(match?.path, "/Users/x/app/src/main.swift")
        XCTAssertEqual(match?.line, 42)
        XCTAssertEqual(match?.column, 7)
    }

    func testRelativePathWithLine() {
        let text = "  --> src/main.rs:12:5"
        let match = FileLinkDetector.match(in: text, column: 8)
        XCTAssertEqual(match?.path, "src/main.rs")
        XCTAssertEqual(match?.line, 12)
    }

    func testBareFileNameWithExtensionNoLine() {
        let match = FileLinkDetector.match(in: "modified: README.md", column: 12)
        XCTAssertEqual(match?.path, "README.md")
        XCTAssertNil(match?.line)
    }

    func testClickOnLineNumberPartStillHits() {
        let text = "src/app.ts:33"
        let match = FileLinkDetector.match(in: text, column: 12)
        XCTAssertEqual(match?.path, "src/app.ts")
        XCTAssertEqual(match?.line, 33)
    }

    func testTildePath() {
        let match = FileLinkDetector.match(in: "cat ~/notes/todo.md", column: 8)
        XCTAssertEqual(match?.path, "~/notes/todo.md")
    }

    // MARK: - Python traceback

    func testPythonTraceback() {
        let text = "  File \"/app/server.py\", line 88, in handle"
        let match = FileLinkDetector.match(in: text, column: 10)
        XCTAssertEqual(match?.path, "/app/server.py")
        XCTAssertEqual(match?.line, 88)
    }

    // MARK: - 命中测试

    func testClickOutsideTokenMisses() {
        let text = "error at src/main.rs:12"
        XCTAssertNil(FileLinkDetector.match(in: text, column: 2))
    }

    func testCJKPrefixShiftsColumns() {
        // 「编译失败」占 8 列(4 个宽字符),路径从第 9 列(含空格)后开始
        let text = "编译失败 src/main.swift:7"
        XCTAssertEqual(FileLinkDetector.match(in: text, column: 10)?.path, "src/main.swift")
        XCTAssertNil(FileLinkDetector.match(in: text, column: 3)?.line)
    }

    // MARK: - 误报过滤

    func testPlainWordsRejected() {
        XCTAssertNil(FileLinkDetector.match(in: "hello world", column: 2))
    }

    func testVersionNumberRejected() {
        XCTAssertNil(FileLinkDetector.match(in: "python 3.14 ready", column: 8))
    }

    func testIPAddressRejected() {
        XCTAssertNil(FileLinkDetector.match(in: "listening on 127.0.0.1:8080", column: 16))
    }

    func testTrailingPeriodStripped() {
        let match = FileLinkDetector.match(in: "see src/config.yaml.", column: 8)
        XCTAssertEqual(match?.path, "src/config.yaml")
    }

    // MARK: - resolve

    func testResolveRelativeAgainstCwd() {
        let match = FileLinkDetector.Match(path: "src/main.rs", line: 1, column: nil, columns: 0..<1)
        let resolved = FileLinkDetector.resolve(match, cwd: "/repo") { $0 == "/repo/src/main.rs" }
        XCTAssertEqual(resolved, "/repo/src/main.rs")
    }

    func testResolveMissingFileReturnsNil() {
        let match = FileLinkDetector.Match(path: "src/main.rs", line: nil, column: nil, columns: 0..<1)
        XCTAssertNil(FileLinkDetector.resolve(match, cwd: "/repo") { _ in false })
    }

    func testResolveRelativeWithoutCwdReturnsNil() {
        let match = FileLinkDetector.Match(path: "src/main.rs", line: nil, column: nil, columns: 0..<1)
        XCTAssertNil(FileLinkDetector.resolve(match, cwd: nil) { _ in true })
    }

    func testResolveStandardizesDotSegments() {
        let match = FileLinkDetector.Match(path: "./src/../src/main.rs", line: nil, column: nil, columns: 0..<1)
        let resolved = FileLinkDetector.resolve(match, cwd: "/repo") { $0 == "/repo/src/main.rs" }
        XCTAssertEqual(resolved, "/repo/src/main.rs")
    }
}
