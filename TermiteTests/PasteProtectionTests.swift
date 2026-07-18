import XCTest
@testable import Termite

final class PasteProtectionTests: XCTestCase {

    func testMultilineNeedsConfirmation() {
        XCTAssertTrue(TermiteTerminalView.needsConfirmation("ls\nrm x"))
    }

    func testDangerousCommandsNeedConfirmation() {
        XCTAssertTrue(TermiteTerminalView.needsConfirmation("rm -rf /tmp/x"))
        XCTAssertTrue(TermiteTerminalView.needsConfirmation("sudo shutdown -h now"))
        XCTAssertTrue(TermiteTerminalView.needsConfirmation("dd if=/dev/zero of=/dev/sda"))
    }

    func testPlainCommandPassesThrough() {
        XCTAssertFalse(TermiteTerminalView.needsConfirmation("ls -la"))
        XCTAssertFalse(TermiteTerminalView.needsConfirmation("git status"))
    }

    func testPreviewTruncates() {
        let text = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let preview = TermiteTerminalView.preview(text)
        XCTAssertTrue(preview.contains("…"))
        XCTAssertTrue(preview.contains("30"))
    }
}

final class CompactTitleTests: XCTestCase {

    @MainActor
    func testUserHostPathCompactsToLastDir() {
        XCTAssertEqual(TerminalSession.compactTitle("zc@MacBook-Pro:/Volumes/CodeVault/xc/heng8"), "heng8")
        XCTAssertEqual(TerminalSession.compactTitle("zc@MacBook-Pro:~"), "~")
    }

    @MainActor
    func testPlainPathCompacts() {
        XCTAssertEqual(TerminalSession.compactTitle("~/Developer/vibe/Termite"), "Termite")
        XCTAssertEqual(TerminalSession.compactTitle("/"), "/")
    }

    @MainActor
    func testProgramTitleKeptVerbatim() {
        XCTAssertEqual(TerminalSession.compactTitle("vim README.md"), "vim README.md")
        XCTAssertEqual(TerminalSession.compactTitle("htop"), "htop")
    }
}
