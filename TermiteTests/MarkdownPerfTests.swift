import XCTest
@testable import Termite

/// 文件预览性能回归:1500 行级 markdown 曾卡 10s(社区反馈)。
/// 解析在后台线程,这里守住解析本身别退化成秒级;
/// UI 侧(LazyVStack)不在单测覆盖内
final class MarkdownPerfTests: XCTestCase {
    /// 有代表性的 1500 行文档:标题/段落/列表/两个大代码围栏/表格,中英混排
    private func makeDocument(lines: Int) -> String {
        var out: [String] = []
        var i = 0
        while out.count < lines {
            i += 1
            out.append("## 第 \(i) 節標題 Section \(i)")
            out.append("這是一段混排說明文字 with **bold** and `inline code` 以及一個[連結](https://example.com),用來模擬真實文檔的行內語法密度。")
            out.append("- 列表項目一 item with 中文")
            out.append("- 列表項目二 `code` 混排")
            out.append("")
            if i % 10 == 0 {
                out.append("```swift")
                for j in 0..<40 {
                    out.append("    func demo\(j)(_ value: Int) -> String { return \"值 \\(value)\" } // 註釋")
                }
                out.append("```")
            }
            if i % 15 == 0 {
                out.append("| 欄位 | 說明 |")
                out.append("| --- | --- |")
                out.append("| a | 內容 |")
            }
        }
        return out.prefix(lines).joined(separator: "\n")
    }

    func testParse1500LineMarkdownIsFast() {
        let doc = makeDocument(lines: 1500)
        let theme = TerminalTheme.midnight
        let start = Date()
        let blocks = MarkdownRenderer.parse(doc, theme: theme)
        let elapsed = Date().timeIntervalSince(start)
        print("[perf] 1500 行 markdown 解析: \(String(format: "%.0f", elapsed * 1000))ms, \(blocks.count) 块")
        XCTAssertGreaterThan(blocks.count, 100)
        XCTAssertLessThan(elapsed, 2.0, "1500 行 markdown 解析不应超过 2s(反馈的 10s 卡顿)")
    }

    func testHighlightLargeSourceIsLinear() {
        // 源码视图路径:512KB 上限下的大文件着色
        let line = "func compute(_ input: Int) -> String { let value = input * 42; return \"result \\(value)\" } // note\n"
        let source = String(repeating: line, count: 3000) // ~300KB
        let theme = TerminalTheme.midnight
        let start = Date()
        let out = CodeHighlighter.highlight(source, fileExtension: "swift", theme: theme)
        let elapsed = Date().timeIntervalSince(start)
        print("[perf] ~300KB swift 着色: \(String(format: "%.0f", elapsed * 1000))ms")
        XCTAssertNotNil(out)
        XCTAssertLessThan(elapsed, 2.0, "大文件着色不应是平方复杂度")
    }
}
