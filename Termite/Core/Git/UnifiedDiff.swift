import Foundation

/// unified diff 解析:把 `git diff` 文本拆成 hunk + 带新旧行号的行
enum UnifiedDiff {

    enum LineKind: Equatable {
        case context, added, removed
    }

    struct Line: Identifiable, Equatable {
        let id: Int
        let kind: LineKind
        let text: String
        let oldNumber: Int?
        let newNumber: Int?
    }

    struct Hunk: Identifiable, Equatable {
        let id: Int
        /// "@@ -12,7 +12,9 @@ func foo()" 的上下文尾巴(没有则空)
        let header: String
        let oldStart: Int
        let newStart: Int
        let lines: [Line]
    }

    /// 解析 unified diff;文件头(diff --git/index/---/+++)跳过
    static func parse(_ text: String) -> [Hunk] {
        var hunks: [Hunk] = []
        var currentLines: [Line] = []
        var header = ""
        var oldStart = 0, newStart = 0
        var oldNumber = 0, newNumber = 0
        var lineID = 0
        var inHunk = false

        func flush() {
            guard inHunk else { return }
            hunks.append(Hunk(id: hunks.count, header: header, oldStart: oldStart, newStart: newStart, lines: currentLines))
            currentLines = []
        }

        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("@@") {
                flush()
                inHunk = true
                (oldStart, newStart, header) = parseHunkHeader(raw)
                oldNumber = oldStart
                newNumber = newStart
                continue
            }
            guard inHunk else { continue }
            if raw.hasPrefix("diff ") || raw.hasPrefix("index ") || raw.hasPrefix("--- ") || raw.hasPrefix("+++ ") {
                inHunk = false
                flush()
                continue
            }
            if raw.hasPrefix("\\") { continue } // "\ No newline at end of file"
            lineID += 1
            if raw.hasPrefix("+") {
                currentLines.append(Line(id: lineID, kind: .added, text: String(raw.dropFirst()), oldNumber: nil, newNumber: newNumber))
                newNumber += 1
            } else if raw.hasPrefix("-") {
                currentLines.append(Line(id: lineID, kind: .removed, text: String(raw.dropFirst()), oldNumber: oldNumber, newNumber: nil))
                oldNumber += 1
            } else {
                // 上下文行以空格开头;diff 输出的最后可能有空串,跳过
                if raw.isEmpty, currentLines.isEmpty { continue }
                currentLines.append(Line(id: lineID, kind: .context, text: String(raw.dropFirst()), oldNumber: oldNumber, newNumber: newNumber))
                oldNumber += 1
                newNumber += 1
            }
        }
        flush()
        return hunks
    }

    /// "@@ -12,7 +30,9 @@ tail" → (12, 30, "tail")
    private static func parseHunkHeader(_ line: String) -> (Int, Int, String) {
        var oldStart = 0, newStart = 0
        var header = ""
        // 第二个 "@@" 之后是上下文尾巴
        let parts = line.components(separatedBy: "@@")
        if parts.count >= 3 {
            header = parts[2].trimmingCharacters(in: .whitespaces)
        }
        if parts.count >= 2 {
            for token in parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ") {
                if token.hasPrefix("-") {
                    oldStart = Int(token.dropFirst().components(separatedBy: ",")[0]) ?? 0
                } else if token.hasPrefix("+") {
                    newStart = Int(token.dropFirst().components(separatedBy: ",")[0]) ?? 0
                }
            }
        }
        return (oldStart, newStart, header)
    }

    /// 全部 hunk 的 ± 统计
    static func stats(_ hunks: [Hunk]) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for hunk in hunks {
            for line in hunk.lines {
                switch line.kind {
                case .added: added += 1
                case .removed: removed += 1
                case .context: break
                }
            }
        }
        return (added, removed)
    }
}
