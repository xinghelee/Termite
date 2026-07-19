import AppKit
import SwiftUI

/// 轻量语法着色:单遍扫描出注释/字符串/数字/关键字/类型名,配色取自当前终端主题的 ANSI 色。
/// 不追求语法树级精确 —— 预览面板够用、零依赖、任意大小文件不崩。
enum CodeHighlighter {
    /// 按扩展名着色;未知扩展返回 nil(调用方按纯文本渲染)
    static func highlight(_ text: String, fileExtension ext: String, theme: TerminalTheme) -> AttributedString? {
        guard let spec = LanguageSpec.spec(for: ext.lowercased()) else { return nil }
        let palette = Palette(theme: theme)
        var out = AttributedString()
        var plain = String.UnicodeScalarView()

        let scalars = Array(text.unicodeScalars)
        var i = 0

        func flushPlain() {
            guard !plain.isEmpty else { return }
            out += AttributedString(String(plain))
            plain = String.UnicodeScalarView()
        }
        func emit(_ from: Int, _ to: Int, _ color: Color) {
            flushPlain()
            var run = AttributedString(String(String.UnicodeScalarView(scalars[from..<to])))
            run.foregroundColor = color
            out += run
        }
        func startsWith(_ token: String, at index: Int) -> Bool {
            let t = Array(token.unicodeScalars)
            guard index + t.count <= scalars.count else { return false }
            for (offset, s) in t.enumerated() where scalars[index + offset] != s { return false }
            return true
        }

        while i < scalars.count {
            let c = scalars[i]

            // 行注释
            if spec.lineComments.contains(where: { startsWith($0, at: i) }) {
                let start = i
                while i < scalars.count, scalars[i] != "\n" { i += 1 }
                emit(start, i, palette.comment)
                continue
            }
            // 块注释
            if let (open, close) = spec.blockComment, startsWith(open, at: i) {
                let start = i
                i += open.unicodeScalars.count
                while i < scalars.count, !startsWith(close, at: i) { i += 1 }
                if i < scalars.count { i += close.unicodeScalars.count }
                emit(start, i, palette.comment)
                continue
            }
            // 字符串(含 python 三引号;\ 转义;不跨行的普通引号遇换行终止,避免坏文件染绿全篇)
            if spec.stringDelimiters.contains(c) {
                let quote = c
                let triple = spec.tripleQuotes && startsWith(String(repeating: String(quote), count: 3), at: i)
                let start = i
                i += triple ? 3 : 1
                while i < scalars.count {
                    if scalars[i] == "\\" { i += 2; continue }
                    if triple {
                        if startsWith(String(repeating: String(quote), count: 3), at: i) { i += 3; break }
                    } else if scalars[i] == quote {
                        i += 1
                        break
                    } else if scalars[i] == "\n" {
                        break
                    }
                    i += 1
                }
                emit(start, min(i, scalars.count), palette.string)
                continue
            }
            // 数字(简化:数字开头连同字母/点/下划线,覆盖 0x1F、1_000、1.5e3)
            if c.properties.numericType != nil, !isIdentifierScalar(i > 0 ? scalars[i - 1] : " ") {
                let start = i
                while i < scalars.count, isIdentifierScalar(scalars[i]) || scalars[i] == "." { i += 1 }
                emit(start, i, palette.number)
                continue
            }
            // 标识符:关键字 / 大写开头当类型名
            if isIdentifierHead(c) {
                let start = i
                while i < scalars.count, isIdentifierScalar(scalars[i]) { i += 1 }
                let word = String(String.UnicodeScalarView(scalars[start..<i]))
                if spec.keywords.contains(word) {
                    emit(start, i, palette.keyword)
                } else if spec.capitalizedAsType, word.first?.isUppercase == true {
                    emit(start, i, palette.type)
                } else {
                    plain.append(contentsOf: scalars[start..<i])
                }
                continue
            }
            // 注解/属性/预处理:@xxx #xxx
            if (c == "@" || c == "#"), i + 1 < scalars.count, isIdentifierHead(scalars[i + 1]) {
                let start = i
                i += 1
                while i < scalars.count, isIdentifierScalar(scalars[i]) { i += 1 }
                emit(start, i, palette.attribute)
                continue
            }

            plain.append(c)
            i += 1
        }
        flushPlain()
        return out
    }

    /// 已知可着色的扩展名(路由预览时用)
    static func supports(fileExtension ext: String) -> Bool {
        LanguageSpec.spec(for: ext.lowercased()) != nil
    }

    private static func isIdentifierHead(_ s: Unicode.Scalar) -> Bool {
        s == "_" || s.properties.isAlphabetic
    }

    private static func isIdentifierScalar(_ s: Unicode.Scalar) -> Bool {
        isIdentifierHead(s) || ("0"..."9").contains(s)
    }

    /// 从主题 ANSI 16 色取角色色(暗/亮主题都成立的经典映射)
    private struct Palette {
        let comment: Color
        let string: Color
        let number: Color
        let keyword: Color
        let type: Color
        let attribute: Color

        init(theme: TerminalTheme) {
            func ansi(_ index: Int) -> Color {
                guard theme.ansi.indices.contains(index) else { return .secondary }
                return Color(nsColor: NSColor(hex: theme.ansi[index]))
            }
            comment = Color(nsColor: NSColor(hex: theme.foreground).withAlphaComponent(0.45))
            string = ansi(2)     // 绿
            number = ansi(3)     // 黄
            keyword = ansi(5)    // 品红
            type = ansi(6)       // 青
            attribute = ansi(4)  // 蓝
        }
    }
}

