import XCTest
import SwiftTerm
@testable import Termite

/// 输入时暂停光标闪烁(TermiteTerminalView 在 send 时把闪烁样式临时换成稳定样式)
@MainActor
final class CursorBlinkPauseTests: XCTestCase {

    private func makeView() -> TermiteTerminalView {
        TermiteTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    /// 模拟一次用户按键(左方向键 ESC [ D)
    private func sendKey(_ view: TermiteTerminalView) {
        view.send(source: view, data: ArraySlice([0x1b, 0x5b, 0x44]))
    }

    private func waitABit(_ seconds: TimeInterval) {
        let exp = expectation(description: "idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 2)
    }

    func testInputSwitchesBlinkToSteady() {
        let view = makeView()
        view.getTerminal().setCursorStyle(.blinkBlock)
        sendKey(view)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBlock,
                       "按键后闪烁样式应临时换成同形状稳定样式")
    }

    func testBlinkRestoredAfterIdle() {
        let view = makeView()
        view.blinkResumeDelay = 0.05
        view.getTerminal().setCursorStyle(.blinkBar)
        sendKey(view)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar)
        waitABit(0.3)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .blinkBar,
                       "停止输入后应恢复原闪烁样式")
    }

    func testRepeatedInputKeepsSteady() {
        let view = makeView()
        view.blinkResumeDelay = 0.2
        view.getTerminal().setCursorStyle(.blinkBlock)
        sendKey(view)
        waitABit(0.1)
        sendKey(view)
        waitABit(0.1)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBlock,
                       "连续输入期间恢复计时应不断顺延,保持常亮")
        waitABit(0.3)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .blinkBlock)
    }

    func testSteadyStyleUntouched() {
        let view = makeView()
        view.getTerminal().setCursorStyle(.steadyBlock)
        sendKey(view)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBlock,
                       "本来就不闪的样式不应被改动")
    }

    func testExternalStyleChangeDuringPauseWins() {
        let view = makeView()
        view.blinkResumeDelay = 0.05
        view.getTerminal().setCursorStyle(.blinkBlock)
        sendKey(view)
        // TUI 在暂停期间通过 DECSCUSR 换了样式,恢复时不应抢回
        view.getTerminal().setCursorStyle(.steadyBar)
        waitABit(0.3)
        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar,
                       "暂停期间外部改过样式,恢复逻辑应放弃不抢")
    }
}
