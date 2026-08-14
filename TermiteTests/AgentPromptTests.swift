import XCTest
@testable import Termite

/// 应答模式的画面解析。
/// 权限确认框只活在 TUI 画面上,转录里没有 —— 这层解析错了,手机上就只剩一片乱码。
/// 用三家 agent 真实的框体形状打样,顺带守住「宁可认不出,也不能认错」的底线。
final class AgentPromptTests: XCTestCase {

    // MARK: - Claude Code

    private let claudePermission = [
        "╭──────────────────────────────────────────────╮",
        "│ Bash command                                 │",
        "│                                              │",
        "│   rm -rf build                               │",
        "│   清掉构建产物                                │",
        "│                                              │",
        "│ Do you want to proceed?                      │",
        "│ ❯ 1. Yes                                     │",
        "│   2. Yes, and don't ask again for rm commands│",
        "│   3. No, and tell Claude what to do (esc)    │",
        "╰──────────────────────────────────────────────╯",
    ]

    func testClaudePermissionOptions() {
        let parsed = AgentPromptReader.parse(screenLines: claudePermission)
        XCTAssertEqual(parsed.options.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(parsed.options.first?.label, "Yes")
        // ❯ 指着的那个要标出来,但不能替人按下去
        XCTAssertEqual(parsed.options.map(\.selected), [true, false, false])
    }

    func testClaudePermissionQuestion() {
        let parsed = AgentPromptReader.parse(screenLines: claudePermission)
        XCTAssertEqual(parsed.question, "Do you want to proceed?")
    }

    /// 方框线剥掉,但要执行的命令必须原样留着 —— 那才是决定按不按的依据
    func testScreenKeepsCommandAndDropsBoxDrawing() {
        let parsed = AgentPromptReader.parse(screenLines: claudePermission)
        XCTAssertTrue(parsed.screen.contains("rm -rf build"))
        XCTAssertFalse(parsed.screen.contains("│"))
        XCTAssertFalse(parsed.screen.contains("╭"))
    }

    /// 公共缩进按整体最小值扣,命令相对正文的层次留得住
    func testScreenDedentsButKeepsRelativeIndent() {
        let parsed = AgentPromptReader.parse(screenLines: [
            "    Bash command",
            "",
            "      rm -rf build",
        ])
        XCTAssertEqual(parsed.screen, "Bash command\n\n  rm -rf build")
    }

    // MARK: - 其它家

    func testCodexStyleArrowAndParenSeparator() {
        let parsed = AgentPromptReader.parse(screenLines: [
            "Allow Codex to run this command?",
            "› 1) Yes, proceed",
            "  2) No, tell Codex what to do",
        ])
        XCTAssertEqual(parsed.options.map(\.id), ["1", "2"])
        XCTAssertEqual(parsed.options.first?.selected, true)
        XCTAssertEqual(parsed.question, "Allow Codex to run this command?")
    }

    func testYesNoPromptFallsBackToTwoKeys() {
        let parsed = AgentPromptReader.parse(screenLines: [
            "Overwrite existing config? (y/n)",
        ])
        XCTAssertEqual(parsed.options.map(\.id), ["y", "n"])
    }

    // MARK: - 不能认错

    /// 正文里的编号列表不是让你选的。只有一个「1.」就当没有选项
    func testSingleNumberedLineIsNotAnOptionSet() {
        let parsed = AgentPromptReader.parse(screenLines: [
            "改动分三步:",
            "1. 先把解析抽出来",
        ])
        XCTAssertTrue(parsed.options.isEmpty)
    }

    /// 编号重复 = 上面那批是上一屏的残留,以最后一批为准。
    /// 认错的话手机上会显示一堆早就过期的选项
    func testRepeatedNumbersKeepOnlyTheLatestBlock() {
        let parsed = AgentPromptReader.parse(screenLines: [
            "  1. 旧的一问",
            "  2. 旧的二答",
            "现在这一问?",
            "❯ 1. 新的 Yes",
            "  2. 新的 No",
        ])
        XCTAssertEqual(parsed.options.map(\.label), ["新的 Yes", "新的 No"])
        XCTAssertEqual(parsed.question, "现在这一问?")
    }

    /// 没有确认框时选项为空,但画面原文照给 —— 界面还能把它当上下文显示
    func testPlainScreenYieldsNoOptions() {
        let parsed = AgentPromptReader.parse(screenLines: [
            "> 正在跑测试…",
            "  12 passed",
        ])
        XCTAssertTrue(parsed.options.isEmpty)
        XCTAssertNil(parsed.question)
        XCTAssertEqual(parsed.lastLine, "12 passed")
    }

    // MARK: - 按键白名单

    /// 应答通道不是一个不受限的键盘:只放行选项键和那几个导航键
    func testOnlyWhitelistedKeysProduceBytes() {
        XCTAssertEqual(AgentPromptReader.bytes(forKey: "1"), [0x31])
        XCTAssertEqual(AgentPromptReader.bytes(forKey: "y"), [0x79])
        XCTAssertEqual(AgentPromptReader.bytes(forKey: "enter"), [0x0d])
        XCTAssertEqual(AgentPromptReader.bytes(forKey: "esc"), [0x1b])
        XCTAssertEqual(AgentPromptReader.bytes(forKey: "up"), [0x1b, 0x5b, 0x41])

        XCTAssertNil(AgentPromptReader.bytes(forKey: "rm -rf /"))
        XCTAssertNil(AgentPromptReader.bytes(forKey: "a"))
        XCTAssertNil(AgentPromptReader.bytes(forKey: ""))
        // Ctrl-C 这类控制字符没在白名单里,不能借应答通道打进去
        XCTAssertNil(AgentPromptReader.bytes(forKey: "\u{03}"))
    }
}