/// 每种语言的着色配置;spec(for:) 按扩展名路由
private struct LanguageSpec {
    var keywords: Set<String> = []
    var lineComments: [String] = []
    var blockComment: (String, String)?
    var stringDelimiters: Set<Unicode.Scalar> = ["\"", "'"]
    var tripleQuotes = false
    var capitalizedAsType = true

    static func spec(for ext: String) -> LanguageSpec? {
        switch ext {
        case "swift":
            return LanguageSpec(
                keywords: ["actor", "as", "assign", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "indirect", "infix", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "nonmutating", "open", "operator", "optional", "override", "postfix", "precedencegroup", "prefix", "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet"],
                lineComments: ["//"], blockComment: ("/*", "*/")
            )
        case "js", "jsx", "ts", "tsx", "mjs", "cjs":
            return LanguageSpec(
                keywords: ["abstract", "any", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let", "namespace", "new", "null", "of", "private", "protected", "public", "readonly", "return", "set", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with", "yield"],
                lineComments: ["//"], blockComment: ("/*", "*/"),
                stringDelimiters: ["\"", "'", "`"]
            )
        case "py":
            return LanguageSpec(
                keywords: ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return", "self", "try", "while", "with", "yield"],
                lineComments: ["#"], tripleQuotes: true
            )
        case "go":
            return LanguageSpec(
                keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface", "iota", "map", "nil", "package", "range", "return", "select", "struct", "switch", "true", "type", "var"],
                lineComments: ["//"], blockComment: ("/*", "*/"),
                stringDelimiters: ["\"", "'", "`"]
            )
        case "rs":
            return LanguageSpec(
                keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"],
                lineComments: ["//"], blockComment: ("/*", "*/")
            )
        case "c", "h", "cpp", "cc", "hpp", "m", "mm":
            return LanguageSpec(
                keywords: ["auto", "bool", "break", "case", "catch", "char", "class", "const", "constexpr", "continue", "default", "delete", "do", "double", "else", "enum", "extern", "false", "float", "for", "goto", "if", "inline", "int", "long", "namespace", "new", "nil", "nullptr", "operator", "private", "protected", "public", "return", "self", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "true", "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while"],
                lineComments: ["//"], blockComment: ("/*", "*/")
            )
        case "java", "kt", "kts":
            return LanguageSpec(
                keywords: ["abstract", "as", "break", "case", "catch", "class", "companion", "const", "continue", "data", "default", "do", "else", "enum", "extends", "false", "final", "finally", "for", "fun", "if", "implements", "import", "in", "init", "instanceof", "interface", "internal", "is", "lateinit", "new", "null", "object", "open", "override", "package", "private", "protected", "public", "return", "sealed", "static", "super", "suspend", "switch", "this", "throw", "throws", "true", "try", "val", "var", "when", "while"],
                lineComments: ["//"], blockComment: ("/*", "*/")
            )
        case "rb":
            return LanguageSpec(
                keywords: ["begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "and", "raise", "redo", "require", "rescue", "retry", "return", "self", "super", "then", "true", "unless", "until", "when", "while", "yield"],
                lineComments: ["#"]
            )
        case "sh", "zsh", "bash", "fish":
            return LanguageSpec(
                keywords: ["alias", "break", "case", "cd", "continue", "do", "done", "echo", "elif", "else", "esac", "eval", "exec", "exit", "export", "fi", "for", "function", "if", "in", "local", "read", "return", "set", "shift", "source", "then", "unset", "until", "while"],
                lineComments: ["#"], capitalizedAsType: false
            )
        case "json":
            return LanguageSpec(keywords: ["false", "null", "true"], capitalizedAsType: false)
        case "yaml", "yml", "toml":
            return LanguageSpec(keywords: ["false", "no", "null", "true", "yes"], lineComments: ["#"], capitalizedAsType: false)
        case "sql":
            return LanguageSpec(
                keywords: ["AND", "AS", "ASC", "BY", "CREATE", "DELETE", "DESC", "DISTINCT", "DROP", "FROM", "GROUP", "HAVING", "IN", "INDEX", "INNER", "INSERT", "INTO", "IS", "JOIN", "LEFT", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "OUTER", "RIGHT", "SELECT", "SET", "TABLE", "UNION", "UPDATE", "VALUES", "WHERE", "and", "as", "from", "insert", "into", "join", "limit", "on", "or", "order", "select", "set", "update", "where"],
                lineComments: ["--"], blockComment: ("/*", "*/"), capitalizedAsType: false
            )
        case "css", "scss", "less":
            return LanguageSpec(lineComments: ["//"], blockComment: ("/*", "*/"), capitalizedAsType: false)
        case "html", "htm", "xml", "svg", "vue", "plist":
            return LanguageSpec(blockComment: ("<!--", "-->"), capitalizedAsType: false)
        case "md", "markdown", "txt", "log", "csv", "lock", "gitignore", "env", "ini", "conf", "cfg", "entitlements", "pbxproj", "strings", "xcconfig", "properties", "gradle", "dockerfile", "makefile":
            return LanguageSpec(capitalizedAsType: false, stringDelimitersOverride: [])
        default:
            return nil
        }
    }

    /// 便捷:关掉字符串着色的初始化(纯文本类)
    init(keywords: Set<String> = [], lineComments: [String] = [], blockComment: (String, String)? = nil,
         stringDelimiters: Set<Unicode.Scalar> = ["\"", "'"], tripleQuotes: Bool = false,
         capitalizedAsType: Bool = true, stringDelimitersOverride: Set<Unicode.Scalar>? = nil) {
        self.keywords = keywords
        self.lineComments = lineComments
        self.blockComment = blockComment
        self.stringDelimiters = stringDelimitersOverride ?? stringDelimiters
        self.tripleQuotes = tripleQuotes
        self.capitalizedAsType = capitalizedAsType
    }
}
