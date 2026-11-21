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

    func testImagesOutsideDocumentTreeNeedConsent() {
        // /net 绝对路径会触发自动挂载连外部主机:不得自动读
        guard case .images(let abs, _) = kinds("![x](/net/evil-host/p.png)").first else { return XCTFail() }
        XCTAssertTrue(abs[0].outsideDocumentTree)
        XCTAssertTrue(abs[0].needsConsent)
        // ../ 逃出文档目录同理
        guard case .images(let up, _) = kinds("![x](../../etc/p.png)").first else { return XCTFail() }
        XCTAssertTrue(up[0].needsConsent)
        // 文档目录内的相对路径直接显示
        guard case .images(let inside, _) = kinds("![x](docs/p.png)").first else { return XCTFail() }
        XCTAssertFalse(inside[0].needsConsent)
        // 网络图片一律要点按
        guard case .images(let remote, _) = kinds("![x](https://example.com/p.png)").first else { return XCTFail() }
        XCTAssertTrue(remote[0].needsConsent)
    }

    func testConfinedRealPathRejectsSymlinksLeavingTree() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("md-confine-\(UUID().uuidString)").path
        let outside = fm.temporaryDirectory.appendingPathComponent("md-outside-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root); try? fm.removeItem(atPath: outside) }
        fm.createFile(atPath: root + "/docs/a.png", contents: Data([1]))
        fm.createFile(atPath: outside + "/b.png", contents: Data([1]))
        // 树内目录符号链接指到树外(模拟指向 /net/某主机):拒绝
        try fm.createSymbolicLink(atPath: root + "/escape", withDestinationPath: outside)
        // 树内指向树内:放行
        try fm.createSymbolicLink(atPath: root + "/alias", withDestinationPath: "docs")
        // 相对路径用 .. 逃出:拒绝
        try fm.createSymbolicLink(atPath: root + "/docs/up", withDestinationPath: "../../")

        XCTAssertNotNil(MarkdownRenderer.confinedRealPath(root + "/docs/a.png", root: root))
        XCTAssertNotNil(MarkdownRenderer.confinedRealPath(root + "/alias/a.png", root: root))
        XCTAssertNil(MarkdownRenderer.confinedRealPath(root + "/escape/b.png", root: root))
        XCTAssertNil(MarkdownRenderer.confinedRealPath(root + "/docs/up/x.png", root: root))
        XCTAssertNil(MarkdownRenderer.confinedRealPath(root + "/docs/missing.png", root: root))
        XCTAssertNil(MarkdownRenderer.confinedRealPath("/net/evil/p.png", root: root))
    }

    func testLexicalPathNeverNeedsFilesystem() {
        XCTAssertEqual(MarkdownRenderer.lexicalPath("/repo/./docs//a/../b.png"), "/repo/docs/b.png")
        XCTAssertEqual(MarkdownRenderer.lexicalPath("/net/evil/../x.png"), "/net/x.png")
        XCTAssertEqual(MarkdownRenderer.lexicalPath("/../../x"), "/x")
        XCTAssertEqual(MarkdownRenderer.lexicalPath("../a/./b"), "../a/b")
        // 文档里写的绝对路径,即便字面落在树内也要点按
        guard case .images(let abs, _) = kinds("![x](/repo/docs/p.png)").first else { return XCTFail() }
        XCTAssertTrue(abs[0].needsConsent)
    }
}
