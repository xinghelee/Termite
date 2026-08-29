import CoreText
import XCTest
@testable import Termite

/// Nerd Font 图标链路。宿主就是 Termite.app,ATSApplicationFontsPath 的注册在这里
/// 真实发生——断言的是用户拿到的字体解析结果,不是脚本仿真。
/// 图标全在 Unicode 私有区,系统回退表不覆盖;这层断了,p10k/eza 用户满屏 tofu。
final class FontPrefsTests: XCTestCase {

    /// 覆盖四个图标区:powerline(E0B0)、seti(E62B)、Font Awesome(F09B)、
    /// material 在 SPUA-A(F0868);外加中文与 ASCII 守住回退不被级联砸掉
    private let sample = "\u{E0B0}\u{E62B}\u{F09B}\u{F0868}汉A"

    /// 每个字形跑排版后落在哪个字体(与 SwiftTerm 两条渲染路径同源:CTLine 排版)
    private func runFonts(_ text: String, font: NSFont) -> [(text: String, fontName: String)] {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }
        return runs.map { run in
            let attrs = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
            let font = attrs[.font] as! NSFont
            let range = CTRunGetStringRange(run)
            let sub = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            return (sub, font.fontName)
        }
    }

    private func fontName(for scalar: String, in resolved: [(text: String, fontName: String)]) -> String? {
        resolved.first { $0.text.contains(scalar) }?.fontName
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SettingsKeys.terminalFontFamily)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.terminalFontFamily)
        super.tearDown()
    }

    func testBundledFontsRegisteredInAppBundle() {
        // ATSApplicationFontsPath 注册成功的直接证据
        XCTAssertNotNil(NSFont(name: FontPrefs.bundledFamily, size: 13))
        XCTAssertNotNil(NSFont(name: "SymbolsNFM", size: 13))
    }

    func testDefaultFontIsBundledNerdFont() {
        XCTAssertEqual(FontPrefs.font().fontName, "JetBrainsMonoNFM-Regular")
    }

    func testDefaultFontRendersNerdGlyphsNatively() {
        let resolved = runFonts(sample, font: FontPrefs.font())
        for scalar in ["\u{E0B0}", "\u{E62B}", "\u{F09B}", "\u{F0868}"] {
            XCTAssertEqual(fontName(for: scalar, in: resolved), "JetBrainsMonoNFM-Regular")
        }
        // 级联不能砸掉系统回退:中文照走苹方,ASCII 留在正文字体
        XCTAssertTrue(fontName(for: "汉", in: resolved)?.contains("PingFang") ?? false)
        XCTAssertEqual(fontName(for: "A", in: resolved), "JetBrainsMonoNFM-Regular")
    }

    func testCustomFontFallsBackToSymbolsForNerdGlyphs() {
        UserDefaults.standard.set("Menlo", forKey: SettingsKeys.terminalFontFamily)
        let font = FontPrefs.font()
        XCTAssertEqual(font.fontName, "Menlo-Regular")
        let resolved = runFonts(sample, font: font)
        for scalar in ["\u{E0B0}", "\u{E62B}", "\u{F09B}", "\u{F0868}"] {
            XCTAssertEqual(fontName(for: scalar, in: resolved), "SymbolsNFM")
        }
        XCTAssertTrue(fontName(for: "汉", in: resolved)?.contains("PingFang") ?? false)
    }

    func testBoldDerivationKeepsNerdGlyphs() {
        // SwiftTerm FontSet 同款派生:必须命中内置真字面,图标不丢
        let bold = NSFontManager.shared.convert(FontPrefs.font(), toHaveTrait: [.boldFontMask])
        XCTAssertEqual(bold.fontName, "JetBrainsMonoNFM-Bold")
        let resolved = runFonts(sample, font: bold)
        XCTAssertEqual(fontName(for: "\u{E0B0}", in: resolved), "JetBrainsMonoNFM-Bold")
    }

    func testFamilyPickerExcludesInternalFonts() {
        let families = FontPrefs.monospacedFamilies()
        // 图标字体没有正文字形;内置默认族由「默认」项承载,不重复出现
        XCTAssertFalse(families.contains("Symbols Nerd Font Mono"))
        XCTAssertFalse(families.contains(FontPrefs.bundledFamily))
    }
}
