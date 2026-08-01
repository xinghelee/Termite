import Foundation

/// 从一行终端文本里识别「文件[:行[:列]]」引用(纯逻辑,可单测)。
/// 识别刻意保守:是否真实存在由 resolve 把关,不存在的候选不产生任何可点击行为。
enum FileLinkDetector {

    struct Match: Equatable {
        let path: String
        let line: Int?
        let column: Int?
        /// 该引用覆盖的终端列区间(宽字符按 2 列计),用于命中测试
        let columns: Range<Int>
    }

    /// Python traceback:File "/path/x.py", line 12 —— 整段可点
    private static let pythonPattern = #/File "([^"]+)", line ([0-9]+)/#
    /// 通用:path(:line(:col)),路径字符集不含空格/引号/括号/冒号
    private static let genericPattern = #/([A-Za-z0-9_.+@%~/-]+)(?::([0-9]+)(?::([0-9]+))?)?/#

    /// 在一行终端文本里找出覆盖 column(0 起,终端列)的文件引用
    static func match(in text: String, column: Int) -> Match? {
        for m in text.matches(of: pythonPattern) {
            let cols = terminalColumns(of: m.range, in: text)
            guard cols.contains(column) else { continue }
            return Match(path: String(m.output.1), line: Int(m.output.2), column: nil, columns: cols)
        }
        for m in text.matches(of: genericPattern) {
            let cols = terminalColumns(of: m.range, in: text)
            guard cols.contains(column) else { continue }
            var path = String(m.output.1)
            while path.hasSuffix(".") { path.removeLast() }
            guard isPathLike(path) else { continue }
            return Match(
                path: path,
                line: m.output.2.flatMap { Int($0) },
                column: m.output.3.flatMap { Int($0) },
                columns: cols
            )
        }
        return nil
    }

    /// 像文件路径:带目录分隔,或扩展名里有字母(排除 3.14、127.0.0.1 这类纯数字点串)
    private static func isPathLike(_ token: String) -> Bool {
        guard !token.isEmpty, token != "/", token != "~" else { return false }
        if token.contains("/") { return true }
        let ext = (token as NSString).pathExtension
        return !ext.isEmpty && ext.rangeOfCharacter(from: .letters) != nil
    }

    /// 解析成绝对路径并验证是既存普通文件;相对路径基于会话 cwd。
    /// exists 可注入以便单测。
    static func resolve(
        _ match: Match,
        cwd: String?,
        exists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    ) -> String? {
        var path = match.path
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        if !path.hasPrefix("/") {
            guard let cwd else { return nil }
            path = (cwd as NSString).appendingPathComponent(path)
        }
        path = (path as NSString).standardizingPath
        return exists(path) ? path : nil
    }

    /// 字符串索引区间 → 终端列区间:CJK 等宽字符占 2 列,与终端排版对齐
    static func terminalColumns(of range: Range<String.Index>, in text: String) -> Range<Int> {
        var col = 0
        var start = 0
        var end = 0
        var index = text.startIndex
        if range.lowerBound == text.startIndex { start = 0 }
        while index < text.endIndex {
            if index == range.lowerBound { start = col }
            col += displayWidth(text[index])
            index = text.index(after: index)
            if index == range.upperBound { end = col }
        }
        return start..<max(end, start)
    }

    private static func displayWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
