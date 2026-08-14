import Foundation

/// 手机应答模式的数据源:直接读 pane **当前画面**,而不是转录。
///
/// 为什么不用转录:权限确认框是 agent 画在备用屏上的 TUI,永远不会写进 jsonl。
/// 而「agent 卡住了在等我」几乎全是这类提示 —— 应答界面要问的正是转录答不了的问题,
/// 所以这里回到画面本身取真相。
///
/// 解析原则和转录适配器一致:**认不出来就当没有**。认不出选项时界面照样展示原始画面,
/// 人自己读得懂;绝不因为 agent 换了个框线样式就把应答通道整个搞没。

/// 一个可以一键按下去的候选项
struct ChatPromptOption: Codable, Identifiable, Equatable {
    /// 要按的那个键(编号选项就是 "1",y/n 提示就是 "y")
    var id: String
    var label: String
    /// 光标正指着它(agent 的默认选择)
    var selected: Bool
}

/// 「它在等什么」的完整回答
struct ChatPromptInfo: Codable, Equatable {
    var id: UUID
    /// 去掉方框线、去掉公共缩进后的画面尾部。提炼不出选项时,它就是界面的全部内容
    var screen: String
    /// 提炼出来的那一问(选项上方最近的一句)
    var question: String?
    var options: [ChatPromptOption]
    /// pane 的注意力态:"input" = 真在等你
    var attention: String?
    var attentionSeconds: Int?
    /// 这个 pane 底下还挂着 agent,按键才有意义
    var canSend: Bool
}

enum AgentPromptReader {
    /// 画面尾部读这么多行:够装下一整个确认框,又不会把整屏历史搬到手机上
    private static let tailRows = 40
    /// 选项文字截断长度。「2. Yes, and don't ask again for rm commands in /Users/…」很长
    private static let labelLimit = 120

    // MARK: - 画面 → 纯文本

    /// pane 当前画面的纯文本行。TUI 期间读的是备用屏,和你在 Mac 上看到的一致
    @MainActor
    static func screenLines(of session: TerminalSession) -> [String] {
        let terminal = session.terminalView.getTerminal()
        let firstRetainedRow = terminal.buffer.totalLinesTrimmed
        var viewportEnd = firstRetainedRow
        while terminal.getScrollInvariantLine(row: viewportEnd) != nil { viewportEnd += 1 }
        let viewportTop = max(firstRetainedRow, viewportEnd - terminal.rows)
        var lines: [String] = []
        for row in 0..<terminal.rows {
            guard let line = terminal.getScrollInvariantLine(row: viewportTop + row) else { continue }
            let cells = line.getData()
            let limit = min(line.getTrimmedLength(), cells.count)
            var text = ""
            var column = 0
            while column < limit {
                let cell = cells[column]
                text.append(terminal.getCharacter(for: cell))
                // 宽字符占两格,第二格是占位空 cell,跳过
                column += max(Int(cell.width), 1)
            }
            lines.append(text)
        }
        return lines
    }

