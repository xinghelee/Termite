import XCTest
@testable import Termite

final class ShellResolverTests: XCTestCase {

    /// 触发线上 bug 的组合:应用语言简中 + 地区菲律宾。
    /// zh_PH 不存在,必须落到 zh_CN.UTF-8 而不是拼出 zh_Hans_PH.UTF-8。
    func testChineseWithUnsupportedRegionFallsBackToZhCN() {
        XCTAssertEqual(ShellResolver.utf8LocaleName(for: Locale(identifier: "zh-Hans_PH")), "zh_CN.UTF-8")
    }

    func testTraditionalChineseFallsBackToZhTW() {
        XCTAssertEqual(ShellResolver.utf8LocaleName(for: Locale(identifier: "zh-Hant_PH")), "zh_TW.UTF-8")
    }

    func testDirectlySupportedLocaleIsKept() {
        XCTAssertEqual(ShellResolver.utf8LocaleName(for: Locale(identifier: "en_PH")), "en_PH.UTF-8")
        XCTAssertEqual(ShellResolver.utf8LocaleName(for: Locale(identifier: "zh_CN")), "zh_CN.UTF-8")
    }

    func testUnknownLanguageFallsBackToEnUS() {
        XCTAssertEqual(ShellResolver.utf8LocaleName(for: Locale(identifier: "fil_PH")), "en_US.UTF-8")
    }

    /// 兜底不变量:无论系统处于什么 locale,合成结果必须是系统真实存在的
    /// locale(否则 zsh 退回 C locale,中文输入被 zle 拆碎)。
    func testEnvironmentLANGIsAlwaysValidLocale() {
        let lang = ShellResolver.utf8LocaleName(for: Locale.current)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: "/usr/share/locale/\(lang)/LC_CTYPE"),
            "合成的 LANG=\(lang) 不是系统有效 locale"
        )
    }
}
