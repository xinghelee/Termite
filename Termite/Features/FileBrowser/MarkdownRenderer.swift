import SwiftUI

/// 轻量 Markdown 块解析:标题/围栏代码块(套用 CodeHighlighter 着色)/列表/引用/分隔线/段落/
/// 表格(GFM,含对齐)/图片(本地相对路径与网络)/README 常见的 HTML 块(<p align>、<h1>、<a>、<img>),
/// 行内加粗、斜体、行内代码、链接交给系统 AttributedString(markdown:)。
enum MarkdownRenderer {
    enum CellAlignment { case leading, center, trailing }

    struct ImageRef: Hashable {
        /// 本地文件(已按文档目录解析成绝对路径)或网络地址
        let source: String
        let alt: String
        /// HTML width 属性(pt);nil = 按可用宽度自适应
        let width: CGFloat?

        var isRemote: Bool { source.hasPrefix("http://") || source.hasPrefix("https://") }
    }

    struct Block: Identifiable {
        let id: Int
        let kind: Kind
    }

    enum Kind {
        case heading(level: Int, text: AttributedString, centered: Bool)
        case paragraph(AttributedString, centered: Bool)
        case code(AttributedString)
        case quote(AttributedString)
        case listItem(marker: String, indent: Int, text: AttributedString)
        case table(header: [AttributedString], alignments: [CellAlignment], rows: [[AttributedString]])
        case images([ImageRef], centered: Bool)
        case rule
    }

    /// baseDirectory:文档所在目录,用来解析图片的相对路径
    static func parse(_ text: String, theme: TerminalTheme, baseDirectory: String? = nil) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var tableLines: [String] = []

