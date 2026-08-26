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

    // MARK: - 光标交还用户偏好(vim/fzf 退出留下的 DECSCUSR 死方块)

    /// 单测里视图不在响应者链上,hasFocus 恒为 false;先验失焦分支的落点,
    /// 再用 applyFocusCursorStyle(focused: true) 走一遍聚焦还原
    private func withCursorPreference(shape: String, blink: Bool, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let oldShape = defaults.object(forKey: SettingsKeys.cursorShape)
        let oldBlink = defaults.object(forKey: SettingsKeys.cursorBlink)
        defaults.set(shape, forKey: SettingsKeys.cursorShape)
        defaults.set(blink, forKey: SettingsKeys.cursorBlink)
        defer {
            if let oldShape { defaults.set(oldShape, forKey: SettingsKeys.cursorShape) }
            else { defaults.removeObject(forKey: SettingsKeys.cursorShape) }
            if let oldBlink { defaults.set(oldBlink, forKey: SettingsKeys.cursorBlink) }
            else { defaults.removeObject(forKey: SettingsKeys.cursorBlink) }
        }
        body()
    }

    func testResidualSteadyStyleHandedBackToPreference() {
        withCursorPreference(shape: CursorPrefs.shapeBar, blink: true) {
            let view = makeView()
            // vim/fzf 退出留下的 DECSCUSR 常亮方块:形状与用户偏好都不沾边
            view.getTerminal().setCursorStyle(.steadyBlock)
            XCTAssertTrue(view.restoreCursorPreference(), "没有 TUI 在驱动终端时应接管整形")
            XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar,
                           "失焦 pane 按偏好形状常亮,不留下方块")
            view.applyFocusCursorStyle(focused: true)
            XCTAssertEqual(view.getTerminal().options.cursorStyle, .blinkBar,
                           "聚焦后应是偏好里的闪烁光标,而不是残留的死方块")
        }
    }

    func testRestoreHonoursSteadyPreference() {
        withCursorPreference(shape: CursorPrefs.shapeBar, blink: false) {
            let view = makeView()
            view.getTerminal().setCursorStyle(.steadyBlock)
            view.restoreCursorPreference()
            XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar)
            view.applyFocusCursorStyle(focused: true)
            XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar,
                           "用户选了不闪,交还偏好不得引入闪烁")
        }
    }

    /// 输入暂停(临时常亮)期间交还偏好:暂停记账要一并结清,
    /// 否则计时器回头把旧样式顶回来,刚交还的偏好白设
    func testRestoreClearsPendingInputPause() {
        withCursorPreference(shape: CursorPrefs.shapeBar, blink: true) {
            let view = makeView()
            view.blinkResumeDelay = 0.05
            view.getTerminal().setCursorStyle(.blinkUnderline)
            view.send(source: view, data: ArraySlice([0x1b, 0x5b, 0x44])) // 触发输入暂停
            XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyUnderline)
            view.restoreCursorPreference()
            XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar)
            let exp = expectation(description: "idle")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
            wait(for: [exp], timeout: 2)
            XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar,
                           "暂停恢复计时不应把交还前的样式带回来")
        }
    }
}
