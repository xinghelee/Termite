import XCTest
import SwiftTerm
@testable import Termite

final class InputModeTrackerTests: XCTestCase {
    private func bytes(_ s: String) -> ArraySlice<UInt8> { ArraySlice(Array(s.utf8)) }

    func testScanTracksFocusAndSGRMouse() {
        var tracker = InputModeTracker()
        tracker.scan(bytes("hello\u{1b}[?2004h\u{1b}[?1004hworld\u{1b}[?1006h"))
        XCTAssertTrue(tracker.focusReporting)
        XCTAssertTrue(tracker.sgrMouse)
        tracker.scan(bytes("\u{1b}[?1004l"))
        XCTAssertFalse(tracker.focusReporting)
        XCTAssertTrue(tracker.sgrMouse)
    }

    func testDefaultsProduceNoPreamble() {
        XCTAssertNil(InputModeTracker.preamble(kittyFlags: 0, bracketedPaste: false, applicationCursor: false,
                                               mouseMode: .off, focusReporting: false, sgrMouse: true))
    }

    /// Claude Code 的启动序列:断开前拍快照 → 新 Terminal 灌回后,模式与原来一致
    func testRoundTripRestoresClaudeCodeModes() throws {
        let original = Terminal(delegate: NullDelegate())
        var tracker = InputModeTracker()
        let startup = bytes("\u{1b}[?2004h\u{1b}[?1004h\u{1b}[<u\u{1b}[>5u\u{1b}[>4;2m")
        original.feed(buffer: startup)
        tracker.scan(startup)
        let preamble = try XCTUnwrap(tracker.preamble(for: original))

        let restored = Terminal(delegate: NullDelegate())
        restored.feed(text: preamble)
        XCTAssertEqual(restored.keyboardEnhancementFlags.rawValue, 5)
        XCTAssertTrue(restored.bracketedPasteMode)
        XCTAssertEqual(preamble, "\u{1b}[?2004h\u{1b}[?1004h\u{1b}[>5u")
    }
}

private final class NullDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
