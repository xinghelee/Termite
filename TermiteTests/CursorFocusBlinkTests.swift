import XCTest
import SwiftTerm
@testable import Termite

/// 只有聚焦 pane 的光标闪烁:失焦切同形状常亮,聚焦还原
@MainActor
final class CursorFocusBlinkTests: XCTestCase {

    private func makeView() -> TermiteTerminalView {
        TermiteTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testUnfocusedSwitchesToSteady() {
        let view = makeView()
        view.getTerminal().setCursorStyle(.blinkBlock)
        view.applyFocusCursorStyle(focused: false)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBlock,
                       "失焦后闪烁样式应换成同形状常亮")
        view.applyFocusCursorStyle(focused: true)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .blinkBlock,
                       "重新聚焦应恢复闪烁")
    }

    func testSteadyPreferenceUntouchedByFocusChanges() {
        let view = makeView()
        view.getTerminal().setCursorStyle(.steadyBar)
        view.applyFocusCursorStyle(focused: false)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar)
        view.applyFocusCursorStyle(focused: true)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar,
                       "用户本来就选了不闪,焦点切换不应引入闪烁")
    }

    /// 输入暂停(常亮)期间失焦:恢复计时被结清,真正的闪烁样式转存到焦点机制
    func testResignDuringInputPauseKeepsSteadyThenRestores() {
        let view = makeView()
        view.blinkResumeDelay = 0.05
        view.getTerminal().setCursorStyle(.blinkUnderline)
        view.send(source: view, data: ArraySlice([0x1b, 0x5b, 0x44])) // 触发输入暂停
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyUnderline)
        view.applyFocusCursorStyle(focused: false)
        // 等超过原恢复延迟:失焦下不得偷偷恢复闪烁
        let exp = expectation(description: "idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyUnderline,
                       "失焦期间输入暂停的恢复计时不应把闪烁带回来")
        view.applyFocusCursorStyle(focused: true)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .blinkUnderline,
                       "重新聚焦应恢复输入暂停前的闪烁样式")
    }

    func testTUIStyleChangeWhileUnfocusedWins() {
        let view = makeView()
        view.getTerminal().setCursorStyle(.blinkBlock)
        view.applyFocusCursorStyle(focused: false)
        // 失焦期间 TUI 用 DECSCUSR 改了样式,聚焦时不抢
        view.getTerminal().setCursorStyle(.steadyBar)
        view.applyFocusCursorStyle(focused: true)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar,
                       "失焦期间外部改过样式,恢复逻辑应放弃不抢")
    }

    func testReassertAfterPreferenceChange() {
        let view = makeView()
        // 模拟失焦 pane 收到设置变更:CursorPrefs.apply 先写入闪烁样式
        view.getTerminal().setCursorStyle(.blinkBar)
        view.reassertCursorFocusState() // 视图不在窗口里,hasFocus == false
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar,
                       "设置变更后失焦 pane 应立刻整形回常亮")
    }
}
