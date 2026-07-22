import XCTest
@testable import Termite

final class ShellResolverTests: XCTestCase {

    /// 兜底不变量:合成的 LANG 必须是系统真实存在的 locale
    /// (否则 zsh 退回 C locale,中文输入被 zle 拆碎)。
    func testSynthesizedLANGIsValidLocale() {
        let lang = ShellResolver.synthesizedLANG
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: "/usr/share/locale/\(lang)/LC_CTYPE"),
            "合成的 LANG=\(lang) 不是系统有效 locale"
        )
    }

    /// 中文输入依赖的是 UTF-8 字符集而非语言:en_US.UTF-8 的 LC_CTYPE
    /// 必须与 zh_CN.UTF-8 指向同一份数据,否则「英文提示+中文输入」的前提不成立。
    func testEnUSCtypeMatchesZhCN() throws {
        let enPath = "/usr/share/locale/\(ShellResolver.synthesizedLANG)/LC_CTYPE"
        let zhPath = "/usr/share/locale/zh_CN.UTF-8/LC_CTYPE"
        let en = try Data(contentsOf: URL(fileURLWithPath: enPath))
        let zh = try Data(contentsOf: URL(fileURLWithPath: zhPath))
        XCTAssertEqual(en, zh, "en_US 与 zh_CN 的 LC_CTYPE 数据不一致")
    }
}