    /// 剥方框线、掐掉上下空行、去掉公共缩进。
    /// 缩进按整体最小值扣,相对层次(代码片段、diff)因此保留下来
    static func tidy(_ raw: [String]) -> [String] {
        var lines = raw.map { line -> String in
            let stripped = String(line.filter { character in
                guard let scalar = character.unicodeScalars.first else { return false }
                // U+2500–U+257F 制表符(方框线)、U+2580–U+259F 块元素
                return !(0x2500...0x259F).contains(scalar.value)
            })
            // 尾部空白无意义;行首留着,等下面统一扣公共缩进
            return String(stripped.reversed().drop { $0 == " " }.reversed())
        }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return [] }
        let indent = lines.filter { !$0.isEmpty }
            .map { $0.prefix { $0 == " " }.count }
            .min() ?? 0
        guard indent > 0 else { return lines }
        return lines.map { String($0.dropFirst(min(indent, $0.count))) }
    }

    // MARK: - 选项识别

    /// `❯ 1. Yes` / `  2. No, tell Claude what to do` —— 三家 agent 的确认框都是这个形状
    private static func option(in line: String) -> ChatPromptOption? {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        var selected = false
        if let first = rest.first, "❯›▶●•→>".contains(first) {
            selected = true
            rest = rest.dropFirst()
        }
        rest = rest.drop { $0 == " " }
        guard let digit = rest.first, digit.isNumber else { return nil }
        rest = rest.dropFirst()
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        let label = rest.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return ChatPromptOption(id: String(digit), label: String(label.prefix(labelLimit)),
                                selected: selected)
    }

    /// 没有编号选项时,看看是不是 `(y/n)` 这种问法(很多 CLI 工具这么问)
    private static func yesNo(in lines: [String]) -> [ChatPromptOption] {
        let hit = lines.reversed().contains { line in
            let lower = line.lowercased()
            return lower.contains("(y/n)") || lower.contains("[y/n]") || lower.contains("y/n)")
        }
        guard hit else { return [] }
        return [
            ChatPromptOption(id: "y", label: String(localized: "是"), selected: false),
            ChatPromptOption(id: "n", label: String(localized: "否"), selected: false),
        ]
    }

    /// 选项上方最近的一句非空非选项的话 —— 那通常就是问题本身
    private static func question(above index: Int, in lines: [String]) -> String? {
        for line in lines[..<index].reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, option(in: text) == nil else { continue }
            return String(text.prefix(labelLimit))
        }
        return nil
    }

    // MARK: - 解析(纯函数,和终端解耦以便单测)

    struct Parsed {
        var screen: String
        var question: String?
        var options: [ChatPromptOption]
        /// 提炼不出问题时给列表用的一句话:画面最后一句有内容的话
        var lastLine: String?
    }

    static func parse(screenLines raw: [String]) -> Parsed {
        let lines = tidy(Array(raw.suffix(tailRows)))
        var options: [ChatPromptOption] = []
        var firstOptionIndex: Int?
        for (index, line) in lines.enumerated() {
            guard let parsed = option(in: line) else { continue }
            // 同一个编号出现两次说明上面那批是旧画面的残留,以最后一批为准
            if options.contains(where: { $0.id == parsed.id }) {
                options = []
                firstOptionIndex = index
            } else if firstOptionIndex == nil {
                firstOptionIndex = index
            }
            options.append(parsed)
        }
        // 单个「1.」很可能只是正文里的编号列表,不是让你选的
        if options.count < 2 {
            options = yesNo(in: lines)
            firstOptionIndex = nil
        }
        return Parsed(
            screen: lines.joined(separator: "\n"),
            question: firstOptionIndex.flatMap { question(above: $0, in: lines) },
            options: options,
            lastLine: lines.reversed()
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix(labelLimit)) })
    }

    // MARK: - 对外

    /// 一次读完:画面、问题、可按的键
    @MainActor
    static func read(session: TerminalSession, canSend: Bool) -> ChatPromptInfo {
        let parsed = parse(screenLines: screenLines(of: session))
        let attention: String? = switch session.attention {
        case .none: nil
        case .needsInput: "input"
        case .finished: "finished"
        }
        return ChatPromptInfo(
            id: session.id,
            screen: parsed.screen,
            question: parsed.question,
            options: parsed.options,
            attention: attention,
            attentionSeconds: attention == nil ? nil : session.attentionSince.map {
                max(0, Int(Date().timeIntervalSince($0)))
            },
            canSend: canSend
        )
    }

    /// 列表里那一行「它在问什么」。提炼不出问题就退回画面最后一句有内容的话
    @MainActor
    static func preview(session: TerminalSession) -> String? {
        let parsed = parse(screenLines: screenLines(of: session))
        return parsed.question ?? parsed.lastLine
    }

    /// 手机上按的那个键 → 真正写进 PTY 的字节。
    /// 白名单式:没列出的键一概不注入,免得应答通道变成一个不受限的键盘
    static func bytes(forKey key: String) -> [UInt8]? {
        switch key {
        case "enter": return [0x0d]
        case "esc": return [0x1b]
        case "up": return [0x1b, 0x5b, 0x41]
        case "down": return [0x1b, 0x5b, 0x42]
        default:
            guard key.count == 1, let character = key.first,
                  character.isNumber || character == "y" || character == "n" else { return nil }
            return Array(key.utf8)
        }
    }
}
