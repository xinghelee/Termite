import XCTest
@testable import Termite

@MainActor
final class MarkdownRendererTests: XCTestCase {
    private func kinds(_ text: String, base: String? = "/repo") -> [MarkdownRenderer.Kind] {
        MarkdownRenderer.parse(text, theme: ThemeStore.shared.current, baseDirectory: base).map(\.kind)
    }

    func testTableParsedWithAlignment() {
        let md = """
        | Capability | What it provides |
        | :--- | :---: |
        | Terminal | Tabs, `a|b` splits |
        | SFTP |
        """
        guard case .table(let header, let alignments, let rows) = kinds(md).first else { return XCTFail("not a table") }
        XCTAssertEqual(header.map { String($0.characters) }, ["Capability", "What it provides"])
        XCTAssertEqual(alignments, [.leading, .center])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(String(rows[0][1].characters), "Tabs, a|b splits")  // 行内代码里的竖线不拆
        XCTAssertEqual(rows[1].count, 2)                                    // 短行补齐
    }

    func testPipeLinesWithoutSeparatorStayParagraph() {
        guard case .paragraph = kinds("| just | text |").first else { return XCTFail() }
    }

    func testReadmeHTMLHeader() {
        let md = """
        <p align="center">
          <img src="docs/assets/icon.svg" width="112" alt="Berth icon">
        </p>

        <h1 align="center">Berth</h1>

        <p align="center">
          <a href="https://example.com/releases">Releases</a> · <a href="README.zh-CN.md">简体中文</a>
        </p>
        """
        let result = kinds(md)
        guard case .images(let images, let centered) = result[0] else { return XCTFail("\(result)") }
        XCTAssertTrue(centered)
        XCTAssertEqual(images.first?.source, "/repo/docs/assets/icon.svg")
        XCTAssertEqual(images.first?.width, 112)
        guard case .heading(1, let title, true) = result[1] else { return XCTFail("\(result)") }
        XCTAssertEqual(String(title.characters), "Berth")
        guard case .paragraph(let links, true) = result[2] else { return XCTFail("\(result)") }
        XCTAssertEqual(String(links.characters), "Releases · 简体中文")         // 标签剥掉,链接保留为链接文本
        XCTAssertFalse(String(links.characters).contains("<"))
    }

    func testImageOnlyLine() {
        guard case .images(let images, _) = kinds("![Berth workspace](./docs/shot.png)").first else { return XCTFail() }
        XCTAssertEqual(images.first?.source, "/repo/docs/shot.png")
        XCTAssertEqual(images.first?.alt, "Berth workspace")
        // 夹在文字中间的图片仍是段落
        guard case .paragraph = kinds("see ![x](a.png) here").first else { return XCTFail() }
    }
}
