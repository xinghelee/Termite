import XCTest
@testable import Termite

final class OSC133ScannerTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testPromptStartBEL() {
        var scanner = OSC133Scanner()
        let input = bytes("\u{1b}]133;A\u{07}")
        let events = scanner.scan(input[...])
        XCTAssertEqual(events.count, 1)
        guard case .promptStart = events[0].event else { return XCTFail("expected promptStart") }
        XCTAssertEqual(events[0].offset, input.count)
    }

    func testCommandEndWithCodeST() {
        var scanner = OSC133Scanner()
        let input = bytes("\u{1b}]133;D;23\u{1b}\\")
        let events = scanner.scan(input[...])
        XCTAssertEqual(events.count, 1)
        guard case .commandEnd(let code) = events[0].event else { return XCTFail("expected commandEnd") }
        XCTAssertEqual(code, 23)
    }

    func testSplitAcrossChunks() {
        var scanner = OSC133Scanner()
        let part1 = bytes("hello \u{1b}]13")
        let part2 = bytes("3;C\u{07} world")
        XCTAssertTrue(scanner.scan(part1[...]).isEmpty)
        let events = scanner.scan(part2[...])
        XCTAssertEqual(events.count, 1)
        guard case .outputStart = events[0].event else { return XCTFail("expected outputStart") }
        // 偏移应指向终止符(BEL)之后一位:"3;C\u{07}" 结束于索引 4
        XCTAssertEqual(events[0].offset, 4)
    }

    func testMultipleEventsInOneChunk() {
        var scanner = OSC133Scanner()
        let input = bytes("\u{1b}]133;D;0\u{07}\u{1b}]133;A\u{07}$ ")
        let events = scanner.scan(input[...])
        XCTAssertEqual(events.count, 2)
        guard case .commandEnd(let code) = events[0].event else { return XCTFail() }
        XCTAssertEqual(code, 0)
        guard case .promptStart = events[1].event else { return XCTFail() }
    }

    func testIgnoresOtherOSC() {
        var scanner = OSC133Scanner()
        let input = bytes("\u{1b}]2;title\u{07}plain text")
        XCTAssertTrue(scanner.scan(input[...]).isEmpty)
    }

    func testCommandEndWithoutCode() {
        var scanner = OSC133Scanner()
        let input = bytes("\u{1b}]133;D\u{07}")
        let events = scanner.scan(input[...])
        XCTAssertEqual(events.count, 1)
        guard case .commandEnd(let code) = events[0].event else { return XCTFail() }
        XCTAssertNil(code)
    }
}