        func resolve(_ src: String) -> String {
            if src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("/") { return src }
            guard let baseDirectory else { return src }
            let clean = src.hasPrefix("./") ? String(src.dropFirst(2)) : src
            return ((baseDirectory as NSString).appendingPathComponent(clean) as NSString).standardizingPath
        }

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
            add(.paragraph(inline(paragraph.joined(separator: " ")), centered: false))
            paragraph = []
        }
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            if let table = parseTable(tableLines) {
                add(.table(header: table.header.map(inline), alignments: table.alignments,
                           rows: table.rows.map { $0.map(inline) }))
            } else {
                // 不是合法表格(缺分隔行):按普通段落
                tableLines.forEach { paragraph.append($0) }
                flushParagraph()
            }
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

            // HTML 块(README 头部常见的居中 logo / 标题 / 链接行):到空行为止整体转换
            if trimmed.hasPrefix("<") {
                flushParagraph()
                flushTable()
                var htmlLines: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    htmlLines.append(lines[i])
                    i += 1
                }
                for kind in convertHTML(htmlLines.joined(separator: "\n"), inline: inline, resolve: resolve) {
                    add(kind)
                }
                continue
            }

            // 整行只有图片(可带外层链接):渲染成图;夹在文字里的图片仍按 alt 文本处理
            if let images = imageOnlyLine(trimmed, resolve: resolve) {
                flushParagraph()
                flushTable()
                add(.images(images, centered: false))
                i += 1
                continue
            }

            // 表格行:攒齐后按 GFM 表格解析
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
                    add(.heading(level: level, text: inline(content), centered: false))
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

    // MARK: - 表格

    /// 拆单元格:去首尾竖线,`\|` 转义与行内代码里的竖线不算分隔
    static func splitCells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for ch in body {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; current.append(ch); continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    /// GFM 表格:第一行表头,第二行是 --- 分隔(冒号定对齐),其余为数据行(列数补齐到表头)
    static func parseTable(_ lines: [String]) -> (header: [String], alignments: [CellAlignment], rows: [[String]])? {
        guard lines.count >= 2 else { return nil }
        let header = splitCells(lines[0])
        let separators = splitCells(lines[1])
        let isSeparator = !separators.isEmpty && separators.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
        guard isSeparator else { return nil }
        let alignments: [CellAlignment] = (0..<header.count).map { index in
            guard index < separators.count else { return .leading }
            let cell = separators[index]
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .trailing
            default: return .leading
            }
        }
        let rows = lines.dropFirst(2).map { line -> [String] in
            var cells = splitCells(line)
            if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
            return Array(cells.prefix(header.count))
        }
        return (header, alignments, rows)
    }

    // MARK: - 图片与 HTML

    private static let markdownImage = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#)

    /// 一行里除了图片(以及包住图片的链接)别无他物时返回图片列表
    static func imageOnlyLine(_ line: String, resolve: (String) -> String) -> [ImageRef]? {
        let range = NSRange(line.startIndex..., in: line)
        let matches = markdownImage.matches(in: line, range: range)
        guard !matches.isEmpty else { return nil }
        var rest = markdownImage.stringByReplacingMatches(in: line, range: range, withTemplate: "")
        // [![alt](img)](link) 剩下 [](link)
        rest = rest.replacingOccurrences(of: #"\[\s*\]\([^)]*\)"#, with: "", options: .regularExpression)
        guard rest.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return matches.compactMap { match in
            guard let alt = Range(match.range(at: 1), in: line), let src = Range(match.range(at: 2), in: line) else { return nil }
            return ImageRef(source: resolve(String(line[src])), alt: String(line[alt]), width: nil)
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = name + #"\s*=\s*["']([^"']*)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    /// README 头部的 HTML:居中的 logo、<h1> 标题、<a> 链接行、<img> 截图。
    /// 不追求完整 HTML,只把常见写法转成对应的块,剩余标签剥掉保留文字
    static func convertHTML(_ html: String, inline: (String) -> AttributedString,
                            resolve: (String) -> String) -> [Kind] {
        var text = html.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        let centered = text.range(of: #"align\s*=\s*["']?center"#, options: [.regularExpression, .caseInsensitive]) != nil
        var kinds: [Kind] = []
        var pendingImages: [ImageRef] = []

        func flushImages() {
            if !pendingImages.isEmpty { kinds.append(.images(pendingImages, centered: centered)) }
            pendingImages = []
        }

        // 统一换行:<br>、块级标签边界都视为分段
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</?(p|div|picture|details|summary|table|tr|td|th|center)[^>]*>"#,
                                         with: "\n", options: [.regularExpression, .caseInsensitive])
        // <a href="u">t</a> → [t](u)(链接里只有图片时保留图片标签,外层链接丢弃)
        if let anchor = try? NSRegularExpression(pattern: #"<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#,
                                                 options: .caseInsensitive) {
            let ns = text as NSString
            var result = ""
            var last = 0
            for match in anchor.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let href = ns.substring(with: match.range(at: 1))
                let label = ns.substring(with: match.range(at: 2))
                if label.range(of: "<img", options: .caseInsensitive) != nil {
                    result += label
                } else {
                    let plain = label.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    result += "[\(plain)](\(href))"
                }
                last = match.range.location + match.range.length
            }
            result += ns.substring(from: last)
            text = result
        }

        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // 图片:<img>/<source> 抽出来,其余文字继续处理
            if let imgRegex = try? NSRegularExpression(pattern: #"<(img|source)\b[^>]*>"#, options: .caseInsensitive) {
                let ns = line as NSString
                for match in imgRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let tag = ns.substring(with: match.range)
                    guard tag.lowercased().hasPrefix("<img"),
                          let src = attribute("src", in: tag) else { continue }
                    let width = attribute("width", in: tag).flatMap { Double($0) }.map { CGFloat($0) }
                    pendingImages.append(ImageRef(source: resolve(src), alt: attribute("alt", in: tag) ?? "", width: width))
                }
                line = imgRegex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            }
            // 标题
            if let heading = line.range(of: #"^<h([1-6])[^>]*>([\s\S]*?)</h[1-6]>$"#, options: [.regularExpression, .caseInsensitive]) {
                let tag = String(line[heading])
                let level = Int(String(tag[tag.index(tag.startIndex, offsetBy: 2)])) ?? 1
                let content = tag.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                flushImages()
                kinds.append(.heading(level: level, text: inline(content), centered: centered))
                continue
            }
            let plain = line.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty else { continue }
            flushImages()
            kinds.append(.paragraph(inline(plain), centered: centered))
        }
        flushImages()
        return kinds
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
        // Lazy 是硬要求:1500 行文档能解析出六七百个块,普通 VStack 会把它们
        // 全量同步实例化在主线程(每块 Text + 选择容器几毫秒),整面板卡住 10s 级
        // (社区反馈实测);解析本身只要几十 ms,不是瓶颈。Lazy 后只实例化可见块
        LazyVStack(alignment: .leading, spacing: 9) {
            ForEach(blocks) { block in
                blockView(block.kind)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ kind: MarkdownRenderer.Kind) -> some View {
        switch kind {
        case .heading(let level, let text, let centered):
            Text(text)
                .font(headingFont(level))
                .multilineTextAlignment(centered ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text, let centered):
            Text(text)
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .multilineTextAlignment(centered ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        case .images(let images, let centered):
            HStack(spacing: 6) {
                ForEach(images, id: \.self) { MarkdownImageView(image: $0) }
            }
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        case .table(let header, let alignments, let rows):
            MarkdownTableView(header: header, alignments: alignments, rows: rows)
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

/// GFM 表格:表头加粗 + 斑马纹 + 外框;单元格内容可折行,窄面板里不横向溢出
private struct MarkdownTableView: View {
    let header: [AttributedString]
    let alignments: [MarkdownRenderer.CellAlignment]
    let rows: [[AttributedString]]

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(header.indices, id: \.self) { column in
                    cell(header[column], column: column, bold: true)
                }
            }
            .background(theme.elevatedBackground)
            Rectangle().fill(theme.borderColor).frame(height: 1)
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(column < rows[row].count ? rows[row][column] : AttributedString(""), column: column, bold: false)
                    }
                }
                .background(row.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.borderColor, lineWidth: 1))
    }

    private func cell(_ text: AttributedString, column: Int, bold: Bool) -> some View {
        let alignment = column < alignments.count ? alignments[column] : .leading
        let frameAlignment: Alignment = switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(text)
            .font(.system(size: 12, weight: bold ? .semibold : .regular))
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

/// Markdown / HTML 图片。
/// - 本地:只读普通文件(排除 FIFO / 设备文件)、≤ 8 MB,后台线程读取解码,不卡主线程
/// - 网络:**不自动加载**——打开文档就发请求等于给文档作者埋追踪像素(泄露 IP 与打开时间)。
///   点一下才拉取,只认 https,走无 cookie / 无缓存的临时会话,≤ 8 MB
/// 读不到或未加载时显示 alt 文本
private struct MarkdownImageView: View {
    let image: MarkdownRenderer.ImageRef

    @State private var loaded: NSImage?
    @State private var failed = false
    @State private var remoteRequested = false

    private static let maxBytes = 8 * 1024 * 1024

    var body: some View {
        Group {
            if let loaded {
                Image(nsImage: loaded).resizable().scaledToFit()
            } else if image.isRemote && !remoteRequested {
                Button { remoteRequested = true } label: {
                    placeholder(String(localized: "点按加载网络图片"), symbol: "network")
                }
                .buttonStyle(.plain)
                .help(image.source)
            } else if failed {
                placeholder(nil, symbol: "photo")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: image.width)
        .help(image.alt)
        .task(id: "\(image.source)#\(remoteRequested)") { await load() }
    }

    private func load() async {
        if image.isRemote {
            guard remoteRequested else { return }
            loaded = await Self.fetchRemote(image.source)
        } else {
            loaded = await Self.readLocal(image.source)
        }
        failed = loaded == nil
    }

    private static func readLocal(_ path: String) async -> NSImage? {
        await Task.detached(priority: .utility) { () -> NSImage? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? Int, size <= maxBytes,
                  let data = FileManager.default.contents(atPath: path) else { return nil }
            return NSImage(data: data)
        }.value
    }

    private static func fetchRemote(_ source: String) async -> NSImage? {
        guard let url = URL(string: source), url.scheme == "https" else { return nil }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= maxBytes else { return nil }
        return await Task.detached(priority: .utility) { NSImage(data: data) }.value
    }

    private func placeholder(_ hint: String?, symbol: String) -> some View {
        let alt = image.alt.isEmpty ? String(localized: "图片") : image.alt
        return Label(hint.map { "\(alt) · \($0)" } ?? alt, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}
