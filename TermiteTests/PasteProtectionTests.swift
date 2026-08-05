import SwiftTerm
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

final class SearchActivationTests: XCTestCase {

    /// 搜索激活期间关 allowMouseReporting(防输出清选区)并换高对比选区色;关闭全部还原
    @MainActor
    func testActivateAndCloseRestoreTerminalState() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let originalColor = view.selectedTextBackgroundColor
        view.allowMouseReporting = true

        let model = TerminalSearchModel()
        model.terminalView = view
        model.activate()
        XCTAssertFalse(view.allowMouseReporting)
        XCTAssertNotEqual(view.selectedTextBackgroundColor, originalColor)

        // 重复激活不覆盖暂存值
        model.activate()

        model.close()
        XCTAssertTrue(view.allowMouseReporting)
        XCTAssertEqual(view.selectedTextBackgroundColor, originalColor)
    }
}

final class ClipboardImagePasteTests: XCTestCase {

    func testTiffOnClipboardSavedAsPng() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let pb = NSPasteboard(name: NSPasteboard.Name("termite.test.image"))
        pb.clearContents()
        pb.setData(try XCTUnwrap(image.tiffRepresentation), forType: .tiff)

        let path = try XCTUnwrap(TermiteTerminalView.saveClipboardImage(pb))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(path.hasSuffix(".png"))
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path))
        XCTAssertEqual([UInt8](data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testEmptyClipboardReturnsNil() {
        let pb = NSPasteboard(name: NSPasteboard.Name("termite.test.empty"))
        pb.clearContents()
        XCTAssertNil(TermiteTerminalView.saveClipboardImage(pb))
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
