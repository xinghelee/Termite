import SwiftUI

/// 轻量 Markdown 块解析:标题/围栏代码块(套用 CodeHighlighter 着色)/列表/引用/分隔线/段落,
/// 行内加粗、斜体、行内代码、链接交给系统 AttributedString(markdown:)。表格按等宽原样展示。
enum MarkdownRenderer {
    struct Block: Identifiable {
        let id: Int
        let kind: Kind
    }

    enum Kind {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case code(AttributedString)
        case quote(AttributedString)
        case listItem(marker: String, indent: Int, text: AttributedString)
        case table(String)
        case rule
    }

    static func parse(_ text: String, theme: TerminalTheme) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var tableLines: [String] = []

        func inline(_ s: String) -> AttributedString {
            (try? AttributedString(
                markdown: s,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(s)
        }
        func add(_ kind: Kind) {
            blocks.append(Block(id: blocks.count, kind: kind))
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            add(.paragraph(inline(paragraph.joined(separator: " "))))
            paragraph = []
        }
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            add(.table(tableLines.joined(separator: "\n")))
            tableLines = []
        }

        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 围栏代码块
            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushTable()
                let lang = languageExtension(String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces))
                var codeLines: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1 // 吃掉闭合 ```
                let code = codeLines.joined(separator: "\n")
                add(.code(CodeHighlighter.highlight(code, fileExtension: lang, theme: theme) ?? AttributedString(code)))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushTable()
                i += 1
                continue
            }

            // 表格行:攒起来整块等宽展示
            if trimmed.hasPrefix("|") {
                flushParagraph()
                tableLines.append(trimmed)
                i += 1
                continue
            }
            flushTable()

            // 标题
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6, trimmed.count > level, trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " {
                    flushParagraph()
                    let content = String(trimmed.dropFirst(level + 1))
                    add(.heading(level: level, text: inline(content)))
                    i += 1
                    continue
                }
            }
            // 分隔线
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                add(.rule)
                i += 1
                continue
            }
            // 引用
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let content = trimmed.drop(while: { $0 == ">" || $0 == " " })
                add(.quote(inline(String(content))))
                i += 1
                continue
            }
            // 列表项(- * + 或 "1." 开头)
            if let item = parseListItem(line) {
                flushParagraph()
                add(.listItem(marker: item.marker, indent: item.indent, text: inline(item.text)))
                i += 1
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        flushTable()
        return blocks
    }

    private static func parseListItem(_ line: String) -> (marker: String, indent: Int, text: String)? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let rest = line.dropFirst(leading.count)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return ("•", indent, String(rest.dropFirst(2)))
        }
        let digits = rest.prefix(while: { $0.isNumber })
        if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") {
            return ("\(digits).", indent, String(rest.dropFirst(digits.count + 2)))
        }
        return nil
    }

    /// 围栏语言名 → CodeHighlighter 认识的扩展名
    private static func languageExtension(_ lang: String) -> String {
        switch lang.lowercased() {
        case "python": return "py"
        case "javascript", "node": return "js"
        case "typescript": return "ts"
        case "rust": return "rs"
        case "ruby": return "rb"
        case "shell", "bash", "zsh", "console", "terminal": return "sh"
        case "objc", "objective-c": return "m"
        case "c++": return "cpp"
        case "kotlin": return "kt"
        case "yml": return "yaml"
        default: return lang.lowercased()
        }
    }
}

/// 渲染出的 Markdown 块列表(FilePreviewScreen 的正文)
struct MarkdownBlocksView: View {
    let blocks: [MarkdownRenderer.Block]

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks) { block in
                blockView(block.kind)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ kind: MarkdownRenderer.Kind) -> some View {
        switch kind {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            Text(text)
                .font(.system(size: 12.5))
                .lineSpacing(3)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.elevatedBackground))
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accentColor.opacity(0.5))
                    .frame(width: 3)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.accentColor)
                Text(text)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .table(let raw):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(raw)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.elevatedBackground))
        case .rule:
            Divider().overlay(theme.borderColor)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 19, weight: .bold)
        case 2: return .system(size: 16, weight: .bold)
        case 3: return .system(size: 14, weight: .semibold)
        default: return .system(size: 12.5, weight: .semibold)
        }
    }
}
