import XCTest
@testable import Termite

/// IME 组词期间隐藏块光标(TermiteTerminalView 对 SwiftTerm CaretView 的显隐控制)
@MainActor
final class IMECaretTests: XCTestCase {

    private func makeView() -> TermiteTerminalView {
        TermiteTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    private func caret(in view: TermiteTerminalView) -> NSView? {
        view.subviews.first { String(describing: type(of: $0)) == "CaretView" }
    }

    private func setMarked(_ text: String, on view: TermiteTerminalView) {
        view.setMarkedText(text as NSString,
                           selectedRange: NSRange(location: text.count, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func testCaretHiddenDuringCompositionAndRestoredAfter() {
        let view = makeView()
        XCTAssertNotNil(caret(in: view), "初始应有 caret 视图")
        XCTAssertEqual(caret(in: view)?.isHidden, false)

        setMarked("hai shi", on: view)
        XCTAssertEqual(caret(in: view)?.isHidden, true, "组词中 caret 应隐藏")

        view.insertText("还是" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(caret(in: view)?.isHidden, false, "上屏后 caret 应恢复")
    }

    func testUnmarkRestoresCaret() {
        let view = makeView()
        setMarked("yi ge", on: view)
        XCTAssertEqual(caret(in: view)?.isHidden, true)
        view.unmarkText()
        XCTAssertEqual(caret(in: view)?.isHidden, false, "取消组词后 caret 应恢复")
    }

    /// TUI(如 Claude Code)每帧经 DECTCEM 隐藏/显示光标,caret 被反复摘下挂回:
    /// 组词开始时 caret 可能不在视图树,重新挂回后也必须保持隐藏
    func testCaretReaddedMidCompositionStaysHidden() {
        let view = makeView()
        let terminal = view.getTerminal()

        view.hideCursor(source: terminal)
        XCTAssertNil(caret(in: view), "DECTCEM 隐藏后 caret 应已摘下")

        setMarked("yi ge", on: view)
        view.showCursor(source: terminal)
        XCTAssertEqual(caret(in: view)?.isHidden, true, "组词中挂回的 caret 应保持隐藏")

        view.insertText("一个" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
        view.hideCursor(source: terminal)
        view.showCursor(source: terminal)
        XCTAssertEqual(caret(in: view)?.isHidden, false, "上屏后再挂回的 caret 应可见")
    }

    /// 组词结束时 caret 恰好被 TUI 摘下:挂回时不能带着组词期的隐藏状态
    func testCaretDetachedAtCompositionEndComesBackVisible() {
        let view = makeView()
        let terminal = view.getTerminal()

        setMarked("hao", on: view)
        view.hideCursor(source: terminal)
        view.insertText("好" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
        view.showCursor(source: terminal)
        XCTAssertEqual(caret(in: view)?.isHidden, false)
    }

    func testMarkedTextOverlayBackgroundOpaque() {
        let view = makeView()
        setMarked("bu tou ming", on: view)
        let overlay = view.subviews.compactMap { $0 as? NSTextField }.first
        XCTAssertNotNil(overlay, "组词中应有拼音预览浮层")
        XCTAssertEqual(overlay?.backgroundColor?.alphaComponent, 1, "浮层背景应不透明,防止底下光标透出")
    }

    // MARK: - 光标格遮罩(盖住 Metal 自绘光标 / TUI 反色块 / 浮层盖不到的上下边缘)

    private func cover(in view: TermiteTerminalView) -> NSView? {
        view.subviews.first { $0.identifier?.rawValue == "imeCursorCover" }
    }

    func testCursorCoverPresentDuringCompositionOnly() {
        let view = makeView()
        XCTAssertNil(cover(in: view), "未组词时不应有遮罩")

        setMarked("zhe zhao", on: view)
        let cover = cover(in: view)
        XCTAssertNotNil(cover, "组词中应有光标格遮罩")
        XCTAssertEqual(cover?.frame, view.caretFrame, "遮罩应盖住整个光标格")

        view.insertText("遮罩" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNil(self.cover(in: view), "上屏后遮罩应移除")
    }

    func testCursorCoverRemovedOnUnmark() {
        let view = makeView()
        setMarked("qu xiao", on: view)
        XCTAssertNotNil(cover(in: view))
        view.unmarkText()
        XCTAssertNil(cover(in: view), "取消组词后遮罩应移除")
    }

    func testCursorCoverStaysBelowPinyinOverlay() {
        let view = makeView()
        setMarked("ceng ji", on: view)
        let coverIdx = view.subviews.firstIndex { $0.identifier?.rawValue == "imeCursorCover" }
        let overlayIdx = view.subviews.firstIndex { $0 is NSTextField }
        XCTAssertNotNil(coverIdx)
        XCTAssertNotNil(overlayIdx)
        XCTAssertLessThan(coverIdx!, overlayIdx!, "遮罩应压在拼音浮层之下,不能挡住拼音")
    }

    /// Metal 路径:光标画在 MTKView 纹理里,isHidden 方案无效,遮罩是唯一屏障
    func testCursorCoverUnderMetalRenderer() throws {
        let view = makeView()
        do { try view.setUseMetal(true) } catch { throw XCTSkip("Metal 不可用: \(error)") }

        setMarked("jin shu", on: view)
        let cover = cover(in: view)
        XCTAssertNotNil(cover, "Metal 下组词中也应有遮罩")
        XCTAssertEqual(cover?.frame, view.caretFrame)
        // 遮罩必须在 MTKView 之上,否则盖不住 Metal 画的光标
        let metalIdx = view.subviews.firstIndex { String(describing: type(of: $0)) == "MTKView" }
        let coverIdx = view.subviews.firstIndex { $0.identifier?.rawValue == "imeCursorCover" }
        if let metalIdx, let coverIdx {
            XCTAssertGreaterThan(coverIdx, metalIdx, "遮罩应在 MTKView 之上")
        }

        view.unmarkText()
        XCTAssertNil(self.cover(in: view))
    }
}
