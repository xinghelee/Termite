import XCTest
import SwiftTerm
@testable import Termite

/// 文本输入经 NSTextInputClient 进入终端时，shell 元字符必须按 UTF-8 原样送往 PTY。
/// 这覆盖粘贴、输入法上屏及辅助输入工具常走的 insertText 路径。
@MainActor
final class SpecialCharacterInputTests: XCTestCase {

    private final class InputRecorder: TerminalViewDelegate {
        var bytes: [UInt8] = []

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            bytes.append(contentsOf: data)
        }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    func testInsertTextPreservesShellMetacharacters() {
        let view = TermiteTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let recorder = InputRecorder()
        view.terminalDelegate = recorder

        let input = #"printf '%s\n' "中文 > \"$TERM\" | cat && echo \\\$HOME; <>()[]{}!"#
        view.insertText(input as NSString,
                        replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(recorder.bytes, Array(input.utf8))
    }
}
